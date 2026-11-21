// The panel's one frame clock (#663): the panel's scan drives the frame. The loop wakes at a latch (where the panel
// takes the next frame's buffer), reads the feed that came since the last frame, renders, refreshes once (which draws
// and swaps), then runs the chores (touch, Wi-Fi, serial) only until a deadline before the next latch. Kept free of
// Arduino so it's host-tested; times are microseconds on one clock and may wrap.
#pragma once

#include <cstdint>

namespace frame_clock {

/// The board, as the clock sees it. Faked in the tests.
struct Board {
    virtual ~Board() = default;
    /// Blocks until the next latch; false if none came in time. `count` is the running latch count, `us` its time
    /// (on a timeout, the time the wait gave up).
    virtual bool wait_latch(uint32_t& count, uint32_t& us) = 0;
    virtual void read_feed() = 0;
    virtual void render() = 0;
    /// Draws what changed and hands the frame to the panel.
    virtual void refresh() = 0;
    /// Touch, Wi-Fi, serial: must return by `until_us`.
    virtual void chores(uint32_t until_us) = 0;
};

struct Report {
    uint32_t frames = 0;  // frames run
    uint32_t late = 0;    // frames whose draw ran past the next latch
    uint32_t missed = 0;  // latches that went by with no frame started on them
    uint32_t no_latch = 0;  // waits that timed out: no frame, chores only
};

class Clock {
  public:
    /// `period_us`: one scan-out. `guard_us`: how long before the next latch the chores must be done.
    Clock(uint32_t period_us, uint32_t guard_us) : period_us_(period_us), guard_us_(guard_us) {}

    /// One frame: waits for a latch, then reads, renders, refreshes, and runs the chores.
    void step(Board& board);
    /// The counts since the last take(), and a fresh window.
    Report take();

  private:
    uint32_t period_us_;
    uint32_t guard_us_;
    bool started_ = false;
    uint32_t last_count_ = 0;  // the latch the last frame woke on
    Report report_;
};

}  // namespace frame_clock
