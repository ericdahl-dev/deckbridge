// The deck panel (#490, #620): joins Wi-Fi, listens for DeckBridge's display feed and shows the deck in front, or the
// waiting screen with its address and port. The core and LVGL run on Arduino's loop task (core 1): the core isn't
// thread-safe. The feed's socket is the receive task's (core 0, with lwIP, #664): it stamps each datagram as it
// arrives into a fixed queue (lib/feed_intake), and the loop's frame drains that into the core. Built with
// DECK_PANEL_TEST_SCREEN (env crowpanel-test), it shows the test screen (#615) instead, with no Wi-Fi.
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

#include <atomic>

#include "board_pins.h"
#include "build_info.h"
#include "display_driver.h"
#include "feed_flags.h"
#include "frame_clock.h"
#include "panel_mcu.h"
#include "perf_log.h"
#include "touch.h"

#ifdef DECK_PANEL_TEST_SCREEN
#include "test_screen.h"
#else
#include "deck_core.h"
#include "deck_view.h"
#include "feed_intake.h"
#include "feed_udp.h"
#include "hold_reset.h"
#include "wifi_link.h"
#endif

#ifndef DECK_PANEL_SHA
#define DECK_PANEL_SHA "unknown"
#endif
#ifndef DECK_PANEL_VERSION
#define DECK_PANEL_VERSION "0"
#endif
#ifndef DECK_PANEL_RELEASE
#define DECK_PANEL_RELEASE 0
#endif

