// Implementation of the panel driver and the LVGL 9 binding. From phrasedeck (#615), on esp_lcd since #635; see
// LICENSE.crowpanel-drivers.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#include "display_driver.h"

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_lcd_panel_ops.h>
#include <esp_memory_utils.h>
#include <esp_lcd_panel_rgb.h>
#include <esp_private/periph_ctrl.h>
#include <esp_rom_sys.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <esp_cpu.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <soc/lcd_cam_struct.h>

#include "bounce_budget.h"
#include "frame_pacing.h"
#include "panel_mcu.h"
#ifdef PANEL_PERF_LOG
#include "perf_log.h"
#endif
#include "scan_watch.h"
#include "swap_gate.h"

// Signal polarity, each overridable with -D to try on the panel without a commit. The defaults reproduce what
// LovyanGFX 1.2.35 programmed (Bus_RGB.inl), the picture that worked before #635:
//   lcd_ck_out_edge = pclk_idle_high (true)  -> data changes on the falling edge: pclk_active_neg 1
//   lcd_ck_idle_edge = false                 -> clock idles low: pclk_idle_high 0
//   lcd_hsync/vsync_idle_pol = polarity (0)  -> both idle low: hsync_idle_low, vsync_idle_low 1
//   lcd_de_idle_pol = de_idle_high (0)       -> de_idle_high 0
#ifndef PANEL_PCLK_ACTIVE_NEG
#define PANEL_PCLK_ACTIVE_NEG 1
#endif
#ifndef PANEL_PCLK_IDLE_HIGH
#define PANEL_PCLK_IDLE_HIGH 0
#endif
#ifndef PANEL_HSYNC_IDLE_LOW
#define PANEL_HSYNC_IDLE_LOW (board::LCD_HSYNC_POLARITY == 0)
#endif
#ifndef PANEL_VSYNC_IDLE_LOW
#define PANEL_VSYNC_IDLE_LOW (board::LCD_VSYNC_POLARITY == 0)
#endif
#ifndef PANEL_DE_IDLE_HIGH
#define PANEL_DE_IDLE_HIGH 0
#endif
// Pixels per bounce buffer: 8000, ten lines, 2 x 16 KB of internal DMA RAM (the old draw buffers' share). Bounce mode
// is what makes the swap work on this core: the prebuilt core restarts the DMA at every vsync
// (CONFIG_LCD_RGB_RESTART_IN_VSYNC), and on the S3 that restart link always points into fbs[0] (IDF 5.5
// esp_lcd_panel_rgb.c, RGB_LCD_NEEDS_SEPARATE_RESTART_LINK), which would undo every swap to fbs[1]. With bounce
// buffers the interrupt copies each next ten lines from the buffer it latched at the frame's start, and the restart
// refills from that buffer too. -DPANEL_BOUNCE_PX=0 turns it off, to see that failure; it must divide 384000.
#ifndef PANEL_BOUNCE_PX
#define PANEL_BOUNCE_PX 8000
#endif
static_assert(PANEL_BOUNCE_PX == 0 || (800 * 480) % PANEL_BOUNCE_PX == 0, "PANEL_BOUNCE_PX must divide 800 x 480");
// And into an even number of chunks: the vsync restart always starts the DMA at the first bounce buffer, so an odd
// count flips which buffer the interrupt refills every frame, and it refills the one going out (banding).
static_assert(PANEL_BOUNCE_PX == 0 || ((800 * 480) / PANEL_BOUNCE_PX) % 2 == 0,
              "PANEL_BOUNCE_PX must give an even number of chunks a frame");
// Which core runs the panel's interrupts, the bounce copy among them (about 30 MB/s out of PSRAM): 1, LVGL's and the
// loop's, by default; 0 is Wi-Fi's. The panel is created on that core, since its interrupt is allocated there.
#ifndef PANEL_ISR_CORE
#define PANEL_ISR_CORE 1
#endif

