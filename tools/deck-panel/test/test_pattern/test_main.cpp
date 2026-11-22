// The test screen's color bars (#615): what the panel draws first, to prove the whole 800 x 480 is driven.
#include <unity.h>

#include "test_pattern.h"

void setUp() {}
void tearDown() {}

void test_the_bars_cover_the_whole_width_with_no_gap_or_overlap() {
    const auto bars = test_pattern::bars(800);
    int next = 0;
    for (const auto& bar : bars) {
        TEST_ASSERT_EQUAL(next, bar.x);
        TEST_ASSERT_TRUE(bar.width > 0);
        next = bar.x + bar.width;
    }
    TEST_ASSERT_EQUAL(800, next);
}

void test_a_width_that_does_not_divide_evenly_still_ends_at_the_edge() {
    const auto bars = test_pattern::bars(799);
    const auto& last = bars[bars.size() - 1];
    TEST_ASSERT_EQUAL(799, last.x + last.width);
}

// Red, green, blue first, each pure in RGB565, so a swapped channel on the glass shows at once; then white, black and
// three grays, which a wrong bit order on the bus would tint.
void test_the_bars_are_red_green_blue_white_black_then_grays_in_rgb565() {
    const auto bars = test_pattern::bars(800);
    const uint16_t expected[test_pattern::kBarCount] = {0xF800, 0x07E0, 0x001F, 0xFFFF, 0x0000, 0x8410, 0x4208, 0xC618};
    for (int i = 0; i < test_pattern::kBarCount; ++i) TEST_ASSERT_EQUAL_HEX16(expected[i], bars[i].rgb565);
}

void test_rgb565_keeps_the_top_bits_of_each_channel() {
    TEST_ASSERT_EQUAL_HEX16(0xF800, test_pattern::rgb565(0xFF, 0x00, 0x00));
    TEST_ASSERT_EQUAL_HEX16(0x07E0, test_pattern::rgb565(0x00, 0xFF, 0x00));
    TEST_ASSERT_EQUAL_HEX16(0x001F, test_pattern::rgb565(0x00, 0x00, 0xFF));
    TEST_ASSERT_EQUAL_HEX16(0x8410, test_pattern::rgb565(0x80, 0x80, 0x80));
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_bars_cover_the_whole_width_with_no_gap_or_overlap);
    RUN_TEST(test_a_width_that_does_not_divide_evenly_still_ends_at_the_edge);
    RUN_TEST(test_the_bars_are_red_green_blue_white_black_then_grays_in_rgb565);
    RUN_TEST(test_rgb565_keeps_the_top_bits_of_each_channel);
    return UNITY_END();
}
