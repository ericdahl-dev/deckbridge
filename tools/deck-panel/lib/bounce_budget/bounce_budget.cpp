#include "bounce_budget.h"

namespace bounce_budget {

uint32_t chunk_ns(const frame_pacing::Timing& t, uint32_t bounce_px) {
    const uint64_t line_clocks = static_cast<uint64_t>(t.width + t.h_front + t.h_pulse + t.h_back);
    const uint64_t lines = bounce_px / static_cast<uint32_t>(t.width);
    return static_cast<uint32_t>(lines * line_clocks * 1000000000ull / t.pclk_hz);
}

void Meter::copied(uint32_t took_us) {
    ++window_.chunks;
    if (took_us > window_.worst_us) window_.worst_us = took_us;
    if (static_cast<uint64_t>(took_us) * 1000u > budget_ns_) ++window_.late;
    if (static_cast<uint64_t>(took_us) * 1000u > 2ull * budget_ns_) ++window_.past_glass;
}

Report Meter::take() {
    Report r = window_;
    // Floor, so a margin of -0.5 us reads -1, never 0: an underrun never rounds to "fine".
    const int64_t margin_ns = static_cast<int64_t>(budget_ns_) - static_cast<int64_t>(r.worst_us) * 1000;
    r.margin_us = static_cast<int32_t>(margin_ns >= 0 ? margin_ns / 1000 : -((-margin_ns + 999) / 1000));
    window_ = Report{};
    return r;
}

}  // namespace bounce_budget