namespace {

constexpr uint32_t SWAP_TIMEOUT_MS = 60;  // nearly two frames at 30 Hz: only a stopped panel misses it

constexpr frame_pacing::Timing TIMING = {
    board::LCD_PCLK_HZ,
    board::LCD_WIDTH,
    board::LCD_HEIGHT,
    board::LCD_HSYNC_FRONT_PORCH,
    board::LCD_HSYNC_PULSE_WIDTH,
    board::LCD_HSYNC_BACK_PORCH,
    board::LCD_VSYNC_FRONT_PORCH,
    board::LCD_VSYNC_PULSE_WIDTH,
    board::LCD_VSYNC_BACK_PORCH,
};

#ifdef PANEL_PERF_LOG
// The bounce copy's timing (#635), perf build only: the link wraps memcpy (-Wl,--wrap=memcpy) and the wrapper below
// times the copies of one bounce chunk out of PSRAM, esp_lcd's fill. Every other memcpy pays one compare.
bounce_budget::Meter g_copy(bounce_budget::chunk_ns(TIMING, PANEL_BOUNCE_PX));
portMUX_TYPE g_copy_lock = portMUX_INITIALIZER_UNLOCKED;
// Where the late copies fell (#663), under g_copy_lock: during display_refresh(), and within kTurnUs after a latch.
constexpr uint32_t kTurnUs = 3000;
const uint32_t g_chunk_ns = bounce_budget::chunk_ns(TIMING, PANEL_BOUNCE_PX);  // once, not per copy
volatile bool g_drawing = false;  // set by the loop around its LVGL refresh, read by the copy
uint32_t g_copy_late_drawing = 0;
uint32_t g_copy_late_turn = 0;
// The copy line (#663), under g_copy_lock: every timed copy by eighth after the latch and by the loop's step.
volatile uint8_t g_mark = static_cast<uint8_t>(perf_line::Mark::other);
const uint32_t g_period_us = frame_pacing::frame_us(TIMING);
perf_line::CopySpread g_spread;
// Until when the UART still drains the prints noted (display_note_print), esp_timer us.
volatile uint32_t g_print_until_us = 0;
#endif

lv_display_t* g_disp = nullptr;
esp_lcd_panel_handle_t g_panel = nullptr;
SemaphoreHandle_t g_vsync_sem = nullptr;
// Given at every latch, for the frame clock (#663). Binary: latches the loop missed count as one.
SemaphoreHandle_t g_latch_sem = nullptr;
swap_gate::Gate g_gate;
// Set by the swap, in flush_cb: LVGL's wait right after it, in the same refresh, returns without waiting (#663).
bool g_wait_deferred = false;
// Fed by both panel interrupts (one core), read by the loop: the spinlock keeps a read whole.
scan_watch::Watch g_scan;
portMUX_TYPE g_scan_lock = portMUX_INITIALIZER_UNLOCKED;

// Written only by the vsync interrupt; read without a reset, so no read-modify-write races it.
volatile uint32_t g_vsyncs = 0;

// The latches (#662, #663): written by release_swap() in the panel interrupt under g_scan_lock, read by the loop. A
// latch is where the panel takes the next frame's buffer: the frame-end callback in bounce mode, the vsync without.
uint32_t g_latches = 0;     // running count
uint32_t g_latch_us = 0;    // the last one
#ifdef PANEL_PERF_LOG
uint32_t g_release_us = 0;  // the last latch that released a swap: that frame's start of scan-out
#endif

// LVGL's task only.
struct {
    uint32_t vsyncs_seen;
    uint32_t timeouts_seen;
    uint32_t swaps;
    uint32_t draw_bitmap_us;
    uint32_t flush_wait_us;
} g_perf = {};

// The interrupt isn't IRAM-safe in this core's build (no CONFIG_LCD_RGB_ISR_IRAM_SAFE), so it never runs while the
// flash cache is off, and calling the gate's flash-resident code from here is fine.
bool IRAM_ATTR release_swap() {
    BaseType_t woke = pdFALSE;
    const bool released = g_gate.vsync();
    // Stamps only, before the gives, so a waiter that takes one reads this latch. Its own clock read, a fraction of a
    // microsecond after the caller's.
    const uint32_t now_us = static_cast<uint32_t>(esp_timer_get_time());
    portENTER_CRITICAL_ISR(&g_scan_lock);
    ++g_latches;
    g_latch_us = now_us;
#ifdef PANEL_PERF_LOG
    if (released) g_release_us = now_us;
#endif
    portEXIT_CRITICAL_ISR(&g_scan_lock);
    if (released) xSemaphoreGiveFromISR(g_vsync_sem, &woke);
    return woke == pdTRUE;
}

// Without bounce buffers the next frame reads the new buffer from this vsync on, so it releases the swap. Wakes the
// frame clock (#663), about 1.9 ms after the latch in bounce mode. On the loop's core, so the loop runs only after
// this interrupt ends, the driver's vsync restart included.
bool IRAM_ATTR on_vsync(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*, void*) {
    g_vsyncs = g_vsyncs + 1;
    portENTER_CRITICAL_ISR(&g_scan_lock);
    g_scan.vsync(static_cast<uint32_t>(esp_timer_get_time()));
    portEXIT_CRITICAL_ISR(&g_scan_lock);
    // Without bounce buffers the latch first, so the frame this wakes sees its count.
    const bool woke_by_release = PANEL_BOUNCE_PX == 0 && release_swap();
    BaseType_t woke = pdFALSE;
    xSemaphoreGiveFromISR(g_latch_sem, &woke);
    return woke_by_release || woke == pdTRUE;
}

// With bounce buffers the driver picks the next frame's buffer here, when it has copied the last of this one, not at
// the vsync: a swap between the two would be released while the old buffer still feeds a whole frame.
bool IRAM_ATTR on_frame_buf_complete(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*, void*) {
    portENTER_CRITICAL_ISR(&g_scan_lock);
    g_scan.frame_complete(static_cast<uint32_t>(esp_timer_get_time()));
    portEXIT_CRITICAL_ISR(&g_scan_lock);
    return release_swap();
}

// Direct mode: px_map is the whole hidden framebuffer and LVGL has drawn the area into it in place, so an area before
// the last needs nothing. The last hands the buffer to the panel; flushing stays set until the vsync (flush_wait_cb).
void flush_cb(lv_display_t* disp, const lv_area_t*, uint8_t* px_map) {
    // Read here: LVGL clears the flag at the end of every wait.
    if (g_gate.flush(lv_display_flush_is_last(disp))) {
        lv_display_flush_ready(disp);
        return;
    }
    // The whole frame, not the last area. In bounce mode draw_bitmap only switches buffers: the bounce copy reads
    // through the same cache LVGL wrote to. Without bounce buffers it also writes the cache back over the range given,
    // and every area of this frame, plus what LVGL copied over from the last one, may still be in the cache.
    const int64_t start = esp_timer_get_time();
    // Only bad arguments fail it, and these are fixed; the frame is handed over either way.
    (void)esp_lcd_panel_draw_bitmap(g_panel, 0, 0, board::LCD_WIDTH, board::LCD_HEIGHT, px_map);
    g_perf.draw_bitmap_us += static_cast<uint32_t>(esp_timer_get_time() - start);
    ++g_perf.swaps;
#ifdef PANEL_PERF_LOG
    // The latches so far count as before this swap; taken here, handed to the ledger after the gate is armed, so the
    // ledger adds nothing between the two.
    const DisplayLatch latch = display_latch();
    const uint32_t swapped_us = static_cast<uint32_t>(esp_timer_get_time());
#endif
    // A vsync that came between the last timeout and its waited() left a give behind; drop it, or it releases this
    // frame before its vsync. Nothing can give for this swap until swapped() arms the gate.
    xSemaphoreTake(g_vsync_sem, 0);
    g_gate.swapped();
    g_wait_deferred = true;
#ifdef PANEL_PERF_LOG
    perf_log::frame_swapped(latch.count, latch.us, swapped_us);
#endif
}

// With this set, LVGL calls it instead of spinning on flushing, before every flush and after every frame. Only a swap
// waits; everything else returns at once.
//
// The frame clock (#663): LVGL waits once more right after the swap, in the same refresh (lv_refr.c, before it notes
// the areas to copy over next time; nothing is drawn after it). Waiting there would hold the loop to the next latch
// and leave the chores no time, so that one returns at once, the swap still outstanding. The next wait, before
// anything is drawn or copied into the buffer the panel may still show, comes in the next frame, which starts on a
// latch after the swap (display_wait_latch), so it finds the release already given and takes it at once; it still
// blocks, up to the timeout, if it doesn't, so LVGL never draws into the buffer on glass.
void flush_wait_cb(lv_display_t* disp) {
    if (!g_gate.must_wait()) {
        lv_display_flush_ready(disp);
        return;
    }
    if (g_wait_deferred) {
        g_wait_deferred = false;
        return;  // flushing stays set; with a flush-wait callback LVGL reads it nowhere else
    }
    const int64_t start = esp_timer_get_time();
    const bool got = xSemaphoreTake(g_vsync_sem, pdMS_TO_TICKS(SWAP_TIMEOUT_MS)) == pdTRUE;
    g_perf.flush_wait_us += static_cast<uint32_t>(esp_timer_get_time() - start);
    g_gate.waited(got);
#ifdef PANEL_PERF_LOG
    // The give orders this read after the release's stamp. A timeout has no release: its glass time is unknown.
    if (got) {
        portENTER_CRITICAL(&g_scan_lock);
        const uint32_t release_us = g_release_us;
        portEXIT_CRITICAL(&g_scan_lock);
        perf_log::frame_on_glass(release_us);
    }
#endif
    lv_display_flush_ready(disp);
}

uint32_t tick_cb() { return millis(); }

// Runs inside every esp_restart(). The RGB panel's frame loop and its GDMA keep running through a software reset,
// and the next boot then hung often enough for the RTC watchdog to reset it again (phrasedeck #150). Stop both first.
// The backlight goes off first, so the stopped panel isn't seen. Only esp_restart() runs this: a panic, watchdog or
// brownout reset doesn't.
void stopLcdOnRestart() {
    panel_mcu::backlightOff();
    LCD_CAM.lcd_user.lcd_start = 0;
    esp_rom_delay_us(50000);  // the frame in progress ends (one frame is about 26 ms)
    periph_module_reset(PERIPH_LCD_CAM_MODULE);
    periph_module_reset(PERIPH_GDMA_MODULE);
}

const char* region(const void* p) { return esp_ptr_external_ram(p) ? "PSRAM" : "internal RAM"; }

bool panel_init() {
    esp_lcd_rgb_panel_config_t cfg = {};
    cfg.clk_src = LCD_CLK_SRC_DEFAULT;  // PLL 160 MHz; the LCD clock divider takes fractions, so 12.3 MHz is near
    cfg.timings.pclk_hz = board::LCD_PCLK_HZ;
    cfg.timings.h_res = board::LCD_WIDTH;
    cfg.timings.v_res = board::LCD_HEIGHT;
    cfg.timings.hsync_pulse_width = board::LCD_HSYNC_PULSE_WIDTH;
    cfg.timings.hsync_back_porch = board::LCD_HSYNC_BACK_PORCH;
    cfg.timings.hsync_front_porch = board::LCD_HSYNC_FRONT_PORCH;
    cfg.timings.vsync_pulse_width = board::LCD_VSYNC_PULSE_WIDTH;
    cfg.timings.vsync_back_porch = board::LCD_VSYNC_BACK_PORCH;
    cfg.timings.vsync_front_porch = board::LCD_VSYNC_FRONT_PORCH;
    cfg.timings.flags.hsync_idle_low = PANEL_HSYNC_IDLE_LOW;
    cfg.timings.flags.vsync_idle_low = PANEL_VSYNC_IDLE_LOW;
    cfg.timings.flags.de_idle_high = PANEL_DE_IDLE_HIGH;
    cfg.timings.flags.pclk_active_neg = PANEL_PCLK_ACTIVE_NEG;
    cfg.timings.flags.pclk_idle_high = PANEL_PCLK_IDLE_HIGH;
    cfg.data_width = 16;
    cfg.bits_per_pixel = 16;
    cfg.num_fbs = 2;
    cfg.bounce_buffer_size_px = PANEL_BOUNCE_PX;
    cfg.dma_burst_size = 64;  // the largest burst; it reads the bounce buffers in internal RAM, or PSRAM without them
    cfg.hsync_gpio_num = board::LCD_HSYNC;
    cfg.vsync_gpio_num = board::LCD_VSYNC;
    cfg.de_gpio_num = board::LCD_DE;
    cfg.pclk_gpio_num = board::LCD_PCLK;
    cfg.disp_gpio_num = -1;  // no display-enable line: the companion chip owns power and backlight
    // Bus order as LovyanGFX's pin_d0..d15: blue low, red high.
    const int data[16] = {board::LCD_B0, board::LCD_B1, board::LCD_B2, board::LCD_B3, board::LCD_B4, board::LCD_G0,
                          board::LCD_G1, board::LCD_G2, board::LCD_G3, board::LCD_G4, board::LCD_G5, board::LCD_R0,
                          board::LCD_R1, board::LCD_R2, board::LCD_R3, board::LCD_R4};
    for (int i = 0; i < 16; ++i) cfg.data_gpio_nums[i] = data[i];
    cfg.flags.fb_in_psram = 1;

    esp_err_t err = esp_lcd_new_rgb_panel(&cfg, &g_panel);
    if (err != ESP_OK) {
        Serial.printf("display: esp_lcd_new_rgb_panel failed: %s\n", esp_err_to_name(err));
        return false;
    }
    esp_lcd_rgb_panel_event_callbacks_t cbs = {};
    cbs.on_vsync = on_vsync;
    if (PANEL_BOUNCE_PX > 0) cbs.on_frame_buf_complete = on_frame_buf_complete;
    err = esp_lcd_rgb_panel_register_event_callbacks(g_panel, &cbs, nullptr);
    if (err == ESP_OK) err = esp_lcd_panel_reset(g_panel);
    if (err == ESP_OK) err = esp_lcd_panel_init(g_panel);
    if (err != ESP_OK) {
        Serial.printf("display: panel bring-up failed: %s\n", esp_err_to_name(err));
        esp_lcd_panel_del(g_panel);
        g_panel = nullptr;
        return false;
    }
    return true;
}

// panel_init() on PANEL_ISR_CORE: esp_lcd allocates the panel's interrupts on the core that creates it.
struct CoreInit {
    SemaphoreHandle_t done;
    bool ok;
};

void panel_init_task(void* arg) {
    CoreInit* init = static_cast<CoreInit*>(arg);
    init->ok = panel_init();
    xSemaphoreGive(init->done);
    vTaskDelete(nullptr);
}

bool panel_init_on_core() {
    if (xPortGetCoreID() == PANEL_ISR_CORE) return panel_init();
    CoreInit init = {xSemaphoreCreateBinary(), false};
    if (init.done == nullptr) return false;
    const bool started =
        xTaskCreatePinnedToCore(panel_init_task, "panel_init", 4096, &init, 5, nullptr, PANEL_ISR_CORE) == pdPASS;
    if (started) xSemaphoreTake(init.done, portMAX_DELAY);
    vSemaphoreDelete(init.done);
    if (!started) Serial.println("display: couldn't start the panel on its core");
    return started && init.ok;
}

}  // namespace

