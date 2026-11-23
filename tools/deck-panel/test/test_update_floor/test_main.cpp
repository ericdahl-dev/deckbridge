// The panel's floor (#690): the lowest version it takes over Wi-Fi, kept in NVS and only ever raised, once a new image
// has confirmed itself.
#include <unity.h>

#include <string>

#include "update_floor.h"

using update_floor::raised;

namespace {

void test_a_higher_pending_floor_is_kept() {
    TEST_ASSERT_EQUAL_STRING("1.4.0", raised("1.2.0", "1.4.0").c_str());
    TEST_ASSERT_EQUAL_STRING("1.10.0", raised("1.9.3", "1.10.0").c_str());  // number by number, not as text
}

void test_a_lower_pending_floor_never_lowers_it() {
    TEST_ASSERT_EQUAL_STRING("1.4.0", raised("1.4.0", "1.2.0").c_str());
    TEST_ASSERT_EQUAL_STRING("1.10.0", raised("1.10.0", "1.9.9").c_str());
}

void test_no_floor_yet_takes_the_pending_one() { TEST_ASSERT_EQUAL_STRING("1.1.0", raised("", "1.1.0").c_str()); }

void test_no_pending_floor_keeps_the_floor() { TEST_ASSERT_EQUAL_STRING("1.4.0", raised("1.4.0", "").c_str()); }

// A floor that isn't a version counts every version as below it, so keeping one would refuse every update for good.
void test_a_pending_floor_that_is_not_a_version_is_never_kept() {
    TEST_ASSERT_EQUAL_STRING("", raised("", "1.x").c_str());
    TEST_ASSERT_EQUAL_STRING("1.4.0", raised("1.4.0", "9.9.9 ").c_str());
    TEST_ASSERT_EQUAL_STRING("1.4.0", raised("1.4.0", "v2").c_str());
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_higher_pending_floor_is_kept);
    RUN_TEST(test_a_lower_pending_floor_never_lowers_it);
    RUN_TEST(test_no_floor_yet_takes_the_pending_one);
    RUN_TEST(test_no_pending_floor_keeps_the_floor);
    RUN_TEST(test_a_pending_floor_that_is_not_a_version_is_never_kept);
    return UNITY_END();
}
