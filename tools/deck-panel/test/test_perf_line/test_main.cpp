// The perf build's serial line (#635), once every 5 s: numbers to read next to the owner's eyes.
#include <unity.h>

#include <string>

#include "perf_line.h"

void setUp() {}
void tearDown() {}

static perf_line::Window window() {
    perf_line::Window w;
    w.ms = 5000;
    w.frames = 150;           // in this window: 30 a second
    w.frame_us = 3300000;     // 22 ms each, the swap wait included
    w.frame_max_us = 31500;
    w.vsyncs = 195;
    w.swaps = 150;
    w.swap_timeouts = 0;
    w.swap_wait_us = 2700000;  // 18 ms a frame
    w.draw_bitmap_us = 3000;   // 0.02 ms a frame
    w.datagrams = 900;
    w.too_big = 1;
    w.internal_free = 123456;
    w.scan.lag_min_us = 20000;
    w.scan.lag_max_us = 20800;
    w.scan.vsync_min_us = 25625;
    w.scan.vsync_max_us = 30000;
    w.scan.resyncs = 1;
    w.copy_budget_us = 666;
    w.copy.chunks = 7200;
    w.copy.worst_us = 540;
    w.copy.margin_us = 126;
    w.copy.late = 0;
    w.clock.frames = 150;
    w.clock.late = 2;
    w.clock.missed = 3;
    w.clock.no_latch = 1;
    return w;
}

void test_the_line_has_every_number_in_one_fixed_order() {
    TEST_ASSERT_EQUAL_STRING(
        "perf: 30.0 frames/s, frame avg 22.0 ms max 31.5 ms (swap wait 18.0), draw_bitmap 0.02 ms/frame, "
        "39.0 vsyncs/s, 0 swap timeouts, scan lag 20.0-20.8 ms, vsync 25.6-30.0 ms, 1 resyncs, "
        "copy worst 540 of 666 us (margin 126) 0 late, 0 past the glass deadline, feed 900 datagrams 1 too big, "
        "no feed frames, clock 150 frames 2 late 3 missed 1 no latch, internal free 123456",
        perf_line::format(window()).c_str());
}

void test_a_window_with_no_frames_says_so_without_dividing_by_zero() {
    perf_line::Window w = window();
    w.frames = 0;
    w.frame_us = 0;
    w.frame_max_us = 0;
    w.swaps = 0;
    w.swap_wait_us = 0;
    w.draw_bitmap_us = 0;
    TEST_ASSERT_EQUAL_STRING(
        "perf: no frames (nothing changed), 39.0 vsyncs/s, 0 swap timeouts, scan lag 20.0-20.8 ms, "
        "vsync 25.6-30.0 ms, 1 resyncs, copy worst 540 of 666 us (margin 126) 0 late, 0 past the glass deadline, "
        "feed 900 datagrams 1 too big, "
        "no feed frames, clock 150 frames 2 late 3 missed 1 no latch, internal free 123456",
        perf_line::format(w).c_str());
}

// The frames are counted in the same window as everything else on the line, so a busy screen never reads as still.
void test_frames_per_second_comes_from_this_windows_own_length() {
    perf_line::Window w = window();
    w.ms = 2500;
    w.frames = 75;
    w.frame_us = 75 * 22000;
    w.vsyncs = 98;
    const std::string line = perf_line::format(w);
    TEST_ASSERT_TRUE(line.rfind("perf: 30.0 frames/s, frame avg 22.0 ms", 0) == 0);
    TEST_ASSERT_TRUE(line.find("39.2 vsyncs/s") != std::string::npos);
}

// An underrun reads as a negative margin and late chunks; a build that can't time the copy says so.
void test_the_copy_numbers_show_an_underrun_and_their_absence() {
    perf_line::Window w = window();
    w.copy_budget_us = 512;
    w.copy.worst_us = 530;
    w.copy.margin_us = -18;
    w.copy.late = 41;
    TEST_ASSERT_TRUE(perf_line::format(w).find("copy worst 530 of 512 us (margin -18) 41 late") != std::string::npos);
    w.copy = {};
    TEST_ASSERT_TRUE(perf_line::format(w).find("copy not timed") != std::string::npos);
}