bool display_init() {
    // Before the panel: its vsync interrupt starts with esp_lcd_panel_init and gives this.
    g_vsync_sem = xSemaphoreCreateBinary();
    g_latch_sem = xSemaphoreCreateBinary();
    if (g_vsync_sem == nullptr || g_latch_sem == nullptr) {
        Serial.println("display: no memory for the vsync semaphores");
        return false;
    }
    if (!panel_init_on_core()) return false;

    void* fb0 = nullptr;
    void* fb1 = nullptr;
    const esp_err_t err = esp_lcd_rgb_panel_get_frame_buffer(g_panel, 2, &fb0, &fb1);
    if (err != ESP_OK || fb0 == nullptr || fb1 == nullptr) {
        Serial.printf("display: no framebuffers: %s\n", esp_err_to_name(err));
        return false;
    }

    lv_init();
    lv_tick_set_cb(tick_cb);

    g_disp = lv_display_create(board::LCD_WIDTH, board::LCD_HEIGHT);
    if (g_disp == nullptr) {
        Serial.println("display: lv_display_create failed");
        return false;
    }
    lv_display_set_flush_cb(g_disp, flush_cb);
    lv_display_set_flush_wait_cb(g_disp, flush_wait_cb);
    // fb1 first: the panel scans fb0 from the start, so LVGL's first frame goes into the hidden one.
    const uint32_t fb_bytes = static_cast<uint32_t>(board::LCD_WIDTH) * board::LCD_HEIGHT * sizeof(uint16_t);
    lv_display_set_buffers(g_disp, fb1, fb0, fb_bytes, LV_DISPLAY_RENDER_MODE_DIRECT);

    // The frame clock refreshes (#663), never LVGL's timer: deleted, so neither lv_timer_handler() nor an invalidation
    // (which resumes a paused one) can start a refresh off the latch.
    lv_display_delete_refr_timer(g_disp);

    Serial.printf("display: %dx%d up, pclk %u Hz, %u fps, frame %u us, refresh on the frame clock, framebuffers %p %p "
                  "in %s\n",
                  board::LCD_WIDTH, board::LCD_HEIGHT, static_cast<unsigned>(board::LCD_PCLK_HZ),
                  static_cast<unsigned>(frame_pacing::frames_per_second(TIMING)),
                  static_cast<unsigned>(frame_pacing::frame_us(TIMING)), fb0, fb1, region(fb0));
    Serial.printf("display: bounce buffers %d px, panel interrupts on core %d, loop on core %d, clock edge %s\n",
                  PANEL_BOUNCE_PX, PANEL_ISR_CORE, xPortGetCoreID(), PANEL_PCLK_ACTIVE_NEG ? "falling" : "rising");
    if (esp_register_shutdown_handler(stopLcdOnRestart) != ESP_OK) {
        Serial.println("display: couldn't register the restart handler");
    }
    return true;
}