namespace {

// The firmware the updater reads (#695): on the boot line, on the waiting screen, and on request over serial.
const build_info::Build kBuild{DECK_PANEL_VERSION, DECK_PANEL_SHA, DECK_PANEL_RELEASE != 0};
build_info::Question g_question;

// The updater asks without a reboot, so it needn't wait for a boot line; opening the port doesn't reset it (#667).
void answer_version_questions() {
    while (Serial.available() > 0) {
        if (!g_question.feed(static_cast<char>(Serial.read()))) continue;
        char line[96];
        build_info::answer_line(kBuild, line, sizeof line);
        Serial.println(line);
    }
}

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
// Static, not loop() locals: the view's text stays off the loop task's 8 KB stack.
deck_core::DeckCore g_core;
#if FEED_RX_TASK
// The feed's intake (#664): the receive task's datagrams, stamped as they arrive, for the loop's frame. 16 slots of
// 1488 B (on the ESP32: 8 B stamp, 4 B length, the source, 1472 B, rounded to 8), about 23.8 KB. A plain static, so
// .bss in internal RAM (this sdkconfig puts no .bss in PSRAM), and it must stay there: the drain reads it in the gap
// before the draw, where a PSRAM read can evict the bounce copy's preload (PANEL_DRAW_AT_US). One producer (the
// receive task), one consumer (the loop), as feed_intake.h says.
feed_intake::Intake g_intake;
// The receive task's alone: it opens, waits on, reads and closes it. A close on one task under another's select() or
// recvfrom() is what one owner rules out, so the loop never touches it; it only says how Wi-Fi is.
FeedUdp g_udp;
std::atomic<bool> g_feed_connected{false};
std::atomic<uint32_t> g_feed_joins{0};
#else
// FEED_RX_TASK=0 (feed_flags.h): main's path. The drain's 512-byte buffer stays off the loop task's stack.
feed_drain::Drain g_drain;
FeedUdp g_udp;
#endif
DeckScreen g_screen;
wifi_setup::HoldReset g_hold;
uint32_t g_too_big = 0;
uint32_t g_dropped = 0;
uint32_t g_health_ms = 0;
int g_read = 0;  // this frame's drain, for the perf build's count

#if FEED_RX_TASK
// The receive task (#664). Core 0, lwIP's and Wi-Fi's: the loop's core 1 stays the panel's. Priority 5: above the
// loop's 1, so a datagram is stamped within a tick of landing however busy the idle side is, and well under lwIP's 18
// and Wi-Fi's 23, which it waits on anyway. The stack is the core's own UDP task's (CONFIG_ARDUINO_UDP_TASK_STACK_SIZE
// 4096): lwip_select()'s fd_set copies and callback record (well under 200 B), recvfrom() with no address, and
// poll()'s printf, the deepest at about 1-1.5 KB; the peek buffer is FeedUdp's, not the stack's. The health line
// prints what's left. Static, so it can't fail for want of heap.
constexpr uint32_t kReceiveStackBytes = 4096;
constexpr UBaseType_t kReceivePriority = 5;
constexpr BaseType_t kReceiveCore = 0;
static_assert(sizeof(StackType_t) == 1, "IDF counts a task's stack in bytes");
StackType_t g_receive_stack[kReceiveStackBytes];
StaticTask_t g_receive_tcb;
TaskHandle_t g_receive_task = nullptr;

/// esp_timer, all 64 bits: the intake's clock. The low 32 wrap every 71 minutes, and the core's millisecond stamps
/// are made from it.
uint64_t clock_us() { return static_cast<uint64_t>(esp_timer_get_time()); }

/// Waits on the socket (select, FeedUdp::wait) for up to FEED_RX_WAIT_MS, 5 ms: woken by lwIP when a datagram lands,
/// so it's stamped (at pump()'s find, its clock) microseconds after arrival, and with none, 200 wakes a second, not
/// #713's 1000 looks. Off Wi-Fi the socket is shut and wait() sleeps the same 5 ms: no spin. The wait is bounded, never
/// forever, for two reasons: poll() must see a join to reopen the socket, and the USB cable's feed (#711) is pumped
/// here too, and Serial isn't an lwIP descriptor, so select() can't wake on it. FEED_RX_DELAY_TICKS=N (feed_flags.h)
/// is #713's look-then-sleep instead, for the A/B builds.
void receive_loop(void*) {
    for (;;) {
        g_udp.poll(g_feed_connected.load(std::memory_order_relaxed), g_feed_joins.load(std::memory_order_relaxed),
                   millis());
#if FEED_RX_DELAY_TICKS
        g_intake.pump(g_udp, clock_us);
        vTaskDelay(FEED_RX_DELAY_TICKS);
#else
        if (g_udp.wait(FEED_RX_WAIT_MS)) g_intake.pump(g_udp, clock_us);
#endif
        // #711, the USB cable: pump its reader here, after each wake, into the same intake (one producer, this task):
        //   g_intake.pump(g_cable, clock_us, deck_core::Source::cable);
        // It runs at least every FEED_RX_WAIT_MS, since nothing above waits longer; it must not block either.
    }
}

void receive_begin() {
    g_receive_task = xTaskCreateStaticPinnedToCore(receive_loop, "feed_rx", kReceiveStackBytes, nullptr,
                                                   kReceivePriority, g_receive_stack, &g_receive_tcb, kReceiveCore);
    if (g_receive_task == nullptr) Serial.println("deck panel: no feed receive task; the feed won't show");
}

unsigned receive_stack_free() {
    return g_receive_task ? unsigned(uxTaskGetStackHighWaterMark(g_receive_task) * sizeof(StackType_t)) : 0u;
}
uint32_t feed_too_big() { return g_intake.too_big(); }
uint32_t feed_dropped() { return g_intake.dropped(); }
#else
unsigned receive_stack_free() { return 0; }
uint32_t feed_too_big() { return g_drain.too_big(); }
uint32_t feed_dropped() { return 0; }
#endif

/// Once a minute on serial: the loop task's spare stack and internal RAM, the numbers a long run needs.
void log_health(uint32_t now_ms) {
    constexpr uint32_t kEveryMs = 60000;
    if (now_ms - g_health_ms < kEveryMs) return;
    g_health_ms = now_ms;
#ifdef PANEL_PERF_LOG
    display_note_print(128);  // about the line below
#endif
    Serial.printf("deck panel: loop stack free %u B, receive stack free %u B, internal heap free %u B (lowest %u B)\n",
                  unsigned(uxTaskGetStackHighWaterMark(nullptr) * sizeof(StackType_t)),
                  receive_stack_free(),
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
    static char build_label[48];  // the core copies it; static keeps it off the setup stack anyway
    build_info::label(kBuild, build_label, sizeof build_label);
    g_core.set_build(build_label);
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
// the cold worst. The feed's drain runs in the gap: it reads the intake's slots (g_intake, a static in internal
// RAM) and feeds the core, another, with no heap and no socket call. Only its code and a few flash constants pass
// through the caches. -DPANEL_DRAW_AT_US=0 drops the hold.
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
        // At the frame's start, the vsync after the latch, in the gap before the draw (PANEL_DRAW_AT_US): what the
        // receive task queued since the last frame, each datagram at its arrival (#664). Only what was queued when it
        // looked, so never more than 16, and no socket call: internal RAM and the core.
#if FEED_RX_TASK
        const feed_intake::Drained got = g_intake.drain(g_core);
        g_read = got.count;
#if defined(PANEL_PERF_LOG) && FEED_STAMP_AT_READ
        // FEED_STAMP_AT_READ=1 (feed_flags.h): the ledger sees the drain's time, as main's did, not the arrivals.
        if (got.count > 0) {
            const uint32_t at = now_us();
            perf_log::feed_seen(at);
            perf_log::feed_read(at);
        }
#elif defined(PANEL_PERF_LOG)
        // The ledger (#662, in perf_log, the loop's task) learns the arrivals here, not on the receive task: the
        // oldest for its skip, the newest for its lag, then the read. Each hook replays the latches first. Nothing
        // read, nothing told: a read with no arrival would count from the read's time.
        if (got.count > 0) {
            // TODO(#666): the skip needs the latch before the waking one at its own time. perf_log's replay_latches()
            // tells only the newest (display_latch()), so after a late frame latches_[1] is an older latch and a skip
            // can go uncounted. With Scan::latches() ({count, us, previous_us}) replay_latches() would tell
            // g_ledger.vsync(previous_us) then g_ledger.vsync(us) when count moved by 2 or more (one vsync(us) when by
            // 1). That change is perf_log.cpp's; nothing to call from here.
            perf_log::feed_seen(static_cast<uint32_t>(got.oldest_us));
            perf_log::feed_seen(static_cast<uint32_t>(got.newest_us));
            perf_log::feed_read(now_us());
        }
#endif
#else
        // FEED_RX_TASK=0: main's drain, verbatim, on the raw socket now; FeedUdp stamps the ledger (feed_udp.cpp).
        g_read = g_drain.run(g_udp, g_core, millis(), [] { return static_cast<uint32_t>(millis()); });
#endif
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
        // Read after the drain, so a datagram stamped then is never in the future of the render.
        g_core.render(g_screen, millis());
#endif
    }

    void refresh() override {
        MARK(refresh);
        display_refresh();
    }

    void chores(uint32_t until_us) override {
#ifdef DECK_PANEL_TEST_SCREEN
        (void)until_us;
        MARK(touch);
        touch_poll();
        MARK(lvgl);
        lv_timer_handler();
        answer_version_questions();
#else
        const uint32_t now = millis();
        // Every frame: these can't wait, and the first can't be bounded (setup's web server, a join, a scan).
        MARK(wifi);
        wifi_link::poll(now);
        g_core.set_network(wifi_link::state(), wifi_link::ip());
        MARK(udp);
        // For the receive task, which opens the socket on each join and closes it off Wi-Fi (FeedUdp::poll); wifi_link
        // is this task's, so it's told, not asked. A join seen a millisecond before its state only reopens late.
#if FEED_RX_TASK
        g_feed_joins.store(wifi_link::joins(), std::memory_order_relaxed);
        g_feed_connected.store(wifi_link::state() == deck_core::Network::connected, std::memory_order_relaxed);
#else
        g_udp.poll(wifi_link::state() == deck_core::Network::connected, wifi_link::joins(), now);
#endif
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
        perf_log::tick(now, g_read, feed_too_big(), feed_dropped(), may_print, g_clock);
        g_read = 0;
        if (!may_print) return;
        // Read once: the receive task may count another meanwhile.
        const uint32_t too_big = feed_too_big();
        const uint32_t dropped = feed_dropped();
        if (too_big != g_too_big || dropped != g_dropped) {
            g_too_big = too_big;
            g_dropped = dropped;
            Serial.printf("deck panel: feed datagrams dropped since boot: %lu too big, %lu with the intake full\n",
                          static_cast<unsigned long>(too_big), static_cast<unsigned long>(dropped));
        }
        log_health(now);
        // The updater's version question (#695), answered with time left: a question waits in Serial's buffer.
        answer_version_questions();
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
    char boot[96];
    build_info::boot_line(kBuild, boot, sizeof boot);
    Serial.println(boot);
#if !FEED_RX_TASK || FEED_STAMP_AT_READ || FEED_RX_DELAY_TICKS != 0 || FEED_RX_WAIT_MS != 5
    // Only off the defaults (feed_flags.h), so a run's log says which build it was.
    Serial.printf("deck panel: feed flags FEED_RX_TASK=%d FEED_STAMP_AT_READ=%d FEED_RX_WAIT_MS=%d "
                  "FEED_RX_DELAY_TICKS=%d\n",
                  FEED_RX_TASK, FEED_STAMP_AT_READ, FEED_RX_WAIT_MS, FEED_RX_DELAY_TICKS);
#endif
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
#if FEED_RX_TASK
    receive_begin();     // before Wi-Fi, so the first join's socket opens on it
#endif
    wifi_link::begin();  // after the backlight: joining takes seconds and must not hold the first frame
    Serial.println("deck panel: deck view up");
#endif
}

// One frame (lib/frame_clock): no delay; the wait for the latch is the loop's only pause.
void loop() { g_clock.step(g_board); }
