// The one frame clock (#663): the panel's latch drives read, render, refresh, then the chores.
#include <unity.h>

#include <algorithm>
#include <string>
#include <vector>

#include "frame_clock.h"

void setUp() {}
void tearDown() {}

namespace {

// A test board: latches at given times, a clock that each step advances, and a log of what ran.
struct FakeBoard : frame_clock::Board {
    std::vector<std::string> log;
    uint32_t latch_count = 0;
    uint32_t latch_us = 0;
    uint32_t skip_next = 0;  // latches the next refresh runs past
    bool stalled = false;    // the panel gives no latch: wait times out

    bool wait_latch(uint32_t& count, uint32_t& us) override {
        log.push_back("wait");
        if (stalled) {
            us = latch_us + 50000;  // the time the wait gave up
            return false;
        }
        latch_count += 1 + skip_next;
        latch_us += 33400 * (1 + skip_next);
        skip_next = 0;
        count = latch_count;
        us = latch_us;
        return true;
    }
    void read_feed() override { log.push_back("read"); }
    void render() override { log.push_back("render"); }
    void refresh() override { log.push_back("refresh"); }
    uint32_t chores_until_us = 0;
    void chores(uint32_t until_us) override {
        log.push_back("chores");
        chores_until_us = until_us;
    }
};

}  // namespace

void test_a_frame_waits_for_the_latch_then_reads_renders_refreshes_and_does_the_chores() {
    FakeBoard board;
    frame_clock::Clock clock(33400, 3000);
    clock.step(board);
    const std::vector<std::string> want = {"wait", "read", "render", "refresh", "chores"};
    TEST_ASSERT_EQUAL(want.size(), board.log.size());
    for (size_t i = 0; i < want.size(); ++i) TEST_ASSERT_EQUAL_STRING(want[i].c_str(), board.log[i].c_str());
}

void test_the_chores_must_end_a_guard_before_the_next_latch() {
    FakeBoard board;
    frame_clock::Clock clock(33400, 3000);  // the scan's period, and the room kept for the next frame's start
    clock.step(board);                      // woken by the latch at 33400
    TEST_ASSERT_EQUAL_UINT32(63800, board.chores_until_us);  // 33400 + 33400 - 3000
}

void test_a_draw_that_runs_past_the_next_latch_is_late_and_the_next_frame_takes_the_newest_latch() {
    FakeBoard board;
    frame_clock::Clock clock(33400, 3000);
    clock.step(board);   // latch 1
    board.skip_next = 1;
    clock.step(board);   // latch 2, its draw runs past latch 3
    clock.step(board);   // so the board's next latch is 4: no backlog of missed frames to run
    const frame_clock::Report r = clock.take();
    TEST_ASSERT_EQUAL_UINT32(3, r.frames);
    TEST_ASSERT_EQUAL_UINT32(1, r.late);
    TEST_ASSERT_EQUAL_UINT32(1, r.missed);
    TEST_ASSERT_EQUAL_UINT32(4, board.latch_count);
    TEST_ASSERT_EQUAL(3, std::count(board.log.begin(), board.log.end(), std::string("wait")));  // not four
    TEST_ASSERT_EQUAL_UINT32(0, clock.take().frames);
}

void test_with_no_latch_nothing_is_drawn_but_the_chores_still_run() {
    FakeBoard board;
    board.stalled = true;  // e.g. the panel stopped: Wi-Fi and touch must stay alive
    frame_clock::Clock clock(33400, 3000);
    clock.step(board);
    const std::vector<std::string> want = {"wait", "chores"};
    TEST_ASSERT_EQUAL(want.size(), board.log.size());
    for (size_t i = 0; i < want.size(); ++i) TEST_ASSERT_EQUAL_STRING(want[i].c_str(), board.log[i].c_str());
    TEST_ASSERT_EQUAL_UINT32(50000 + 33400 - 3000, board.chores_until_us);
    const frame_clock::Report r = clock.take();
    TEST_ASSERT_EQUAL_UINT32(0, r.frames);
    TEST_ASSERT_EQUAL_UINT32(1, r.no_latch);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_frame_waits_for_the_latch_then_reads_renders_refreshes_and_does_the_chores);
    RUN_TEST(test_the_chores_must_end_a_guard_before_the_next_latch);
    RUN_TEST(test_a_draw_that_runs_past_the_next_latch_is_late_and_the_next_frame_takes_the_newest_latch);
    RUN_TEST(test_with_no_latch_nothing_is_drawn_but_the_chores_still_run);
    return UNITY_END();
}