lv_display_t* display_lvgl() { return g_disp; }

scan_watch::Report display_take_scan() {
    portENTER_CRITICAL(&g_scan_lock);
    const scan_watch::Report r = g_scan.take();
    portEXIT_CRITICAL(&g_scan_lock);
    return r;
}

DisplayLatch display_latch() {
    portENTER_CRITICAL(&g_scan_lock);
    const DisplayLatch l = {g_latches, g_latch_us};
    portEXIT_CRITICAL(&g_scan_lock);
    return l;
}

bool display_wait_latch(uint32_t timeout_ms, DisplayLatch& latch) {
    const uint32_t entry = display_latch().count;
    const TickType_t start = xTaskGetTickCount();
    const TickType_t timeout = pdMS_TO_TICKS(timeout_ms);
    for (;;) {
        const TickType_t waited = xTaskGetTickCount() - start;
        if (waited >= timeout) return false;
        // A give from a latch before the entry returns at once; the count says it's old, and the loop waits again.
        if (xSemaphoreTake(g_latch_sem, timeout - waited) != pdTRUE) return false;
        latch = display_latch();
        if (latch.count != entry) return true;
    }
}

void display_refresh() {
    // lv_refr_now() refreshes only through the display's refresh timer, deleted in display_init(); this is the same
    // refresh, on the default display (the only one).
#ifdef PANEL_PERF_LOG
    g_drawing = true;
#endif
    _lv_display_refr_timer(nullptr);
#ifdef PANEL_PERF_LOG
    g_drawing = false;
#endif
}

