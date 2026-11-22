// The frame ledger (#662): arrival to glass per frame, and the frames that missed a vsync.
#include <unity.h>

#include "frame_ledger.h"

void setUp() {}
void tearDown() {}

void test_a_read_swapped_and_shown_at_the_next_vsync_is_one_frame_with_its_lag() {
    frame_ledger::Ledger ledger;
    ledger.read(1000);
    ledger.swapped(9000);
    ledger.on_glass(21000);
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(1, r.frames);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_typical_us);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_worst_us);
    TEST_ASSERT_EQUAL_UINT32(0, r.skipped);
}

void test_a_read_after_the_swap_is_not_in_that_frame_but_the_next() {
    frame_ledger::Ledger ledger;
    ledger.read(1000);
    ledger.swapped(9000);
    ledger.read(10000);   // too late for the frame already handed over
    ledger.on_glass(21000);
    ledger.swapped(30000);
    ledger.on_glass(46000);
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(2, r.frames);
    TEST_ASSERT_EQUAL_UINT32(36000, r.lag_worst_us);  // 10000 to 46000
}

void test_a_vsync_that_passes_before_the_read_is_handed_over_marks_its_frame_skipped() {
    frame_ledger::Ledger ledger;
    ledger.read(1000);
    ledger.vsync(5000);   // a boundary went by with the read not yet drawn
    ledger.swapped(30000);
    ledger.vsync(40000);
    ledger.on_glass(40000);
    ledger.read(41000);
    ledger.swapped(50000);
    ledger.vsync(65000);
    ledger.on_glass(65000);  // in time: the vsync came after the swap
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(2, r.frames);
    TEST_ASSERT_EQUAL_UINT32(1, r.skipped);
}

void test_lag_counts_from_the_newest_arrival_before_the_read() {
    frame_ledger::Ledger ledger;
    ledger.arrived(500);
    ledger.arrived(800);  // the newest
    ledger.read(1000);
    ledger.swapped(9000);
    ledger.on_glass(21000);
    TEST_ASSERT_EQUAL_UINT32(20200, ledger.take().lag_worst_us);
}

// Under the frame clock (#663) every datagram waits for a latch: the one that wakes the frame that reads it. Arrival
// is stamped where it happens (#664), so the ledger may hear of it after that latch: it goes by the latches' times.
void test_arrival_right_before_the_waking_latch_and_read_after_it_is_not_skipped() {
    frame_ledger::Ledger ledger;
    ledger.vsync(0);
    ledger.vsync(33000);   // the waking latch
    ledger.arrived(32000); // heard of after it, arrived just before it
    ledger.read(34000);
    ledger.swapped(40000);
    ledger.vsync(66000);
    ledger.on_glass(66000);
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(1, r.frames);
    TEST_ASSERT_EQUAL_UINT32(0, r.skipped);
    TEST_ASSERT_EQUAL_UINT32(34000, r.lag_worst_us);
}

void test_arrival_before_the_previous_latch_is_skipped() {
    frame_ledger::Ledger ledger;
    ledger.vsync(0);
    ledger.vsync(33000);   // a frame that could have taken it
    ledger.vsync(66000);   // the waking latch
    ledger.arrived(20000);
    ledger.read(67000);
    ledger.swapped(70000);
    ledger.vsync(99000);
    ledger.on_glass(99000);
    TEST_ASSERT_EQUAL_UINT32(1, ledger.take().skipped);
}

static void frame(frame_ledger::Ledger& ledger, uint32_t read_us, uint32_t lag_us) {
    ledger.read(read_us);
    ledger.swapped(read_us + 1);
    ledger.on_glass(read_us + lag_us);
}

void test_the_typical_lag_is_the_median_of_the_window_and_take_starts_a_new_one() {
    frame_ledger::Ledger ledger;
    const uint32_t lags[] = {10000, 30000, 20000, 90000, 40000};
    uint32_t t = 0;
    for (uint32_t lag : lags) {
        frame(ledger, t, lag);
        t += 100000;
    }
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(5, r.frames);
    TEST_ASSERT_EQUAL_UINT32(30000, r.lag_typical_us);
    TEST_ASSERT_EQUAL_UINT32(90000, r.lag_worst_us);
    const frame_ledger::Report next = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(0, next.frames);
    TEST_ASSERT_EQUAL_UINT32(0, next.lag_typical_us);
    TEST_ASSERT_EQUAL_UINT32(0, next.lag_worst_us);
}

void test_a_read_whose_refresh_drew_nothing_is_no_frame_and_not_a_skip() {
    frame_ledger::Ledger ledger;
    ledger.read(1000);      // e.g. the same bpm again: nothing on screen changes
    ledger.nothing_drawn();
    ledger.vsync(26000);    // nothing waits, so this boundary missed nothing
    ledger.read(30000);
    ledger.swapped(35000);
    ledger.vsync(50000);
    ledger.on_glass(50000);
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(1, r.frames);
    TEST_ASSERT_EQUAL_UINT32(0, r.skipped);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_worst_us);
}

void test_a_window_with_more_frames_than_the_store_still_counts_them_all_and_its_worst() {
    frame_ledger::Ledger ledger;
    uint32_t t = 0;
    for (int i = 0; i < 300; ++i) {
        frame(ledger, t, i == 280 ? 90000 : 20000);  // the worst comes after the store is full
        t += 100000;
    }
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(300, r.frames);
    TEST_ASSERT_EQUAL_UINT32(90000, r.lag_worst_us);
    TEST_ASSERT_EQUAL_UINT32(20000, r.lag_typical_us);
}

// Two arrivals read together: the older one waited across a frame that could have taken it, so the frame is skipped
// even though the newer one came just in time. Lag still counts from the newest (#662).
void test_the_oldest_arrival_since_the_last_read_decides_the_skip() {
    frame_ledger::Ledger ledger;
    ledger.arrived(20000);  // before the latch at 33000
    ledger.vsync(33000);
    ledger.vsync(66000);    // the waking latch
    ledger.arrived(65000);
    ledger.read(67000);
    ledger.swapped(70000);
    ledger.vsync(99000);
    ledger.on_glass(99000);
    const frame_ledger::Report r = ledger.take();
    TEST_ASSERT_EQUAL_UINT32(1, r.skipped);
    TEST_ASSERT_EQUAL_UINT32(34000, r.lag_worst_us);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_read_swapped_and_shown_at_the_next_vsync_is_one_frame_with_its_lag);
    RUN_TEST(test_a_read_after_the_swap_is_not_in_that_frame_but_the_next);
    RUN_TEST(test_a_vsync_that_passes_before_the_read_is_handed_over_marks_its_frame_skipped);
    RUN_TEST(test_lag_counts_from_the_newest_arrival_before_the_read);
    RUN_TEST(test_arrival_right_before_the_waking_latch_and_read_after_it_is_not_skipped);
    RUN_TEST(test_arrival_before_the_previous_latch_is_skipped);
    RUN_TEST(test_the_typical_lag_is_the_median_of_the_window_and_take_starts_a_new_one);
    RUN_TEST(test_a_read_whose_refresh_drew_nothing_is_no_frame_and_not_a_skip);
    RUN_TEST(test_a_window_with_more_frames_than_the_store_still_counts_them_all_and_its_worst);
    RUN_TEST(test_the_oldest_arrival_since_the_last_read_decides_the_skip);
    return UNITY_END();
}
