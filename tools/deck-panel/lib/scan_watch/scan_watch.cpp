#include "scan_watch.h"

namespace scan_watch {
namespace {

void widen(bool& seen, uint32_t& lo, uint32_t& hi, uint32_t v) {
    if (!seen || v < lo) lo = v;
    if (!seen || v > hi) hi = v;
    seen = true;
}

}  // namespace

// Unsigned subtraction throughout, so the microsecond counter's wrap is no jump.
void Watch::vsync(uint32_t now_us) {
    if (have_vsync_) widen(window_interval_, window_.vsync_min_us, window_.vsync_max_us, now_us - last_vsync_us_);
    last_vsync_us_ = now_us;
    have_vsync_ = true;
}

void Watch::frame_complete(uint32_t now_us) {
    if (!have_vsync_) return;
    const uint32_t lag = now_us - last_vsync_us_;
    if (have_lag_) {
        const uint32_t moved = lag > last_lag_us_ ? lag - last_lag_us_ : last_lag_us_ - lag;
        if (moved > kResyncUs) ++window_.resyncs;
    }
    widen(window_lag_, window_.lag_min_us, window_.lag_max_us, lag);
    last_lag_us_ = lag;
    have_lag_ = true;
}

Report Watch::take() {
    const Report r = window_;
    window_ = Report{};
    window_lag_ = window_interval_ = false;
    return r;
}

}  // namespace scan_watch
