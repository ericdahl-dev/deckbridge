#include "feed_seq.h"

namespace feed_seq {

void Counter::saw(uint32_t seq) {
    // How far on from the last, and how far behind it, modulo 2^32, so the wrap counts like any other step.
    const uint32_t ahead = seq - last_, behind = last_ - seq;
    if (!seen_) {
        // The first seen is the baseline: a boot, or a join mid-stream.
    } else if (ahead == 0) {
        return;  // a repeat
    } else if (behind <= kLate && seq != 1) {
        // A little behind: a datagram that came late, already counted lost when the one after it came. Not a restart.
        if (lost_ > 0) --lost_;
        return;
    } else if (ahead < 0x80000000u) {
        lost_ += ahead - 1;
    }
    // Else further behind, or 1 again: the feed reopened or DeckBridge restarted. A new baseline, never a loss.
    seen_ = true;
    last_ = seq;
}

uint32_t Counter::lost() const { return lost_; }

bool Counter::seen() const { return seen_; }

}  // namespace feed_seq
