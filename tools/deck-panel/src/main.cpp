// The deck panel (#490, #620): joins Wi-Fi, listens for DeckBridge's display feed and shows the deck in front, or the
// waiting screen with its address and port. Everything runs on Arduino's loop task: the core isn't thread-safe, so
// the UDP socket is polled here, never read from a callback. Built with DECK_PANEL_TEST_SCREEN (env crowpanel-test),
// it shows the test screen (#615) instead, with no Wi-Fi.
//
// One frame clock (#663, lib/frame_clock): loop() is one frame. It waits for the panel's latch and the vsync after it
// (about 1.9 ms later), reads the feed that came since, holds until 4.3 ms after the latch (PANEL_DRAW_AT_US: the
// bounce copy that follows the vertical blank needs core 1 quiet), renders, refreshes once (draw and swap), then does
// the chores (Wi-Fi, touch, serial) until a guard before the next latch. A datagram read after latch N is swapped
// before N+1 and on glass from N+1: under one scan-out.
#include <Arduino.h>
#include <Wire.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <lvgl.h>

#include "board_pins.h"
#include "display_driver.h"
#include "frame_clock.h"
#include "panel_mcu.h"
#include "perf_log.h"
#include "touch.h"

#ifdef DECK_PANEL_TEST_SCREEN
#include "test_screen.h"
#else
#include "deck_core.h"
#include "deck_view.h"
#include "feed_drain.h"
#include "feed_udp.h"
#include "hold_reset.h"
#include "update_wifi.h"
#include "wifi_link.h"
#endif

#ifndef DECK_PANEL_SHA
#define DECK_PANEL_SHA "unknown"
#endif

