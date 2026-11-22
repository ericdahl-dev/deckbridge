// Hold-to-reset (#622): a finger held 5 s on the waiting screen (waiting for DeckBridge, or joining Wi-Fi) forgets
// the saved Wi-Fi. Never from the deck view, where a hand on the glass is part of a set.
#include <unity.h>

#include "hold_reset.h"

void setUp() {}
void tearDown() {}

void test_a_5_s_hold_on_the_waiting_screen_fires_once() {
    wifi_setup::HoldReset hold;
    TEST_ASSERT_FALSE(hold.update(true, true, 1000));
    TEST_ASSERT_FALSE(hold.update(true, true, 5999));
    TEST_ASSERT_TRUE(hold.update(true, true, 6000));
    TEST_ASSERT_FALSE(hold.update(true, true, 9000));  // once a hold
    hold.update(false, true, 9100);
    hold.update(true, true, 10000);
    TEST_ASSERT_TRUE(hold.update(true, true, 15000));  // a new hold fires again
}

void test_letting_go_starts_over() {
    wifi_setup::HoldReset hold;
    hold.update(true, true, 0);
    hold.update(false, true, 4000);
    hold.update(true, true, 4100);
    TEST_ASSERT_FALSE(hold.update(true, true, 8000));
    TEST_ASSERT_TRUE(hold.update(true, true, 9100));
}

void test_the_deck_view_never_counts() {
    wifi_setup::HoldReset hold;
    TEST_ASSERT_FALSE(hold.update(true, false, 0));
    TEST_ASSERT_FALSE(hold.update(true, false, 20000));
}

void test_a_press_that_began_on_the_deck_never_counts() {
    // A hand on the glass mid-set, and the feed goes quiet under it: that press never forgets the Wi-Fi.
    wifi_setup::HoldReset hold;
    hold.update(true, false, 0);
    TEST_ASSERT_FALSE(hold.update(true, true, 1000));
    TEST_ASSERT_FALSE(hold.update(true, true, 60000));
    hold.update(false, true, 60100);  // a fresh press on the waiting screen does
    hold.update(true, true, 61000);
    TEST_ASSERT_TRUE(hold.update(true, true, 66000));
}

void test_the_deck_coming_back_mid_hold_cancels_it() {
    wifi_setup::HoldReset hold;
    hold.update(true, true, 0);
    hold.update(true, false, 3000);
    TEST_ASSERT_FALSE(hold.update(true, true, 5000));
    TEST_ASSERT_FALSE(hold.update(true, true, 10000));  // that press touched the deck: it never counts again
}

void test_the_clock_wrapping_is_no_jump() {
    wifi_setup::HoldReset hold;
    hold.update(true, true, 0xFFFFF000u);
    TEST_ASSERT_FALSE(hold.update(true, true, 0x00000100u));  // 4.4 s later
    TEST_ASSERT_TRUE(hold.update(true, true, 0x00000800u));   // 6.1 s later
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_5_s_hold_on_the_waiting_screen_fires_once);
    RUN_TEST(test_letting_go_starts_over);
    RUN_TEST(test_the_deck_view_never_counts);
    RUN_TEST(test_a_press_that_began_on_the_deck_never_counts);
    RUN_TEST(test_the_deck_coming_back_mid_hold_cancels_it);
    RUN_TEST(test_the_clock_wrapping_is_no_jump);
    return UNITY_END();
}
