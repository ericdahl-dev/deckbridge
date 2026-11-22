// The panel's build, as the updater reads it (#695): the boot line, the answer to a version question, and the
// waiting screen's label. The updater's finder (#685) parses the first two, so their text is fixed here.
#include <unity.h>

#include "build_info.h"

void setUp() {}
void tearDown() {}

using build_info::Build;

static const Build release{"1.2.0", "abc1234", true};
static const Build local{"1.2.0", "abc1234-dirty", false};

void test_the_boot_line_keeps_the_old_start_and_adds_the_version() {
    char line[96];
    build_info::boot_line(release, line, sizeof line);
    TEST_ASSERT_EQUAL_STRING("deck panel: boot, build abc1234, version 1.2.0", line);
}

void test_a_local_build_says_so_after_its_version() {
    char line[96];
    build_info::boot_line(local, line, sizeof line);
    TEST_ASSERT_EQUAL_STRING("deck panel: boot, build abc1234-dirty, version 1.2.0 local", line);
}

void test_the_answer_is_the_boot_line_without_boot() {
    char line[96];
    build_info::answer_line(release, line, sizeof line);
    TEST_ASSERT_EQUAL_STRING("deck panel: build abc1234, version 1.2.0", line);
    build_info::answer_line(local, line, sizeof line);
    TEST_ASSERT_EQUAL_STRING("deck panel: build abc1234-dirty, version 1.2.0 local", line);
}

void test_the_waiting_label_puts_the_sha_beside_the_version() {
    char label[48];
    build_info::label(release, label, sizeof label);
    TEST_ASSERT_EQUAL_STRING("v1.2.0  abc1234", label);
    build_info::label(local, label, sizeof label);
    TEST_ASSERT_EQUAL_STRING("v1.2.0 local  abc1234-dirty", label);
}

// A buffer too small is cut, never overrun, and still ends in a NUL.
void test_a_short_buffer_is_cut() {
    char line[12] = {};
    line[11] = 'x';
    build_info::answer_line(release, line, 11);
    TEST_ASSERT_EQUAL_STRING("deck panel", line);
    TEST_ASSERT_EQUAL('x', line[11]);
}

// The version question over serial (#695): the updater sends a line "version", and the panel answers without a reboot.
static int asked(build_info::Question& q, const char* bytes) {
    int n = 0;
    for (const char* c = bytes; *c; ++c) n += q.feed(*c) ? 1 : 0;
    return n;
}

void test_a_version_line_is_a_question() {
    build_info::Question q;
    TEST_ASSERT_EQUAL(1, asked(q, "version\n"));
}

void test_a_line_ends_at_cr_lf_or_both_and_counts_once() {
    build_info::Question q;
    TEST_ASSERT_EQUAL(3, asked(q, "version\rversion\r\nversion\n"));
}

void test_other_lines_and_a_line_split_across_reads_are_handled() {
    build_info::Question q;
    TEST_ASSERT_EQUAL(0, asked(q, "versions\nVERSION\n version\nhello\n"));
    TEST_ASSERT_EQUAL(0, asked(q, "ver"));
    TEST_ASSERT_EQUAL(1, asked(q, "sion\n"));
}

// A long line of noise (boot garbage at the wrong baud) is dropped whole: its tail isn't read as a question.
void test_an_overlong_line_is_dropped_whole() {
    build_info::Question q;
    char noise[200];
    for (int i = 0; i < 190; ++i) noise[i] = 'x';
    noise[190] = 0;
    TEST_ASSERT_EQUAL(0, asked(q, noise));
    TEST_ASSERT_EQUAL(0, asked(q, "version\n"));
    TEST_ASSERT_EQUAL(1, asked(q, "version\n"));
    TEST_ASSERT_EQUAL(0, asked(q, "xxxxxxxxxxxxxxxxxversion\n"));  // a long line ending in the word
    TEST_ASSERT_EQUAL(1, asked(q, "version\n"));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_the_boot_line_keeps_the_old_start_and_adds_the_version);
    RUN_TEST(test_a_local_build_says_so_after_its_version);
    RUN_TEST(test_the_answer_is_the_boot_line_without_boot);
    RUN_TEST(test_the_waiting_label_puts_the_sha_beside_the_version);
    RUN_TEST(test_a_short_buffer_is_cut);
    RUN_TEST(test_a_version_line_is_a_question);
    RUN_TEST(test_a_line_ends_at_cr_lf_or_both_and_counts_once);
    RUN_TEST(test_other_lines_and_a_line_split_across_reads_are_handled);
    RUN_TEST(test_an_overlong_line_is_dropped_whole);
    return UNITY_END();
}
