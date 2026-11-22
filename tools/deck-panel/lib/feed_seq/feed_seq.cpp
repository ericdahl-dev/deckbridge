#include "feed_seq.h"

namespace feed_seq {

void Counter::saw(uint32_t seq) {
    // How far on from the last, modulo 2^32, so the wrap counts like any other step.
    const uint32_t ahead = seq - last_;
    // The first seen is the baseline (a boot or a join mid-stream). At or below the last (ahead 0, or "behind": more
    // than half the range on) is a restart, a late datagram or a repeat: a new baseline, never a loss.
    if (seen_ && ahead != 0 && ahead < 0x80000000u) lost_ += ahead - 1;
    seen_ = true;
    last_ = seq;
}

uint32_t Counter::lost() const { return lost_; }

bool Counter::seen() const { return seen_; }

}  // namespace feed_seq
