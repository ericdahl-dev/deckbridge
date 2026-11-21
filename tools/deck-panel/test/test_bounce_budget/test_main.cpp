// The bounce copy's budget (#635): each 10-line chunk must be copied out of PSRAM before the DMA, sending the other
// buffer, comes back for it. At 16 MHz it wasn't, and every 10th row showed a stale end.
#include <unity.h>

#include "bounce_budget.h"

void setUp() {}
void tearDown() {}

static frame_pacing::Timing panel(uint32_t pclk_hz) { return {pclk_hz, 800, 480, 8, 4, 8, 8, 4, 8}; }

void test_a_chunk_goes_out_in_its_lines_times_the_line_clocks() {
    // 8000 px is 10 lines of 820 clocks.
    TEST_ASSERT_EQUAL_UINT32(512500, bounce_budget::chunk_ns(panel(16000000), 8000));
    TEST_ASSERT_EQUAL_UINT32(585714, bounce_budget::chunk_ns(panel(14000000), 8000));
    TEST_ASSERT_EQUAL_UINT32(666666, bounce_budget::chunk_ns(panel(12300000), 8000));
}

void test_the_window_keeps_the_worst_copy_its_margin_and_the_late_ones() {
    bounce_budget::Meter meter(512500);
    meter.copied(400);
    meter.copied(530);  // over the budget: late
    meter.copied(480);
    const bounce_budget::Report r = meter.take();
    TEST_ASSERT_EQUAL_UINT32(3, r.chunks);
    TEST_ASSERT_EQUAL_UINT32(530, r.worst_us);
    TEST_ASSERT_EQUAL_INT32(-18, r.margin_us);  // 512.5 - 530 = -17.5, rounded toward the bad side
    TEST_ASSERT_EQUAL_UINT32(1, r.late);
}

void test_a_window_with_room_has_a_positive_margin_and_take_starts_over() {
    bounce_budget::Meter meter(666666);
    meter.copied(500);
    TEST_ASSERT_EQUAL_INT32(166, meter.take().margin_us);
    const bounce_budget::Report empty = meter.take();
    TEST_ASSERT_EQUAL_UINT32(0, empty.chunks);
    TEST_ASSERT_EQUAL_UINT32(0, empty.late);
}

// The glass deadline (#663): the DMA starts reading the refilled buffer one chunk after the fill starts and reaches
// its end a chunk later, so a front-to-back copy leaves no stale pixel unless it runs past two chunks.
void test_a_copy_past_two_chunks_is_past_the_glass_deadline() {
    bounce_budget::Meter meter(666666);
    meter.copied(667);   // late, but the DMA never overtakes it
    meter.copied(1333);  // just inside two chunks
    meter.copied(1334);  // past them
    const bounce_budget::Report r = meter.take();
    TEST_ASSERT_EQUAL_UINT32(3, r.late);
    TEST_ASSERT_EQUAL_UINT32(1, r.past_glass);
    TEST_ASSERT_EQUAL_UINT32(0, meter.take().past_glass);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_chunk_goes_out_in_its_lines_times_the_line_clocks);
    RUN_TEST(test_the_window_keeps_the_worst_copy_its_margin_and_the_late_ones);
    RUN_TEST(test_a_copy_past_two_chunks_is_past_the_glass_deadline);
    RUN_TEST(test_a_window_with_room_has_a_positive_margin_and_take_starts_over);
    return UNITY_END();
}
