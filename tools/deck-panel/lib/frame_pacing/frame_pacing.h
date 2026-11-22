// The panel's frame timing (#635), from its pixel clock and porches. Kept free of Arduino so it's host-tested.
#pragma once

#include <cstdint>

namespace frame_pacing {

struct Timing {
    uint32_t pclk_hz;
    int width, height;
    int h_front, h_pulse, h_back;
    int v_front, v_pulse, v_back;
};

// One scanned-out frame, in microseconds (rounded down).
uint32_t frame_us(const Timing& t);

// Whole frames a second (rounded down).
uint32_t frames_per_second(const Timing& t);

// LVGL's refresh period: the whole milliseconds that fit in one frame, so each refresh finds the last swap done.
uint32_t refresh_period_ms(const Timing& t);

}  // namespace frame_pacing
