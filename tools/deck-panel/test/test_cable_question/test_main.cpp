// The version question over the USB cable (#695, #667): the cable carries the feed's SLIP frames and the updater's
// "version" line on the same bytes. Text outside frames reaches the question; the answer goes back on the cable.
#include <unity.h>

#include <deque>
#include <string>
#include <vector>

#include "cable_question.h"
#include "serial_feed.h"

void setUp() {}
void tearDown() {}

struct FakeCable : serial_feed::Bytes {
    std::deque<uint8_t> waiting;
    void add(const std::string& bytes) { waiting.insert(waiting.end(), bytes.begin(), bytes.end()); }
    size_t read(uint8_t* into, size_t room) override {
        size_t n = 0;
        for (; n < room && !waiting.empty(); ++n) {
            into[n] = waiting.front();
            waiting.pop_front();
        }
        return n;
    }
};

static std::vector<std::string> g_answers;
static void write_answer(const char* line) { g_answers.push_back(line); }

static const build_info::Build kBuild{"1.2.0", "abc1234", true};
static const std::string kEnd = "\xC0";
/// One SLIP frame holding `packet`, which has no END or ESC bytes.
static std::string frame(const std::string& packet) { return kEnd + packet + kEnd; }

/// Reads every whole packet waiting, as the loop's drain does; returns how many.
static int drain(serial_feed::SerialFeed& feed) {
    int packets = 0;
    uint8_t buffer[64];
    while (feed.next_size() > 0) {
        feed.read(buffer, sizeof buffer);
        ++packets;
    }
    return packets;
}

void test_a_version_line_between_two_frames_is_answered_once_and_both_frames_still_come_through() {
    g_answers.clear();
    FakeCable cable;
    cable_question::CableQuestion question(kBuild, write_answer);
    serial_feed::SerialFeed feed(cable, &question);
    cable.add(frame("/a") + "version\n" + frame("/b"));
    TEST_ASSERT_EQUAL(2, drain(feed));
    // Not written during the drain (the frame's gap before the draw): the loop's chores write it (firmware review).
    TEST_ASSERT_EQUAL(0, (int)g_answers.size());
    question.answer();
    question.answer();
    TEST_ASSERT_EQUAL(1, (int)g_answers.size());
    TEST_ASSERT_EQUAL_STRING("deck panel: build abc1234, version 1.2.0", g_answers[0].c_str());
}

void test_the_word_version_inside_a_frame_is_never_answered() {
    g_answers.clear();
    FakeCable cable;
    cable_question::CableQuestion question(kBuild, write_answer);
    serial_feed::SerialFeed feed(cable, &question);
    cable.add(frame("version\n"));
    TEST_ASSERT_EQUAL(1, drain(feed));
    question.answer();
    TEST_ASSERT_EQUAL(0, (int)g_answers.size());
}

// The updater asks "\nversion\n": the leading newline ends whatever was on the line before.
void test_the_updaters_ask_with_a_newline_first_is_answered() {
    g_answers.clear();
    FakeCable cable;
    cable_question::CableQuestion question(kBuild, write_answer);
    serial_feed::SerialFeed feed(cable, &question);
    cable.add("junk\nversion\n");
    drain(feed);
    question.answer();
    TEST_ASSERT_EQUAL(1, (int)g_answers.size());
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_version_line_between_two_frames_is_answered_once_and_both_frames_still_come_through);
    RUN_TEST(test_the_word_version_inside_a_frame_is_never_answered);
    RUN_TEST(test_the_updaters_ask_with_a_newline_first_is_answered);
    return UNITY_END();
}
