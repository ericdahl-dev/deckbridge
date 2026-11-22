// The panel's fonts (#621: Geist, converted with ASCII, Latin-1 Supplement, Latin Extended-A and "…") draw those
// characters; anything else would draw as an empty box, so text is fitted to them first and the rest is "?".
#include <unity.h>

#include <string>

#include "font_fallback.h"

void setUp() {}
void tearDown() {}

static std::string fitted(const char* text) {
    char out[64];
    font_fallback::fit(text, out, sizeof out);
    return out;
}

void test_printable_ascii_is_kept() { TEST_ASSERT_EQUAL_STRING("Night Drive (Extended) #2", fitted("Night Drive (Extended) #2").c_str()); }

void test_latin_1_and_extended_a_letters_are_kept() {
    TEST_ASSERT_EQUAL_STRING("Caf\xC3\xA9 \xC3\x85ngstr\xC3\xB6m", fitted("Caf\xC3\xA9 \xC3\x85ngstr\xC3\xB6m").c_str());
    TEST_ASSERT_EQUAL_STRING("\xC5\x81\xC3\xB3\x64\xC5\xBA", fitted("\xC5\x81\xC3\xB3\x64\xC5\xBA").c_str());  // Łódź
    TEST_ASSERT_EQUAL_STRING("\xC2\xA0\xC5\xBF", fitted("\xC2\xA0\xC5\xBF").c_str());  // U+00A0 and U+017F, the ends
}

void test_the_ellipsis_is_kept() { TEST_ASSERT_EQUAL_STRING("Joining Wi-Fi\xE2\x80\xA6", fitted("Joining Wi-Fi\xE2\x80\xA6").c_str()); }

void test_anything_else_is_a_question_mark_one_per_character() {
    // 日, 🎵, Ā's neighbor past Extended-A (U+0180), a C1 control (U+0085)
    TEST_ASSERT_EQUAL_STRING("? ? ? ?", fitted("\xE6\x97\xA5 \xF0\x9F\x8E\xB5 \xC6\x80 \xC2\x85").c_str());
}

void test_the_output_is_cut_to_its_room_between_characters() {
    char out[5];
    font_fallback::fit("abcdef", out, sizeof out);
    TEST_ASSERT_EQUAL_STRING("abcd", out);
    font_fallback::fit("abc\xC3\xA9", out, sizeof out);  // é doesn't fit whole: left out
    TEST_ASSERT_EQUAL_STRING("abc", out);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_printable_ascii_is_kept);
    RUN_TEST(test_latin_1_and_extended_a_letters_are_kept);
    RUN_TEST(test_the_ellipsis_is_kept);
    RUN_TEST(test_anything_else_is_a_question_mark_one_per_character);
    RUN_TEST(test_the_output_is_cut_to_its_room_between_characters);
    return UNITY_END();
}