// The frame ledger's report (#662): arrival-to-glass lag, typical and worst, and the frames that missed a vsync.
void test_the_feed_lag_and_skipped_frames_follow_the_feed_counts() {
    perf_line::Window w = window();
    w.ledger.frames = 150;
    w.ledger.lag_typical_us = 21340;
    w.ledger.lag_worst_us = 48020;
    w.ledger.skipped = 2;
    TEST_ASSERT_TRUE(perf_line::format(w).find("1 too big, lag 21.3 worst 48.0 ms, 2 of 150 frames skipped,") !=
                     std::string::npos);
}

// No feed data reached the glass: "nothing changed", told apart from a lag of 0.
void test_a_window_with_no_feed_frames_says_so() {
    perf_line::Window w = window();
    w.ledger = {};
    TEST_ASSERT_TRUE(perf_line::format(w).find("1 too big, no feed frames,") != std::string::npos);
}

// The frame clock's report (#663): frames run on a latch, those whose draw ran past the next one, the latches that
// went by with no frame, and the waits no latch ended (a stopped panel).
void test_the_frame_clock_counts_follow_the_feed_lag() {
    perf_line::Window w = window();
    w.ledger.frames = 150;
    w.ledger.lag_typical_us = 21340;
    w.ledger.lag_worst_us = 48020;
    w.ledger.skipped = 2;
    w.clock = {};
    w.clock.frames = 149;
    w.clock.late = 4;
    w.clock.missed = 5;
    TEST_ASSERT_TRUE(perf_line::format(w).find("2 of 150 frames skipped, clock 149 frames 4 late 5 missed 0 no latch, "
                                               "internal free") != std::string::npos);
}

// Where the late copies fell (#663): during the loop's LVGL refresh, and within 3 ms after a latch (the frame turn,
// where the driver refills both bounce buffers at the vsync). Overlapping counts, not a split. Only when some are late.
void test_late_copies_say_how_many_fell_in_a_refresh_and_at_the_frame_turn() {
    perf_line::Window w = window();
    w.copy.late = 41;
    w.copy_late_drawing = 30;
    w.copy_late_turn = 12;
    TEST_ASSERT_TRUE(perf_line::format(w).find("(margin 126) 41 late (30 drawing, 12 at the turn), "
                                               "0 past the glass deadline, feed") != std::string::npos);
    w.copy.late = 0;
    w.copy_late_drawing = 0;
    w.copy_late_turn = 0;
    TEST_ASSERT_TRUE(perf_line::format(w).find("(margin 126) 0 late, 0 past the glass deadline, feed") !=
                     std::string::npos);
}

// Where in the frame the bounce copies ran, and in which loop step (#663): every copy counted, and the late ones, so a
// bucket's late count reads against how many copies it had. The eighths start at the latch.
void test_a_copy_falls_in_the_eighth_of_the_scan_out_since_the_latch() {
    TEST_ASSERT_EQUAL_INT(0, perf_line::phase(0, 33400));
    TEST_ASSERT_EQUAL_INT(0, perf_line::phase(4174, 33400));  // 33400 / 8 = 4175
    TEST_ASSERT_EQUAL_INT(1, perf_line::phase(4175, 33400));
    TEST_ASSERT_EQUAL_INT(7, perf_line::phase(33399, 33400));
    TEST_ASSERT_EQUAL_INT(7, perf_line::phase(90000, 33400));  // a latch missed: the last eighth, not past the array
}

void test_the_copy_line_has_late_and_all_copies_by_eighth_and_by_loop_step() {
    perf_line::CopySpread c;
    for (int i = 0; i < perf_line::kPhases; ++i) c.copies_by_phase[i] = 300 + i;
    c.late_by_phase[3] = 2;
    c.copies_by_mark[static_cast<int>(perf_line::Mark::wait)] = 6000;
    c.late_by_mark[static_cast<int>(perf_line::Mark::wait)] = 1;
    c.copies_by_mark[static_cast<int>(perf_line::Mark::refresh)] = 900;
    c.late_by_mark[static_cast<int>(perf_line::Mark::perf)] = 1;
    c.copies_by_mark[static_cast<int>(perf_line::Mark::perf)] = 40;
    TEST_ASSERT_EQUAL_STRING(
        "perf copy: late/copies by eighth after the latch 0/300 0/301 0/302 2/303 0/304 0/305 0/306 0/307; "
        "by loop step wait 1/6000 read 0/0 render 0/0 refresh 0/900 wifi 0/0 udp 0/0 touch 0/0 lvgl 0/0 perf 1/40 "
        "other 0/0; outside an interrupt 0/0; while serial drains 0/0; no late copies",
        perf_line::format_copy(c).c_str());
}