uint32_t display_frame_us() { return frame_pacing::frame_us(TIMING); }

uint32_t display_copy_budget_us() { return bounce_budget::chunk_ns(TIMING, PANEL_BOUNCE_PX) / 1000u; }

bounce_budget::Report display_take_copy(DisplayCopyLate* where) {
#ifdef PANEL_PERF_LOG
    portENTER_CRITICAL(&g_copy_lock);
    const bounce_budget::Report r = g_copy.take();
    if (where != nullptr) *where = {g_copy_late_drawing, g_copy_late_turn};
    g_copy_late_drawing = 0;
    g_copy_late_turn = 0;
    portEXIT_CRITICAL(&g_copy_lock);
    return r;
#else
    if (where != nullptr) *where = {};
    return {};
#endif
}

#ifdef PANEL_PERF_LOG
void display_mark(perf_line::Mark step) { g_mark = static_cast<uint8_t>(step); }

void display_note_print(uint32_t bytes) {
    // 115200 baud, 10 bits a byte: 87 us each, after whatever is still draining.
    const uint32_t now = static_cast<uint32_t>(esp_timer_get_time());
    const uint32_t from = static_cast<int32_t>(g_print_until_us - now) > 0 ? g_print_until_us : now;
    g_print_until_us = from + bytes * 87u;
}

