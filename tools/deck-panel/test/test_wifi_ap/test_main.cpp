// The panel's setup network (#622): a name to find it by, and a fresh password shown on its screen each time.
#include <unity.h>

#include <cstring>
#include <string>

#include "wifi_ap.h"

void setUp() {}
void tearDown() {}

void test_the_name_ends_in_the_macs_last_two_bytes() {
    const uint8_t mac[6] = {0x24, 0x6F, 0x28, 0x9A, 0x1a, 0x2B};
    char name[20];
    wifi_setup::network_name(mac, name, sizeof name);
    TEST_ASSERT_EQUAL_STRING("DeckPanel-1A2B", name);
}

void test_the_password_is_10_characters_with_no_look_alikes() {
    uint32_t n = 0;
    char password[11];
    // Every value a random source can give, in turn, so every letter it maps to shows up.
    for (int round = 0; round < 200; ++round) {
        wifi_setup::setup_password([&] { return n++ * 2654435761u; }, password, sizeof password);
        TEST_ASSERT_EQUAL(10, std::strlen(password));
        for (const char* p = password; *p; ++p) {
            TEST_ASSERT_TRUE_MESSAGE(std::strchr("0O1lIo", *p) == nullptr, password);
            TEST_ASSERT_TRUE((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '2' && *p <= '9'));
        }
    }
}

void test_the_same_random_values_give_the_same_password() {
    char a[11], b[11];
    uint32_t x = 7, y = 7;
    wifi_setup::setup_password([&] { return x += 12345; }, a, sizeof a);
    wifi_setup::setup_password([&] { return y += 12345; }, b, sizeof b);
    TEST_ASSERT_EQUAL_STRING(a, b);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_name_ends_in_the_macs_last_two_bytes);
    RUN_TEST(test_the_password_is_10_characters_with_no_look_alikes);
    RUN_TEST(test_the_same_random_values_give_the_same_password);
    return UNITY_END();
}
