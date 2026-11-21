// When a new image confirms itself or rolls back (#690): on what recovery needs, never on the display feed.
#include <unity.h>

#include "update_boot.h"

using update_boot::Decision;
using update_boot::State;

namespace {

int decided(State s) { return static_cast<int>(update_boot::decide(s)); }

State trial_with_wifi() {
    State s;
    s.trial = true;
    s.saved_wifi = true;
    return s;
}

void test_an_image_that_is_not_a_trial_does_nothing() {
    State s;
    s.wifi_joined = s.update_listening = true;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::nothing), decided(s));
}

void test_a_trial_with_wifi_joined_and_the_update_server_listening_confirms() {
    State s = trial_with_wifi();
    s.wifi_joined = s.update_listening = true;
    s.since_boot_ms = 9000;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::confirm), decided(s));
}

void test_a_trial_waits_while_either_is_missing_inside_the_trial_time() {
    State joined = trial_with_wifi();
    joined.wifi_joined = true;
    joined.since_boot_ms = update_boot::kTrialMs - 1;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::wait), decided(joined));
    State listening = trial_with_wifi();
    listening.update_listening = true;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::wait), decided(listening));
}

void test_a_trial_that_has_not_brought_recovery_up_in_time_rolls_back() {
    State s = trial_with_wifi();
    s.wifi_joined = true;  // joined, but no update server: a bad release couldn't be replaced
    s.since_boot_ms = update_boot::kTrialMs;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::roll_back), decided(s));
}

// A panel with no saved Wi-Fi runs its setup network (#622): it confirms when that is up and the update server
// listens on it, since the app can reach the panel there. Joining a network isn't asked of it.
void test_a_trial_in_setup_mode_confirms_on_its_setup_network_and_the_update_server() {
    State s;
    s.trial = true;
    s.setup_network_up = s.update_listening = true;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::confirm), decided(s));
    State down;
    down.trial = true;
    down.update_listening = true;
    down.since_boot_ms = update_boot::kTrialMs;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::roll_back), decided(down));
}

void test_a_panel_with_saved_wifi_does_not_confirm_on_a_setup_network_alone() {
    State s = trial_with_wifi();
    s.setup_network_up = s.update_listening = true;
    TEST_ASSERT_EQUAL(static_cast<int>(Decision::wait), decided(s));
}

}  // namespace

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_an_image_that_is_not_a_trial_does_nothing);
    RUN_TEST(test_a_trial_with_wifi_joined_and_the_update_server_listening_confirms);
    RUN_TEST(test_a_trial_waits_while_either_is_missing_inside_the_trial_time);
    RUN_TEST(test_a_trial_that_has_not_brought_recovery_up_in_time_rolls_back);
    RUN_TEST(test_a_trial_in_setup_mode_confirms_on_its_setup_network_and_the_update_server);
    RUN_TEST(test_a_panel_with_saved_wifi_does_not_confirm_on_a_setup_network_alone);
    return UNITY_END();
}
