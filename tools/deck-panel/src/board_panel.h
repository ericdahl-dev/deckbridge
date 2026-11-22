// The panel under the scan on the board (#666): lib/panel_scan's Panel seam on ESP-IDF's esp_lcd RGB driver. It brings
// the panel up, routes esp_lcd's interrupts into the Scan, and gives the Scan its semaphores, clock and lock. Board
// only, not host-tested: the Scan above it is (test/test_panel_scan, against a scripted panel with the same contract).
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#pragma once

#include <cstdint>

#include <esp_lcd_panel_rgb.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "board_pins.h"
#include "panel_scan.h"

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
// count flips which buffer the interrupt refills every frame, and it refills the one going out (banding). The Scan
// refuses it too, at run time.
static_assert(PANEL_BOUNCE_PX == 0 || ((800 * 480) / PANEL_BOUNCE_PX) % 2 == 0,
              "PANEL_BOUNCE_PX must give an even number of chunks a frame");
// Which core runs the panel's interrupts, the bounce copy among them (about 30 MB/s out of PSRAM): 1, LVGL's and the
// loop's, by default; 0 is Wi-Fi's. The panel is created on that core, since its interrupt is allocated there.
#ifndef PANEL_ISR_CORE
#define PANEL_ISR_CORE 1
#endif

class BoardPanel : public panel_scan::Panel {
  public:
    /// Where the interrupts go. Before Scan::start, which calls start() below.
    void route(panel_scan::Scan* scan) { scan_ = scan; }

    // The seam. give() runs in the panel interrupt (from a task too, though the Scan never does); take() and drop()
    // on the loop; lock() from both.
    bool start(const panel_scan::Config& config) override;
    void hand_over() override;
    void give(panel_scan::Signal signal) override;
    void drop(panel_scan::Signal signal) override;
    bool take(panel_scan::Signal signal, uint32_t timeout_ms) override;
    uint64_t now() const override;
    void lock() override;
    void unlock() override;

    /// The framebuffer LVGL drew, for the next hand_over(): flush_cb's px_map. Loop only.
    void set_frame(void* px_map) { frame_ = px_map; }
    /// The panel's two framebuffers, in PSRAM. After start().
    bool frame_buffers(void** fb0, void** fb1) const;

    /// Time in esp_lcd_panel_draw_bitmap since the last call. Loop only.
    uint32_t take_draw_bitmap_us() {
        const uint32_t us = draw_bitmap_us_;
        draw_bitmap_us_ = 0;
        return us;
    }
    /// The latches as the last hand_over() found them, just after its draw_bitmap, and when (esp_timer us): the frame
    /// ledger's swap (#662). Loop only.
    const panel_scan::Latches& swap_latches() const { return swap_latches_; }
    uint32_t swapped_us() const { return swapped_us_; }
    /// The latch that last released a swap (low 32 bits, esp_timer us), that frame's start of scan-out. Read after a
    /// take of Signal::release, which orders it after the write.
    uint32_t release_us() const { return release_us_; }
    /// The last latch's low 32 bits, one aligned word written by the panel interrupt: for the perf build's copy
    /// wrapper, which runs inside that interrupt for every chunk and so reads it without the lock.
    uint32_t latch_us() const { return latch_us_; }

  private:
    // The esp_lcd callbacks, in IRAM, on PANEL_ISR_CORE: stamp, call the Scan, return whether a give woke a task.
    static bool on_vsync(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*, void* ctx);
    static bool on_frame_buf_complete(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*, void* ctx);
    bool take_woken() {
        const bool woke = woken_ == pdTRUE;
        woken_ = pdFALSE;
        return woke;
    }
    static void init_task(void* arg);
    bool init();
    bool init_on_core();

    panel_scan::Scan* scan_ = nullptr;
    panel_scan::Config config_{};
    esp_lcd_panel_handle_t panel_ = nullptr;
    // Static storage, no heap: one binary semaphore per panel_scan::Signal.
    StaticSemaphore_t sem_store_[3] = {};
    SemaphoreHandle_t sem_[3] = {nullptr, nullptr, nullptr};
    portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
    // Set by give()'s FromISR calls, read and cleared by the callback on its way out. The vsync callback comes from
    // the LCD interrupt and the frame end from the GDMA's (the bounce fill), which may nest: only ever set inside,
    // and cleared on exit, so a nested callback's exit can't drop the outer one's wake (the outer's yield is then
    // already asked for by the inner).
    BaseType_t woken_ = pdFALSE;
    volatile uint32_t latch_us_ = 0;
    volatile uint32_t release_us_ = 0;
    // The loop's.
    void* frame_ = nullptr;
    uint32_t draw_bitmap_us_ = 0;
    panel_scan::Latches swap_latches_{};
    uint32_t swapped_us_ = 0;
};
