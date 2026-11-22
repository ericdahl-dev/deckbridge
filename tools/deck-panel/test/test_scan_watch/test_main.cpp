// The scan watch (#635): numbers for a picture that jumps. In a healthy scan-out the bounce driver finishes copying a
// frame at the same point after each vsync; when the DMA falls behind or is restarted out of step, that point moves.
#include <unity.h>

#include "scan_watch.h"

void setUp() {}
void tearDown() {}

// 25625 us a frame at 16 MHz; the copy of each frame ends 20000 us after its vsync.
static void steady(scan_watch::Watch& w, uint32_t& t, int frames, uint32_t lag = 20000) {
    for (int i = 0; i < frames; ++i) {
        w.vsync(t);
        w.frame_complete(t + lag);
        t += 25625;
    }
}

void test_a_steady_scan_out_has_one_lag_one_interval_and_no_resyncs() {
    scan_watch::Watch w;
    uint32_t t = 1000;
    steady(w, t, 40);
    const scan_watch::Report r = w.take();
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_min_us);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_max_us);
    TEST_ASSERT_EQUAL_UINT32(25625, r.vsync_min_us);
    TEST_ASSERT_EQUAL_UINT32(25625, r.vsync_max_us);
    TEST_ASSERT_EQUAL_UINT32(0, r.resyncs);
}

void test_a_lag_that_moves_more_than_half_a_millisecond_is_a_resync() {
    scan_watch::Watch w;
    uint32_t t = 1000;
    steady(w, t, 5);
    steady(w, t, 5, 20100);  // jitter: not a resync
    steady(w, t, 5, 20800);  // moved by 700 us: one resync, then steady again
    const scan_watch::Report r = w.take();
    TEST_ASSERT_EQUAL_UINT32(1, r.resyncs);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_min_us);
    TEST_ASSERT_EQUAL_UINT32(20800, r.lag_max_us);
}

void test_a_late_vsync_widens_the_interval() {
    scan_watch::Watch w;
    w.vsync(0);
    w.vsync(25625);
    w.vsync(25625 + 30000);
    const scan_watch::Report r = w.take();
    TEST_ASSERT_EQUAL_UINT32(25625, r.vsync_min_us);
    TEST_ASSERT_EQUAL_UINT32(30000, r.vsync_max_us);
}

void test_take_starts_a_new_window_and_a_frame_end_before_any_vsync_is_ignored() {
    scan_watch::Watch w;
    w.frame_complete(500);
    uint32_t t = 1000;
    steady(w, t, 3);
    w.take();
    const scan_watch::Report empty = w.take();
    TEST_ASSERT_EQUAL_UINT32(0, empty.resyncs);
    TEST_ASSERT_EQUAL_UINT32(0, empty.lag_max_us);
    TEST_ASSERT_EQUAL_UINT32(0, empty.vsync_max_us);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_steady_scan_out_has_one_lag_one_interval_and_no_resyncs);
    RUN_TEST(test_a_lag_that_moves_more_than_half_a_millisecond_is_a_resync);
    RUN_TEST(test_a_late_vsync_widens_the_interval);
    RUN_TEST(test_take_starts_a_new_window_and_a_frame_end_before_any_vsync_is_ignored);
    return UNITY_END();
}
