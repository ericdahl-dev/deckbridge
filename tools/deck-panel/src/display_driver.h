// Panel bring-up for the Elecrow CrowPanel Advance 7.0-HMI. From phrasedeck's display_driver (#615), moved onto
// ESP-IDF's esp_lcd RGB driver for #635; see LICENSE.crowpanel-drivers.
//
// Drives the 800x480 16-bit RGB565 IPS panel with two full framebuffers in PSRAM. LVGL draws straight into the hidden
// one (direct mode), and the panel switches to it at the next vsync, so a frame is never shown half drawn. It does
// NOT own the backlight: that's an I2C command to the companion chip (panel_mcu.h). Every pin, timing and clock value
// comes from board_pins.h.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#pragma once

#include <cstdint>

#include <lvgl.h>

#include "bounce_budget.h"
#ifdef PANEL_PERF_LOG
#include "perf_line.h"
#endif
#include "scan_watch.h"

#include "board_pins.h"

// Initializes LVGL, brings up the panel and its two framebuffers and registers the LVGL display, with a
// millis()-backed tick. Does NOT turn the backlight on. LVGL's own refresh timer is deleted: the frame clock (#663)
// refreshes with display_refresh(), once a frame, and lv_timer_handler() only runs LVGL's other timers.
//
// Returns false if the panel or its PSRAM framebuffers failed: fatal, there is nothing to draw on. Two frames at
// 800x480x16 bpp are 1.5 MB and can't come from internal SRAM, so a build without octal PSRAM fails here.
bool display_init();

// The LVGL display registered by display_init(), or nullptr before it runs.
lv_display_t* display_lvgl();

// What the panel did since the last call, for a performance log. Call it from LVGL's task (the loop).
struct DisplayPerf {
    uint32_t vsyncs;          // frames the panel scanned out
    uint32_t swaps;           // frames LVGL finished and handed over
    uint32_t swap_timeouts;   // swaps whose vsync didn't come within 60 ms
    uint32_t draw_bitmap_us;  // time in esp_lcd_panel_draw_bitmap (the swap; and the cache write-back without bounce)
    uint32_t flush_wait_us;   // time LVGL waited for a swap's vsync
};
DisplayPerf display_take_perf();

// The scan-out's steadiness since the last call (lib/scan_watch): vsync-to-frame-end lag, vsync spread, resyncs.
// Bounce mode only: without bounce buffers the frame-end callback isn't registered.
scan_watch::Report display_take_scan();

// A bounce chunk's deadline, and (perf build only) the copies timed against it since the last call; no chunks
// otherwise.
uint32_t display_copy_budget_us();
// Of the late copies (#663): those during display_refresh(), and those within 3 ms after a latch (the frame turn).
struct DisplayCopyLate {
    uint32_t drawing;
    uint32_t turn;
};
bounce_budget::Report display_take_copy(DisplayCopyLate* where = nullptr);

#ifdef PANEL_PERF_LOG
// The loop's step, for the copy line (#663), perf build only: the bounce copy files itself under the step its
// interrupt broke into. Loop task only.
void display_mark(perf_line::Mark step);
// The bounce copies since the last call, by eighth of the scan-out after the latch and by loop step.
perf_line::CopySpread display_take_copy_spread();
// A print of `bytes` went to Serial: copies while the UART drains it are counted apart. Loop task only.
void display_note_print(uint32_t bytes);
#endif

// Latches so far, where the panel takes the next frame's buffer (frame end in bounce mode, vsync without), and the
// last one's time in esp_timer microseconds (low 32 bits). The frame clock's boundary (#663) and the frame ledger's
// (#662). Any task.
struct DisplayLatch {
    uint32_t count;
    uint32_t us;
};
DisplayLatch display_latch();

// The frame clock's wait (#663), loop task only: blocks until a latch newer than the one current on entry and the
// vsync after it (about 1.9 ms later in bounce mode; without bounce buffers they're one interrupt), and
// returns the newest (several since the last call count as one), or false after `timeout_ms` with none. A latch
// left over from before the call never ends it, so a frame always starts just after a latch, and a swap handed over
// before the call is always released by the latch that ends it.
bool display_wait_latch(uint32_t timeout_ms, DisplayLatch& latch);

// One LVGL refresh, loop task only: draws what's invalid and hands the frame to the panel, without waiting for its
// release (the next frame's first wait collects that). Nothing invalid: no flush, and LVGL's REFR_READY still comes.
void display_refresh();

// One scan-out, from the pixel clock and porches.
uint32_t display_frame_us();
