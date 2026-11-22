// The test screen's color bars (#615). Kept free of Arduino and LVGL so it's host-tested.
#pragma once

#include <array>
#include <cstdint>

namespace test_pattern {

struct Bar {
    int x;
    int width;
    uint8_t r, g, b;  // what LVGL is asked for
    uint16_t rgb565;  // what reaches the panel's 16-bit bus
};

// The panel's RGB565: the top 5 bits of red, 6 of green and 5 of blue.
constexpr uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return static_cast<uint16_t>(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

constexpr int kBarCount = 8;

std::array<Bar, kBarCount> bars(int width);

}  // namespace test_pattern
