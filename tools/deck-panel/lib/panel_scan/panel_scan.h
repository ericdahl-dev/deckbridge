// The panel's scan (#666): its timing, the two framebuffers' swaps, the frame boundaries the frame clock waits on, and
// the health of it all, in one module. Inside: frame_pacing (the timing), swap_gate (the swap handshake), scan_watch
// (vsync and frame-end steadiness) and bounce_budget (the copy's deadline). Under it, a Panel: esp_lcd on the board, a
// scripted timeline in the tests. Kept free of Arduino, FreeRTOS and esp_lcd, so it's host-tested.
#pragma once

#include <cstdint>

#include "bounce_budget.h"
#include "frame_pacing.h"
#include "scan_watch.h"
#include "swap_gate.h"

namespace panel_scan {

/// What the panel is started with.
struct Config {
    frame_pacing::Timing timing;
    /// Pixels per bounce chunk, copied out of PSRAM by an interrupt; 0 for none (the GDMA reads the framebuffers).
    uint32_t bounce_px;
};

/// What the loop waits on: a swap's release, a latch (where the panel takes the next frame's buffer), a vsync.
enum class Signal { release = 0, latch = 1, vsync = 2 };

/// The latches so far (#663, #664): the running count, and the last two in esp_timer microseconds (previous_us 0
/// until there are two), so a reader that missed some still sees the real one before the last.
struct Latches {
    uint32_t count = 0;
    uint64_t us = 0;
    uint64_t previous_us = 0;
};

/// The scan's health since the last look.
struct Health {
    uint32_t vsyncs = 0;         ///< frames the panel scanned out
    uint32_t latches = 0;        ///< where it took the next buffer (frame ends with bounce buffers)
    uint32_t swaps = 0;          ///< frames handed over
    uint32_t swap_timeouts = 0;  ///< swaps whose release didn't come in time
    scan_watch::Report scan;     ///< vsync-to-frame-end lag, vsync spread, resyncs
    bounce_budget::Report copy;  ///< the copies timed (perf build): worst, margin, late
    uint32_t copy_late_drawing = 0;  ///< of the late, those while the loop drew (#663)
    uint32_t copy_late_turn = 0;     ///< of the late, the rest that started within kTurnUs after a latch
};

/// How LVGL's flush wait ended. released and timed_out: call lv_display_flush_ready (a timeout is counted).
/// deferred: don't; the swap is still out, and the next frame's first wait collects it.
enum class Wait { released, deferred, timed_out };

/// The panel under the scan: esp_lcd and two binary semaphores on the board, a timeline in the tests.
struct Panel {
    virtual ~Panel() = default;
    virtual bool start(const Config& config) = 0;
    /// The hidden framebuffer, drawn, goes to the panel (esp_lcd_panel_draw_bitmap).
    virtual void hand_over() = 0;
    /// From an interrupt: wakes a take of `signal`. Binary: several before a take count as one.
    virtual void give(Signal signal) = 0;
    /// Clears a give no one took.
    virtual void drop(Signal signal) = 0;
    /// Loop only: blocks until `signal` is given or `timeout_ms` passes.
    virtual bool take(Signal signal, uint32_t timeout_ms) = 0;
    /// Microseconds, on the clock the interrupts stamp with (esp_timer_get_time).
    virtual uint64_t now() const = 0;
    /// Around what the interrupts and the tasks share (a spinlock on the board, which works from both).
    virtual void lock() = 0;
    virtual void unlock() = 0;
};

class Scan {
  public:
    explicit Scan(Panel& panel) : panel_(panel) {}

    /// Checks the config and starts the panel. False, and the panel untouched, for a bounce size that isn't an even
    /// number of chunks a frame (an odd count makes the copy refill the buffer going out: #635's banding).
    bool start(const Config& config);
    /// One scan-out, and a bounce chunk's deadline (0 without bounce buffers).
    uint32_t frame_us() const { return frame_us_; }
    uint32_t copy_budget_us() const { return copy_budget_us_; }

    /// LVGL's flush, one area drawn. True: release it at once (lv_display_flush_ready). False: it was the frame's last,
    /// now handed to the panel, out until its release.
    bool present(bool last_area);
    /// LVGL's flush wait. The first one after a swap, in the same refresh (#663), is deferred: blocking there would hold
    /// the loop to the next latch and starve the chores. The next blocks until the release, at most `timeout_ms`. With
    /// no swap out, released at once.
    Wait wait_release(uint32_t timeout_ms);

    /// The frame clock's wait (#663): until a latch newer than the one current on entry, so a give left from before the
    /// call never starts a frame. False after `timeout_ms` with none.
    bool wait_next_frame(uint32_t timeout_ms, Latches& latch);
    /// The other wake (#679): until the vsync after `latch`, at once if it came already (without bounce buffers the
    /// latch is a vsync, so at once). False after `timeout_ms`.
    bool wait_vsync_after(const Latches& latch, uint32_t timeout_ms);
    /// The frame clock's wait in one wake (#666): until the vsync after a latch newer than the one current on entry (the
    /// two waits above as one, so the loop isn't woken between the latch and the draw). Without bounce buffers the latch
    /// is the vsync. `latch` is that latch. False after `timeout_ms`.
    bool wait_frame(uint32_t timeout_ms, Latches& latch);
    /// The latch stamp, for any task.
    Latches latches() const;
    /// The health since the last call, and a fresh window. Loop only.
    Health take_health();

    /// The frame turn (#663): a late copy this soon after a latch is counted there.
    static constexpr uint32_t kTurnUs = 3000;

    /// The panel's interrupts: stamp and count only.
    void vsync(uint64_t now_us);
    void frame_complete(uint64_t now_us);
    /// A bounce chunk copied in `took_us`, ending at `now_us`, `drawing` if the loop was in its refresh (perf build).
    void copied(uint32_t took_us, uint64_t now_us, bool drawing);

  private:
    /// Where the panel takes the next frame's buffer: frame complete with bounce buffers, the vsync without.
    void latch(uint64_t now_us);

    Panel& panel_;
    swap_gate::Gate gate_;
    bool defer_ = false;  ///< set by a swap: its first wait returns at once
    // Written by the interrupts, read by the tasks, under the Panel's lock.
    Latches latches_;
    uint64_t vsync_us_ = 0;
    uint32_t vsyncs_ = 0;
    scan_watch::Watch watch_;
    bounce_budget::Meter meter_{0};
    uint32_t copy_late_drawing_ = 0, copy_late_turn_ = 0;
    // The loop's: swaps, and what the last look saw of the running counts.
    uint32_t swaps_ = 0;
    uint32_t seen_vsyncs_ = 0, seen_latches_ = 0, seen_timeouts_ = 0;
    Config config_{};
    uint32_t frame_us_ = 0;
    uint32_t copy_budget_us_ = 0;
    uint32_t copy_budget_ns_ = 0;
};

/// One health window looked at in parts (#666): the perf line takes the counts, the scan and the copy one after another,
/// each through its own driver call. Each part comes from the window once; looking at a part again takes a new window,
/// and what of the old one wasn't looked at is gone. Loop only.
class HealthLooks {
  public:
    enum class Part { counts = 0, scan = 1, copy = 2 };
    const Health& look(Scan& scan, Part part);

  private:
    Health health_;
    bool looked_[3] = {true, true, true};
};

}  // namespace panel_scan
