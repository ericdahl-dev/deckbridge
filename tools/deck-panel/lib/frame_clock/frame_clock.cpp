#include "frame_clock.h"

namespace frame_clock {

void Clock::step(Board& board) {
    uint32_t count = 0;
    uint32_t us = 0;
    if (!board.wait_latch(count, us)) {
        ++report_.no_latch;
        board.chores(us + period_us_ - guard_us_);
        return;
    }
    if (started_ && count - last_count_ > 1) {
        // The last frame's draw ran past a latch: the board hands the newest one, so nothing queues up behind it.
        ++report_.late;
        report_.missed += count - last_count_ - 1;
    }
    started_ = true;
    last_count_ = count;
    ++report_.frames;
    board.read_feed();
    board.render();
    board.refresh();
    board.chores(us + period_us_ - guard_us_);
}

Report Clock::take() {
    const Report r = report_;
    report_ = {};
    return r;
}

}  // namespace frame_clock