namespace {

// Serial's TX ring buffer: a print lands in it and the UART drains it in the background (115200 baud, about 11.5 B a
// millisecond), so no print waits for the wire unless the buffer is full. IDF's TX ring doesn't split an item and
// takes a write in chunks of up to half its size, each with a header, so it holds less than its size: 2 KB keeps the
// perf line (under 640 B), the health line and a few more with room.
constexpr size_t kSerialTxBytes = 2048;
// The chores end this long before the next latch, so the frame's wait starts before it.
constexpr uint32_t kGuardUs = 3000;

uint32_t now_us() { return static_cast<uint32_t>(esp_timer_get_time()); }

#ifndef DECK_PANEL_TEST_SCREEN
/// Whether `until_us` is still ahead; esp_timer's low 32 bits wrap every 71 minutes.
bool time_left(uint32_t until_us) { return static_cast<int32_t>(until_us - now_us()) > 0; }
#endif

frame_clock::Clock g_clock(display_frame_us(), kGuardUs);

// The loop's step, for the perf build's copy line (#663); nothing in the others.
#ifdef PANEL_PERF_LOG
#define MARK(step) display_mark(perf_line::Mark::step)
#else
#define MARK(step) \
    do {           \
    } while (0)
#endif

#ifndef DECK_PANEL_TEST_SCREEN
// Static, not loop() locals: the drain's 512-byte buffer and the view's text stay off the loop task's 8 KB stack.
deck_core::DeckCore g_core;
feed_drain::Drain g_drain;
FeedUdp g_udp;
DeckScreen g_screen;
wifi_setup::HoldReset g_hold;
uint32_t g_too_big = 0;
uint32_t g_health_ms = 0;
int g_read = 0;  // this frame's drain, for the perf build's count

/// Once a minute on serial: the loop task's spare stack and internal RAM, the numbers a long run needs.
void log_health(uint32_t now_ms) {
    constexpr uint32_t kEveryMs = 60000;
    if (now_ms - g_health_ms < kEveryMs) return;
    g_health_ms = now_ms;
#ifdef PANEL_PERF_LOG
    display_note_print(96);  // about the line below
#endif
    Serial.printf("deck panel: loop stack free %u B, internal heap free %u B (lowest %u B)\n",
                  unsigned(uxTaskGetStackHighWaterMark(nullptr) * sizeof(StackType_t)),
                  unsigned(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
                  unsigned(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)));
}
#endif

void build_screen() {
#ifdef DECK_PANEL_TEST_SCREEN
    test_screen::build();
#else
    g_screen.build();
    // The first frame says what's true before Wi-Fi starts: the core takes the network as up until told.
    g_core.set_network(wifi_link::state(), wifi_link::ip());
    g_core.set_setup(wifi_link::setup_name(), wifi_link::setup_password());
    g_core.render(g_screen, millis());
#endif
}

// When the frame may touch PSRAM (#663, #650), microseconds after the latch; 0: at once. The first bounce copy
// after the vertical blank (IDF v5.5.4 esp_lcd_panel_rgb.c: the fill of chunk 2, at the first DMA EOF after the
// vsync restart) starts about 3.28-3.30 ms after the latch, from a cache preload issued about 2 ms before it, after
// the fill of chunk 1. Anything core 1 reads or writes through the data cache in that gap (LVGL's heap and the
// framebuffers are PSRAM, its fonts flash rodata) can evict the preload, and then the copy runs cold, 667-969 us
// against its 666 us margin. That copy ends by +4.26 ms at worst (the slowest seen, cold); with the loop asleep it
// ran at most 589 us (owner's run c4), ending by about +3.9 ms. So render and refresh start at +4.3 ms, past even
// the cold worst. The feed's drain runs in the gap: it reads lwIP's buffers and WiFiUDP's, both internal RAM (under
// the 4096 B PSRAM threshold; Wi-Fi and lwIP buffers not in PSRAM), and feeds the core, a static in internal RAM
// with no heap. Only its code and a few flash constants pass through the caches. -DPANEL_DRAW_AT_US=0 drops the hold.
#ifndef PANEL_DRAW_AT_US
#define PANEL_DRAW_AT_US 4300
#endif

#if PANEL_DRAW_AT_US > 0
SemaphoreHandle_t g_hold_sem = nullptr;
esp_timer_handle_t g_hold_timer = nullptr;

void hold_done(void*) { xSemaphoreGive(g_hold_sem); }

void hold_begin() {
    g_hold_sem = xSemaphoreCreateBinary();
    const esp_timer_create_args_t args = {hold_done, nullptr, ESP_TIMER_TASK, "draw_at", false};
    if (g_hold_sem == nullptr || esp_timer_create(&args, &g_hold_timer) != ESP_OK) {
        g_hold_timer = nullptr;
        Serial.println("deck panel: no draw timer; holding in whole ticks");
    }
}

/// Blocks the loop task until `at_us` (esp_timer), if that's ahead; core 1 runs its idle task meanwhile. A one-shot
/// esp_timer (its task and interrupt on core 0) gives the semaphore: no spin, finer than a tick.
void hold_until(uint32_t at_us) {
    const int32_t left = static_cast<int32_t>(at_us - now_us());
    if (left <= 0) return;
    if (g_hold_timer != nullptr && esp_timer_start_once(g_hold_timer, static_cast<uint64_t>(left)) == ESP_OK) {
        // The bound only covers a lost give.
        xSemaphoreTake(g_hold_sem, pdMS_TO_TICKS(left / 1000 + 5));
        return;
    }
    vTaskDelay(pdMS_TO_TICKS((left + 999) / 1000));
}
#endif

/// The panel, as the frame clock sees it.
class PanelBoard : public frame_clock::Board {
  public:
    bool wait_latch(uint32_t& count, uint32_t& us) override {
        // Two scan-outs: only a stopped panel misses it, and then the chores still run.
        DisplayLatch latch;
        MARK(wait);
        if (!display_wait_latch(2 * display_frame_us() / 1000, latch)) {
            us = now_us();
            return false;
        }
        count = latch.count;
        us = latch.us;
        latch_us_ = latch.us;
        return true;
    }

    void read_feed() override {
        MARK(read);
#ifndef DECK_PANEL_TEST_SCREEN
        // At the frame's start, the vsync after the latch, in the gap before the draw (PANEL_DRAW_AT_US): until the
        // socket is empty, within the drain's time budget (#636).
        g_read = g_drain.run(g_udp, g_core, millis(), [] { return static_cast<uint32_t>(millis()); });
#endif
    }