// A 16000-byte copy out of PSRAM that isn't the panel interrupt's is someone else's: counted apart, so the meter's
// own filter can be checked on the panel.
void test_the_copy_line_counts_copies_outside_an_interrupt_apart() {
    perf_line::CopySpread c;
    c.outside_isr = 12;
    c.late_outside_isr = 3;
    TEST_ASSERT_TRUE(perf_line::format_copy(c).find("other 0/0; outside an interrupt 3/12") != std::string::npos);
}

// Each late copy, a few per window (#663): when it started after the latch, how long it took and the loop's step, so
// the phase is read to the microsecond, not to an eighth.
void test_the_copy_line_lists_the_late_copies_it_kept() {
    perf_line::CopySpread c;
    c.kept = 2;
    c.lates[0] = {3120, 702, static_cast<uint8_t>(perf_line::Mark::read)};
    c.lates[1] = {15004, 851, static_cast<uint8_t>(perf_line::Mark::wait)};
    const std::string line = perf_line::format_copy(c);
    TEST_ASSERT_TRUE(line.find("outside an interrupt 0/0; while serial drains 0/0; late at +3120 702 us read, "
                               "+15004 851 us wait") != std::string::npos);
    perf_line::CopySpread none;
    TEST_ASSERT_TRUE(perf_line::format_copy(none).find("outside an interrupt 0/0; while serial drains 0/0; "
                                                       "no late copies") != std::string::npos);
}

// Copies while the UART still drains the last print (#663): the loop's step has moved on by then, so they're counted
// apart, beside the steps, not instead of them.
void test_the_copy_line_counts_copies_while_serial_drains() {
    perf_line::CopySpread c;
    c.while_printing = 1100;
    c.late_while_printing = 4;
    TEST_ASSERT_TRUE(perf_line::format_copy(c).find("outside an interrupt 0/0; while serial drains 4/1100;") !=
                     std::string::npos);
}

// The glass deadline (#663): copies the DMA could overtake, apart from the margin's late ones.
void test_the_copy_numbers_say_how_many_were_past_the_glass_deadline() {
    perf_line::Window w = window();
    w.copy.late = 3;
    w.copy.past_glass = 1;
    TEST_ASSERT_TRUE(perf_line::format(w).find("3 late (0 drawing, 0 at the turn), 1 past the glass deadline, feed") !=
                     std::string::npos);
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_the_line_has_every_number_in_one_fixed_order);
    RUN_TEST(test_a_window_with_no_frames_says_so_without_dividing_by_zero);
    RUN_TEST(test_frames_per_second_comes_from_this_windows_own_length);
    RUN_TEST(test_the_copy_numbers_show_an_underrun_and_their_absence);
    RUN_TEST(test_the_feed_lag_and_skipped_frames_follow_the_feed_counts);
    RUN_TEST(test_a_window_with_no_feed_frames_says_so);
    RUN_TEST(test_the_frame_clock_counts_follow_the_feed_lag);
    RUN_TEST(test_late_copies_say_how_many_fell_in_a_refresh_and_at_the_frame_turn);
    RUN_TEST(test_the_copy_numbers_say_how_many_were_past_the_glass_deadline);
    RUN_TEST(test_a_copy_falls_in_the_eighth_of_the_scan_out_since_the_latch);
    RUN_TEST(test_the_copy_line_has_late_and_all_copies_by_eighth_and_by_loop_step);
    RUN_TEST(test_the_copy_line_counts_copies_outside_an_interrupt_apart);
    RUN_TEST(test_the_copy_line_lists_the_late_copies_it_kept);
    RUN_TEST(test_the_copy_line_counts_copies_while_serial_drains);
    return UNITY_END();
}
