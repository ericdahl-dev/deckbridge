#include "test_pattern.h"

namespace test_pattern {

namespace {

struct Rgb {
    uint8_t r, g, b;
};

// Red, green, blue, white, black, then grays at half, a quarter and three quarters.
constexpr Rgb kColors[kBarCount] = {
    {0xFF, 0x00, 0x00}, {0x00, 0xFF, 0x00}, {0x00, 0x00, 0xFF}, {0xFF, 0xFF, 0xFF},
    {0x00, 0x00, 0x00}, {0x80, 0x80, 0x80}, {0x40, 0x40, 0x40}, {0xC0, 0xC0, 0xC0},
};

}  // namespace

std::array<Bar, kBarCount> bars(int width) {
    std::array<Bar, kBarCount> out{};
    // Each edge is rounded from the whole width, so the last bar ends exactly at the edge.
    for (int i = 0; i < kBarCount; ++i) {
        const int left = width * i / kBarCount;
        const int right = width * (i + 1) / kBarCount;
        const Rgb& c = kColors[i];
        out[i] = {left, right - left, c.r, c.g, c.b, rgb565(c.r, c.g, c.b)};
    }
    return out;
}

}  // namespace test_pattern
