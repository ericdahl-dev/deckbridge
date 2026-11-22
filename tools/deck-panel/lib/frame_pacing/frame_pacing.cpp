#include "frame_pacing.h"

namespace frame_pacing {
namespace {

uint64_t clocks_per_frame(const Timing& t) {
    const uint64_t line = static_cast<uint64_t>(t.width + t.h_front + t.h_pulse + t.h_back);
    const uint64_t lines = static_cast<uint64_t>(t.height + t.v_front + t.v_pulse + t.v_back);
    return line * lines;
}

}  // namespace

uint32_t frame_us(const Timing& t) { return static_cast<uint32_t>(clocks_per_frame(t) * 1000000u / t.pclk_hz); }

uint32_t frames_per_second(const Timing& t) { return static_cast<uint32_t>(t.pclk_hz / clocks_per_frame(t)); }

uint32_t refresh_period_ms(const Timing& t) { return frame_us(t) / 1000u; }

}  // namespace frame_pacing