    void render() override {
#if PANEL_DRAW_AT_US > 0
        MARK(wait);  // the hold: the loop is asleep
        hold_until(latch_us_ + PANEL_DRAW_AT_US);
#endif
        MARK(render);
#ifdef DECK_PANEL_TEST_SCREEN
        test_screen::show_touch();
#else
        if (update_wifi::hold_render()) return;  // an update is writing flash: the still screen, not the deck (#690)
        // Read after the drain, so a datagram stamped then is never in the future of the render.
        g_core.render(g_screen, millis());
#endif
    }

    void refresh() override {
        MARK(refresh);
#ifndef DECK_PANEL_TEST_SCREEN
        if (update_wifi::hold_refresh()) return;
#endif
        display_refresh();
    }

    void chores(uint32_t until_us) override {
#ifdef DECK_PANEL_TEST_SCREEN
        (void)until_us;
        MARK(touch);
        touch_poll();
        MARK(lvgl);
        lv_timer_handler();
#else
        const uint32_t now = millis();
        // Every frame: these can't wait, and the first can't be bounded (setup's web server, a join, a scan).
        MARK(wifi);
        wifi_link::poll(now);
        g_core.set_network(wifi_link::state(), wifi_link::ip());
        update_wifi::chores(now);
        MARK(udp);
        g_udp.poll(wifi_link::state() == deck_core::Network::connected, wifi_link::joins(), now);
        // Touch only off the deck: the waiting, joining and setup screens, where the hold reset lives. On the deck
        // touch_pressed() keeps the last waiting-screen state, which only ever stops a hold (HoldReset), and the
        // first poll back on the waiting screen comes before the hold sees it.
        MARK(touch);
        if (g_core.waiting() && time_left(until_us)) touch_poll();
        if (g_hold.update(touch_pressed(), g_core.waiting(), now)) wifi_link::forget_and_restart();
        // LVGL's other timers: the touch's input device, animations. Its refresh timer is gone (display_init).
        MARK(lvgl);
        lv_timer_handler();
        MARK(perf);
        // Serial last, and only with time left; what waits prints at a later frame.
        const bool may_print = time_left(until_us);
        perf_log::tick(now, g_read, g_drain.too_big(), may_print, g_clock);
        g_read = 0;
        if (!may_print) return;
        if (g_drain.too_big() != g_too_big) {
            g_too_big = g_drain.too_big();
            Serial.printf("deck panel: %lu feed datagrams too big, dropped\n", static_cast<unsigned long>(g_too_big));
        }
        log_health(now);
#endif
    }

  private:
    uint32_t latch_us_ = 0;  // the latch this frame woke on
};

PanelBoard g_board;

}  // namespace

void setup() {
    // Before begin(): the buffer can't be set after.
    const bool tx_buffered = Serial.setTxBufferSize(kSerialTxBytes) == kSerialTxBytes;
    Serial.begin(115200);
    if (!tx_buffered) Serial.println("deck panel: no serial TX buffer; prints may hold a frame");
    Serial.printf("deck panel: boot, build %s\n", DECK_PANEL_SHA);
    Wire.begin(board::I2C_SDA, board::I2C_SCL, board::I2C_HZ);
    // The companion chip can come up after the ESP32 (seen at power-on on a V1.4): wait up to 2 s for it, quietly,
    // then let begin() log what it found once.
    for (int i = 0; i < 20 && !panel_mcu::probe(); ++i) delay(100);
    panel_mcu::begin();
    if (!display_init()) {
        Serial.println("deck panel: no display, restarting in 5 s");
        delay(5000);
        esp_restart();
    }
    perf_log::begin();
    touch_init();
    build_screen();
    display_refresh();  // the whole first frame, now, whatever ran before
#if PANEL_DRAW_AT_US > 0
    hold_begin();
#endif
    // Last, after that frame, so the screen doesn't flash on boot.
    if (!panel_mcu::backlightOn()) Serial.println("deck panel: the backlight may be off");
#ifdef DECK_PANEL_TEST_SCREEN
    Serial.println("deck panel: test screen up");
#else
    wifi_link::begin();  // after the backlight: joining takes seconds and must not hold the first frame
    update_wifi::begin();
    Serial.println("deck panel: deck view up");
#endif
}

// One frame (lib/frame_clock): no delay; the wait for the latch is the loop's only pause.
void loop() { g_clock.step(g_board); }