perf_line::CopySpread display_take_copy_spread() {
    portENTER_CRITICAL(&g_copy_lock);
    const perf_line::CopySpread c = g_spread;
    g_spread = {};
    portEXIT_CRITICAL(&g_copy_lock);
    return c;
}
#endif

DisplayPerf display_take_perf() {
    const uint32_t vsyncs = g_vsyncs;
    const uint32_t timeouts = g_gate.timeouts();
    DisplayPerf p;
    // Differences of running counts, so the interrupt's counter is never written from here.
    p.vsyncs = vsyncs - g_perf.vsyncs_seen;
    p.swap_timeouts = timeouts - g_perf.timeouts_seen;
    p.swaps = g_perf.swaps;
    p.draw_bitmap_us = g_perf.draw_bitmap_us;
    p.flush_wait_us = g_perf.flush_wait_us;
    g_perf = {};
    g_perf.vsyncs_seen = vsyncs;
    g_perf.timeouts_seen = timeouts;
    return p;
}

#ifdef PANEL_PERF_LOG
extern "C" void* __real_memcpy(void* to, const void* from, size_t n);

// In IRAM: memcpy runs everywhere, flash writes included, when the cache is off. Only a copy out of PSRAM, which
// can't happen then, reaches the meter's flash code.
extern "C" IRAM_ATTR void* __wrap_memcpy(void* to, const void* from, size_t n) {
    if (PANEL_BOUNCE_PX == 0 || n != PANEL_BOUNCE_PX * sizeof(uint16_t) || !esp_ptr_external_ram(from) ||
        esp_ptr_external_ram(to)) {
        return __real_memcpy(to, from, n);
    }
    const uint32_t start = esp_cpu_get_cycle_count();
    void* result = __real_memcpy(to, from, n);
    const uint32_t took_us = (esp_cpu_get_cycle_count() - start) / esp_rom_get_cpu_ticks_per_us();
    // Late as the meter counts it: longer than the chunk's deadline. The latch time is one aligned word, written by
    // the panel interrupt on this core. Where the copy fell is taken at its start: its end less its length.
    const bool late = static_cast<uint64_t>(took_us) * 1000u > g_chunk_ns;
    const uint32_t end_us = static_cast<uint32_t>(esp_timer_get_time());
    const uint32_t since_latch_us = end_us - took_us - g_latch_us;
    const bool turn = late && since_latch_us < kTurnUs;
    const bool in_isr = xPortInIsrContext();
    const int phase = perf_line::phase(since_latch_us, g_period_us);
    const uint8_t mark = g_mark;
    const bool printing = static_cast<int32_t>(g_print_until_us - end_us) > 0;
    portENTER_CRITICAL_SAFE(&g_copy_lock);
    g_copy.copied(took_us);
    if (late && g_drawing) ++g_copy_late_drawing;
    if (turn) ++g_copy_late_turn;
    if (!in_isr) {
        ++g_spread.outside_isr;
        if (late) ++g_spread.late_outside_isr;
    } else {
        ++g_spread.copies_by_phase[phase];
        if (mark < perf_line::kMarks) ++g_spread.copies_by_mark[mark];
        if (late) {
            ++g_spread.late_by_phase[phase];
            if (mark < perf_line::kMarks) ++g_spread.late_by_mark[mark];
            if (g_spread.kept < perf_line::CopySpread::kKept) {
                g_spread.lates[g_spread.kept++] = {since_latch_us, took_us, mark};
            }
        }
        if (printing) {
            ++g_spread.while_printing;
            if (late) ++g_spread.late_while_printing;
        }
    }
    portEXIT_CRITICAL_SAFE(&g_copy_lock);
    return result;
}
#endif
