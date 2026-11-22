// How often the panel scans out a frame, and how often LVGL should refresh to match it (#635). The panel's vsync is
// where the two framebuffers swap, so a refresh period longer than a frame skips vsyncs unevenly (1 and 2 at 33 ms).
#include <unity.h>

#include "frame_pacing.h"

void setUp() {}
void tearDown() {}

// The CrowPanel Advance 7.0: 800x480, porches 8 front, 4 pulse, 8 back on both axes, so 820 x 500 clocks a frame.
static frame_pacing::Timing panel(uint32_t pclk_hz) { return {pclk_hz, 800, 480, 8, 4, 8, 8, 4, 8}; }

void test_at_16_mhz_a_frame_is_25625_us_39_hz() {
    TEST_ASSERT_EQUAL_UINT32(25625, frame_pacing::frame_us(panel(16000000)));
    TEST_ASSERT_EQUAL_UINT32(39, frame_pacing::frames_per_second(panel(16000000)));
}

void test_lvgl_refreshes_every_whole_ms_within_a_frame() {
    TEST_ASSERT_EQUAL_UINT32(25, frame_pacing::refresh_period_ms(panel(16000000)));
    TEST_ASSERT_EQUAL_UINT32(29, frame_pacing::refresh_period_ms(panel(14000000)));  // 29286 us
    TEST_ASSERT_EQUAL_UINT32(33, frame_pacing::refresh_period_ms(panel(12300000)));  // 33333 us, the 30 Hz floor
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_at_16_mhz_a_frame_is_25625_us_39_hz);
    RUN_TEST(test_lvgl_refreshes_every_whole_ms_within_a_frame);
    return UNITY_END();
}
