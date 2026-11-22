// The setup page (#622): the networks the panel can see, and the form the phone posts back.
#include <unity.h>

#include <string>

#include "wifi_page.h"

void setUp() {}
void tearDown() {}

static bool has(const std::string& page, const char* text) { return page.find(text) != std::string::npos; }

void test_networks_are_listed_once_strongest_first_hidden_ones_left_out() {
    const wifi_setup::Seen seen[] = {{"Weak", -80}, {"Home", -70}, {"", -30}, {"Home", -40}, {"Strong", -35}};
    const std::string page = wifi_setup::setup_page(seen, 5, "", "DeckPanel-1A2B");
    const size_t strong = page.find("value=\"Strong\""), home = page.find("value=\"Home\""),
                 weak = page.find("value=\"Weak\"");
    TEST_ASSERT_TRUE(strong != std::string::npos && home != std::string::npos && weak != std::string::npos);
    TEST_ASSERT_TRUE(strong < home && home < weak);
    TEST_ASSERT_TRUE(page.find("value=\"Home\"", home + 1) == std::string::npos);  // once
    TEST_ASSERT_FALSE(has(page, "value=\"\""));
}

void test_a_network_name_is_text_never_markup() {
    const wifi_setup::Seen seen[] = {{"<script>\"a\"&'b'", -50}};
    const std::string page = wifi_setup::setup_page(seen, 1, "", "DeckPanel-1A2B");
    TEST_ASSERT_FALSE(has(page, "<script>"));
    TEST_ASSERT_TRUE(has(page, "&lt;script&gt;&quot;a&quot;&amp;&#39;b&#39;"));
}

void test_the_form_posts_the_three_fields_and_never_refills_the_password() {
    const wifi_setup::Seen seen[] = {{"Home", -50}};
    const std::string page = wifi_setup::setup_page(seen, 1, "A network name is at most 32 bytes", "DeckPanel-1A2B");
    TEST_ASSERT_TRUE(has(page, "<form method=\"post\" action=\"/save\""));
    TEST_ASSERT_TRUE(has(page, "name=\"ssid\""));
    TEST_ASSERT_TRUE(has(page, "name=\"ssid_other\""));
    TEST_ASSERT_TRUE(has(page, "<input type=\"password\" name=\"password\" autocomplete=\"off\">"));
    TEST_ASSERT_TRUE(has(page, "A network name is at most 32 bytes"));
    TEST_ASSERT_TRUE(has(page, "DeckPanel-1A2B"));
}

void test_no_error_line_without_an_error() {
    const std::string page = wifi_setup::setup_page(nullptr, 0, "", "DeckPanel-1A2B");
    TEST_ASSERT_FALSE(has(page, "class=\"error\""));
}

void test_the_saved_page_names_the_network_and_nothing_else() {
    const std::string page = wifi_setup::saved_page("Caf\xC3\xA9 <5G>");
    TEST_ASSERT_TRUE(has(page, "Caf\xC3\xA9 &lt;5G&gt;"));
    TEST_ASSERT_TRUE(has(page, "restarting"));
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_networks_are_listed_once_strongest_first_hidden_ones_left_out);
    RUN_TEST(test_a_network_name_is_text_never_markup);
    RUN_TEST(test_the_form_posts_the_three_fields_and_never_refills_the_password);
    RUN_TEST(test_no_error_line_without_an_error);
    RUN_TEST(test_the_saved_page_names_the_network_and_nothing_else);
    return UNITY_END();
}
