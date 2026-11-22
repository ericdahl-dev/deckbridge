#include "frame_ledger.h"

#include <algorithm>

namespace frame_ledger {

void Ledger::arrived(uint32_t us) {
    if (!arrived_) oldest_us_ = us;
    arrived_ = true;
    arrived_us_ = us;
}

void Ledger::read(uint32_t us) {
    if (!waiting_) waiting_late_ = false;
    // The latch before the waking one came after the arrival: a frame went by that could have taken it. Signed, so a
    // wrapped clock compares right.
    if (arrived_ && latches_told_ == kLatches && static_cast<int32_t>(latches_[1] - oldest_us_) > 0) {
        waiting_late_ = true;
    }
    waiting_ = true;
    waiting_us_ = arrived_ ? arrived_us_ : us;
    arrived_ = false;
}

void Ledger::swapped(uint32_t) {
    if (!waiting_) return;
    waiting_ = false;
    in_flight_ = true;
    in_flight_us_ = waiting_us_;
    in_flight_late_ = waiting_late_;
}

void Ledger::nothing_drawn() { waiting_ = false; }

void Ledger::vsync(uint32_t us) {
    latches_[1] = latches_[0];
    latches_[0] = us;
    if (latches_told_ < kLatches) ++latches_told_;
    if (waiting_) waiting_late_ = true;
}

void Ledger::on_glass(uint32_t us) {
    if (!in_flight_) return;
    in_flight_ = false;
    const uint32_t lag = us - in_flight_us_;
    ++report_.frames;
    if (in_flight_late_) ++report_.skipped;
    if (stored_ < kCapacity) lags_[stored_++] = lag;
    if (lag > report_.lag_worst_us) report_.lag_worst_us = lag;
}

Report Ledger::take() {
    Report r = report_;
    if (stored_ > 0) {
        uint32_t* middle = lags_ + stored_ / 2;
        std::nth_element(lags_, middle, lags_ + stored_);
        r.lag_typical_us = *middle;
    }
    report_ = {};
    stored_ = 0;
    return r;
}

}  // namespace frame_ledger
