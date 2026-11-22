#include "perf_log.h"

#ifdef PANEL_PERF_LOG

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <lvgl.h>

#include "display_driver.h"
#include "frame_ledger.h"
#include "perf_line.h"

namespace perf_log {
namespace {

constexpr uint32_t kWindowMs = 5000;

// This window's frames: refreshes that flushed something, timed start to end.
uint32_t g_frames = 0;
uint64_t g_frame_us = 0;
uint32_t g_frame_max_us = 0;
uint32_t g_refresh_start_us = 0;
uint32_t g_refresh_px = 0;

uint32_t g_window_start_ms = 0;
uint32_t g_datagrams = 0;
uint32_t g_too_big_at_start = 0;
uint32_t g_too_big = 0;
uint32_t g_dropped_at_start = 0;
bool g_drops_counted = false;
uint32_t g_dropped = 0;

// The frame ledger (#662): about 1 KB, so static, off the loop's stack. Fed by the hooks below, all on this task.
frame_ledger::Ledger g_ledger;
// The panel's latches already replayed into the ledger.
uint32_t g_latches_seen = 0;

// Every latch since the last call is one boundary to the ledger: vsync() only marks what waits, so several count
// as one, at the last one's time.
void replay_latches(uint32_t latches, uint32_t latch_us) {
    if (latches == g_latches_seen) return;
    g_latches_seen = latches;
    g_ledger.vsync(latch_us);
}

void replay_latches() {
    const DisplayLatch l = display_latch();
    replay_latches(l.count, l.us);
}

void on_event(lv_event_t* e) {
    switch (lv_event_get_code(e)) {
        case LV_EVENT_REFR_START:
            g_refresh_start_us = micros();
            g_refresh_px = 0;
            break;
        case LV_EVENT_FLUSH_START: {
            const lv_area_t* a = static_cast<const lv_area_t*>(lv_event_get_param(e));
            if (a) g_refresh_px += static_cast<uint32_t>(lv_area_get_size(a));
            break;
        }
        case LV_EVENT_REFR_READY: {
            // Nothing drawn: not a frame, and what this frame read waits for none. Every frame refreshes once
            // (#663), right after its reads, so this is the settle step: no reliance on LVGL's timer state.
            if (g_refresh_px == 0) {
                g_ledger.nothing_drawn();
                break;
            }
            const uint32_t took = micros() - g_refresh_start_us;
            ++g_frames;
            g_frame_us += took;
            if (took > g_frame_max_us) g_frame_max_us = took;
            break;
        }
        default:
            break;
    }
}

}  // namespace

void begin() {
    lv_display_t* disp = display_lvgl();
    if (disp == nullptr) return;
    lv_display_add_event_cb(disp, on_event, LV_EVENT_REFR_START, nullptr);
    lv_display_add_event_cb(disp, on_event, LV_EVENT_FLUSH_START, nullptr);
    lv_display_add_event_cb(disp, on_event, LV_EVENT_REFR_READY, nullptr);
    display_take_perf();  // start the driver's counts from here
    display_take_scan();
    display_take_copy();
    g_ledger.take();
    g_latches_seen = display_latch().count;
    g_window_start_ms = millis();
    Serial.println("perf: on, a line every 5 s");
}

void tick(uint32_t now_ms, int datagrams, uint32_t too_big, uint32_t dropped, bool drops_counted, bool may_print,
          frame_clock::Clock& clock) {
    g_drops_counted = drops_counted;
    if (datagrams > 0) g_datagrams += static_cast<uint32_t>(datagrams);
    g_too_big = too_big;
    g_dropped = dropped;
    if (!may_print || now_ms - g_window_start_ms < kWindowMs) return;

    const DisplayPerf d = display_take_perf();
    perf_line::Window w;
    w.ms = now_ms - g_window_start_ms;
    w.frames = g_frames;
    w.frame_us = g_frame_us;
    w.frame_max_us = g_frame_max_us;
    w.vsyncs = d.vsyncs;
    w.swaps = d.swaps;
    w.swap_timeouts = d.swap_timeouts;
    w.swap_wait_us = d.flush_wait_us;
    w.draw_bitmap_us = d.draw_bitmap_us;
    w.datagrams = g_datagrams;
    w.too_big = g_too_big - g_too_big_at_start;
    w.dropped = g_dropped - g_dropped_at_start;
    w.drops_counted = g_drops_counted;  // a numbered feed came (#750); else lost can't be told
    w.internal_free = static_cast<uint32_t>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    w.scan = display_take_scan();
    w.copy_budget_us = display_copy_budget_us();
    DisplayCopyLate where = {};
    w.copy = display_take_copy(&where);
    const perf_line::CopySpread spread = display_take_copy_spread();
    w.copy_late_drawing = where.drawing;
    w.copy_late_turn = where.turn;
    w.ledger = g_ledger.take();
    w.clock = clock.take();
    const std::string line = perf_line::format(w);
    const std::string copies = perf_line::format_copy(spread);
    Serial.println(line.c_str());
    Serial.println(copies.c_str());
    display_note_print(static_cast<uint32_t>(line.size() + copies.size() + 4));

    g_frames = 0;
    g_frame_us = 0;
    g_frame_max_us = 0;
    g_window_start_ms = now_ms;
    g_datagrams = 0;
    g_too_big_at_start = g_too_big;
    g_dropped_at_start = g_dropped;
}

void feed_seen(uint32_t us) {
    replay_latches();
    g_ledger.arrived(us);
}

void feed_read(uint32_t us) {
    replay_latches();
    g_ledger.read(us);
}

void frame_swapped(uint32_t latches, uint32_t latch_us, uint32_t swapped_us) {
    replay_latches(latches, latch_us);
    g_ledger.swapped(swapped_us);
}

void frame_on_glass(uint32_t release_us) { g_ledger.on_glass(release_us); }

}  // namespace perf_log

#else

namespace perf_log {
void begin() {}
void tick(uint32_t, int, uint32_t, uint32_t, bool, bool, frame_clock::Clock&) {}
}  // namespace perf_log

#endif
