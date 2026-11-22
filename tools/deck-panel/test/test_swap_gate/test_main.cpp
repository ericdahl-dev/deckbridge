// The handshake between LVGL's flush and the panel's vsync (#635). LVGL draws a frame into the hidden framebuffer;
// on the frame's last area the driver hands that buffer to the panel, which shows it from the next vsync. LVGL must
// not draw into it again until that vsync has passed, or the drawing shows half-done: the tearing this fixes.
#include <unity.h>

#include "swap_gate.h"

void setUp() {}
void tearDown() {}

void test_an_area_before_the_last_is_released_at_once_with_no_wait() {
    swap_gate::Gate gate;
    TEST_ASSERT_TRUE(gate.flush(false));
    TEST_ASSERT_FALSE(gate.must_wait());
}

void test_the_last_area_is_held_until_a_vsync_after_the_swap() {
    swap_gate::Gate gate;
    TEST_ASSERT_FALSE(gate.flush(true));  // not released yet: the driver hands over the buffer, then arms
    gate.swapped();
    TEST_ASSERT_TRUE(gate.must_wait());
    TEST_ASSERT_TRUE(gate.vsync());   // this vsync releases the wait
    TEST_ASSERT_FALSE(gate.vsync());  // and only this one
    gate.waited(true);
    TEST_ASSERT_FALSE(gate.must_wait());
}

void test_a_vsync_before_the_swap_releases_nothing() {
    swap_gate::Gate gate;
    TEST_ASSERT_FALSE(gate.vsync());
    gate.flush(true);
    TEST_ASSERT_FALSE(gate.vsync());  // the buffer isn't handed over yet
    gate.swapped();
    TEST_ASSERT_TRUE(gate.vsync());
}

void test_a_wait_that_times_out_is_released_and_counted() {
    swap_gate::Gate gate;
    gate.flush(true);
    gate.swapped();
    gate.waited(false);
    TEST_ASSERT_FALSE(gate.must_wait());
    TEST_ASSERT_EQUAL_UINT32(1, gate.timeouts());
    TEST_ASSERT_FALSE(gate.vsync());  // a late vsync after the timeout releases nothing stale
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_an_area_before_the_last_is_released_at_once_with_no_wait);
    RUN_TEST(test_the_last_area_is_held_until_a_vsync_after_the_swap);
    RUN_TEST(test_a_vsync_before_the_swap_releases_nothing);
    RUN_TEST(test_a_wait_that_times_out_is_released_and_counted);
    return UNITY_END();
}
