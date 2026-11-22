// The feed's lost-datagram count (#750), from DeckBridge's bundle numbers.
#include <unity.h>

#include "feed_seq.h"

void setUp() {}
void tearDown() {}

void test_nothing_seen_is_nothing_lost_and_not_seen() {
    feed_seq::Counter c;
    TEST_ASSERT_FALSE(c.seen());
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
}

void test_in_order_loses_nothing() {
    feed_seq::Counter c;
    for (uint32_t n = 1; n <= 100; ++n) c.saw(n);
    TEST_ASSERT_TRUE(c.seen());
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
}

void test_a_gap_counts_the_missing_numbers() {
    feed_seq::Counter c;
    c.saw(1);
    c.saw(2);
    c.saw(5);   // 3 and 4 never came
    c.saw(6);
    c.saw(10);  // 7, 8, 9
    TEST_ASSERT_EQUAL_UINT32(5, c.lost());
}

// The panel booting, or joining, mid-stream: the first number it sees is where it starts.
void test_the_first_number_seen_is_the_baseline() {
    feed_seq::Counter c;
    c.saw(5000);
    c.saw(5001);
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
}

// The feed reopened or DeckBridge restarted (it counts from 1 again), or a datagram came late or twice: at or below the
// last number is a new baseline, never a loss.
void test_at_or_below_the_last_is_a_restart_not_a_loss() {
    feed_seq::Counter c;
    c.saw(40);
    c.saw(41);
    c.saw(1);
    c.saw(2);
    c.saw(2);
    c.saw(3);
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
    c.saw(5);
    TEST_ASSERT_EQUAL_UINT32(1, c.lost());
}

void test_the_wrap_counts_across_it() {
    feed_seq::Counter c;
    c.saw(0xFFFFFFFEu);
    c.saw(0xFFFFFFFFu);
    c.saw(0);
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
    c.saw(3);  // 1 and 2
    TEST_ASSERT_EQUAL_UINT32(2, c.lost());
    feed_seq::Counter d;
    d.saw(0xFFFFFFFFu);
    d.saw(1);  // 0
    TEST_ASSERT_EQUAL_UINT32(1, d.lost());
}

// A datagram that came a little late (#750's firmware review): 12 before 11 counts 11 lost, then 11 coming takes the
// loss back; 13 is then on time. A repeat changes nothing.
void test_a_late_datagram_is_not_two_losses() {
    feed_seq::Counter c;
    c.saw(10);
    c.saw(12);
    TEST_ASSERT_EQUAL_UINT32(1, c.lost());
    c.saw(11);
    c.saw(13);
    c.saw(13);
    TEST_ASSERT_EQUAL_UINT32(0, c.lost());
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_nothing_seen_is_nothing_lost_and_not_seen);
    RUN_TEST(test_in_order_loses_nothing);
    RUN_TEST(test_a_gap_counts_the_missing_numbers);
    RUN_TEST(test_the_first_number_seen_is_the_baseline);
    RUN_TEST(test_at_or_below_the_last_is_a_restart_not_a_loss);
    RUN_TEST(test_the_wrap_counts_across_it);
    RUN_TEST(test_a_late_datagram_is_not_two_losses);
    return UNITY_END();
}
