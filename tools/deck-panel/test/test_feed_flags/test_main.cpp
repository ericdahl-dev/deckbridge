// The feed path's shipped defaults (#713, owner's call from the A/B runs A-F on PR #713): no receive task, the loop
// reads the socket; the task, its wait and its stamps stay behind build flags for a heavier feed.
#include <unity.h>

#include "feed_flags.h"

void setUp() {}
void tearDown() {}

void test_the_shipped_build_has_no_receive_task() { TEST_ASSERT_EQUAL_INT(0, FEED_RX_TASK); }

void test_the_task_only_flags_keep_their_defaults() {
    TEST_ASSERT_EQUAL_INT(0, FEED_STAMP_AT_READ);
    TEST_ASSERT_EQUAL_INT(5, FEED_RX_WAIT_MS);
    TEST_ASSERT_EQUAL_INT(0, FEED_RX_DELAY_TICKS);
}

// The boot line names the feed flags only when a build is off these defaults, so a run's log says which build it was.
void test_the_shipped_build_is_on_the_defaults() { TEST_ASSERT_EQUAL_INT(0, FEED_FLAGS_OFF_DEFAULT); }

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_shipped_build_has_no_receive_task);
    RUN_TEST(test_the_task_only_flags_keep_their_defaults);
    RUN_TEST(test_the_shipped_build_is_on_the_defaults);
    return UNITY_END();
}
