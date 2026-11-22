// The setup page's form (#622): what the phone posts, checked before anything is saved.
#include <unity.h>

#include <cstring>
#include <string>

#include "wifi_form.h"

void setUp() {}
void tearDown() {}

static wifi_setup::FormResult parse(const char* body) { return wifi_setup::parse_form(body, std::strlen(body)); }

void test_a_chosen_network_and_its_password_are_decoded() {
    const auto r = parse("ssid=Home+Net&password=secret123");
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL_STRING("Home Net", r.credentials.ssid);
    TEST_ASSERT_EQUAL_STRING("secret123", r.credentials.password);
}

void test_percent_escapes_decode_to_their_bytes() {
    const auto r = parse("ssid=Caf%C3%A9&password=p%26ss%3Dword1");
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL_STRING("Caf\xC3\xA9", r.credentials.ssid);
    TEST_ASSERT_EQUAL_STRING("p&ss=word1", r.credentials.password);
}

void test_a_typed_hidden_name_wins_over_the_list() {
    const auto r = parse("ssid=Neighbor&ssid_other=Hidden+One&password=");
    TEST_ASSERT_TRUE(r.ok);
    TEST_ASSERT_EQUAL_STRING("Hidden One", r.credentials.ssid);
}

void test_no_network_is_refused() {
    TEST_ASSERT_FALSE(parse("password=secret123").ok);
    TEST_ASSERT_FALSE(parse("ssid=&ssid_other=&password=secret123").ok);
    TEST_ASSERT_EQUAL_STRING("Choose a network, or type its name", parse("password=x").error);
}

void test_a_name_is_at_most_32_bytes() {
    TEST_ASSERT_TRUE(parse("ssid=12345678901234567890123456789012&password=").ok);
    const auto r = parse("ssid=123456789012345678901234567890123&password=");
    TEST_ASSERT_FALSE(r.ok);
    TEST_ASSERT_EQUAL_STRING("A network name is at most 32 bytes", r.error);
}

void test_a_password_is_empty_8_to_63_characters_or_64_hex_digits() {
    TEST_ASSERT_TRUE(parse("ssid=a&password=").ok);  // an open network
    TEST_ASSERT_TRUE(parse("ssid=a&password=12345678").ok);
    TEST_ASSERT_TRUE(parse("ssid=a&password=123456789012345678901234567890123456789012345678901234567890123").ok);
    TEST_ASSERT_TRUE(parse("ssid=a&password=0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789abcdef").ok);
    const char* why = "A password is 8 to 63 characters, or 64 hex digits; leave it empty for an open network";
    TEST_ASSERT_EQUAL_STRING(why, parse("ssid=a&password=1234567").error);
    TEST_ASSERT_EQUAL_STRING(why, parse("ssid=a&password=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg").error);
}

void test_a_password_takes_printable_ascii_only() {
    const auto r = parse("ssid=a&password=abc%01defgh");
    TEST_ASSERT_FALSE(r.ok);
    TEST_ASSERT_EQUAL_STRING("A password takes plain letters, digits, spaces and symbols", r.error);
}

void test_a_broken_escape_is_refused() {
    const auto r = parse("ssid=a%G1&password=");
    TEST_ASSERT_FALSE(r.ok);
    TEST_ASSERT_EQUAL_STRING("The page sent something garbled; try again", r.error);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_chosen_network_and_its_password_are_decoded);
    RUN_TEST(test_percent_escapes_decode_to_their_bytes);
    RUN_TEST(test_a_typed_hidden_name_wins_over_the_list);
    RUN_TEST(test_no_network_is_refused);
    RUN_TEST(test_a_name_is_at_most_32_bytes);
    RUN_TEST(test_a_password_is_empty_8_to_63_characters_or_64_hex_digits);
    RUN_TEST(test_a_password_takes_printable_ascii_only);
    RUN_TEST(test_a_broken_escape_is_refused);
    return UNITY_END();
}
