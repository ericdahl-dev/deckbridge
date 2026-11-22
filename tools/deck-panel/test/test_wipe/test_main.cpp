// Password copies on the stack (#622): zeroed when they go out of scope, by a write the compiler can't drop.
#include <unity.h>

#include <cstring>

#include "wipe.h"

void setUp() {}
void tearDown() {}

void test_wipe_zeroes_every_byte() {
    char buf[16];
    std::memset(buf, 'x', sizeof buf);
    wifi_setup::wipe(buf, sizeof buf);
    for (char c : buf) TEST_ASSERT_EQUAL(0, c);
}

void test_a_guard_zeroes_its_buffer_when_it_goes_out_of_scope() {
    char buf[8];
    std::memcpy(buf, "secret!", 8);
    {
        wifi_setup::WipeOnExit guard(buf, sizeof buf);
        TEST_ASSERT_EQUAL_STRING("secret!", buf);  // untouched while in scope
    }
    for (char c : buf) TEST_ASSERT_EQUAL(0, c);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_wipe_zeroes_every_byte);
    RUN_TEST(test_a_guard_zeroes_its_buffer_when_it_goes_out_of_scope);
    return UNITY_END();
}
