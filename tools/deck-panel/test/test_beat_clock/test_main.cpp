// The panel's beat clock (#660): the master clock's beat at any time, from the beat edges the feed brings.
#include <unity.h>

#include "beat_clock.h"

void setUp() {}
void tearDown() {}

using deck_core::BeatClock;

void test_no_beat_heard_is_none() {
    BeatClock clock;
    TEST_ASSERT_EQUAL(0, clock.beat_at(0));
    TEST_ASSERT_EQUAL(0, clock.beat_at(10000));
}

// One edge gives no tempo: the beat heard holds until the next.
void test_one_edge_holds_its_beat() {
    BeatClock clock;
    clock.edge(3, 100);
    TEST_ASSERT_EQUAL(3, clock.beat_at(100));
    TEST_ASSERT_EQUAL(3, clock.beat_at(5000));
}

// 0 is DeckBridge's "the clock has been quiet over 2 s": no beat.
void test_beat_0_is_none() {
    BeatClock clock;
    clock.edge(3, 100);
    clock.edge(0, 2200);
    TEST_ASSERT_EQUAL(0, clock.beat_at(2200));
}


// 128 BPM: a beat every 469 ms (468.75). Two edges give the tempo; the next beat shows when it's due, before its
// message, and no further than kPredictBeats past the last edge heard.
void test_the_next_beat_shows_when_due_before_its_message() {
    BeatClock clock;
    clock.edge(1, 1000);
    clock.edge(2, 1469);
    TEST_ASSERT_EQUAL(2, clock.beat_at(1937));
    TEST_ASSERT_EQUAL(3, clock.beat_at(1938));
    TEST_ASSERT_EQUAL(1, BeatClock::kPredictBeats);
    TEST_ASSERT_EQUAL(3, clock.beat_at(2407));  // the beat after is due too, but never two past the last edge
    TEST_ASSERT_EQUAL(3, clock.beat_at(9000));
}

// After 4 comes 1.
void test_after_4_comes_1() {
    BeatClock clock;
    clock.edge(3, 1000);
    clock.edge(4, 1469);
    TEST_ASSERT_EQUAL(1, clock.beat_at(1938));
}

// The keepalive sends the same beat again: no edge, so no tempo from it.
void test_the_same_beat_again_is_no_edge() {
    BeatClock clock;
    clock.edge(1, 1000);
    clock.edge(1, 1200);
    clock.edge(2, 1469);
    TEST_ASSERT_EQUAL(3, clock.beat_at(1938));
}


// The first time `clock` shows `beat` after `from_ms`, scanning each millisecond up to `to_ms`; 0 if it never does.
static uint32_t first_shows(const BeatClock& clock, int beat, uint32_t from_ms, uint32_t to_ms) {
    for (uint32_t t = from_ms; t <= to_ms; ++t)
        if (clock.beat_at(t) == beat) return t;
    return 0;
}

// Arrivals jitter (Wi-Fi, the sender): 128 BPM edges, each up to 10 ms early or late. After 16 of them the next beat
// shows within 4 ms of when it's truly due.
void test_jittered_edges_lock_to_the_true_beat() {
    const int jitter[] = {6, -9, 3, 10, -4, -10, 8, 0, -6, 9, -2, 5, -8, 2, 7, -7};
    BeatClock clock;
    int beat = 1;
    for (int k = 0; k < 16; ++k) {
        const double due = 1000 + k * 468.75;
        clock.edge(beat, static_cast<uint32_t>(due + jitter[k] + 0.5));
        beat = beat % 4 + 1;
    }
    const double next_due = 1000 + 16 * 468.75;  // 8500
    const uint32_t shown = first_shows(clock, beat, 8300, 8700);
    TEST_ASSERT_UINT32_WITHIN(4, static_cast<uint32_t>(next_due), shown);
}

// One message 30 ms late doesn't drag the next beat 30 ms late with it.
void test_one_late_message_barely_moves_the_next_beat() {
    BeatClock clock;
    int beat = 1;
    for (int k = 0; k < 8; ++k) {
        const double due = 1000 + k * 468.75;
        clock.edge(beat, static_cast<uint32_t>(due + 0.5) + (k == 7 ? 30 : 0));
        beat = beat % 4 + 1;
    }
    const uint32_t next_due = 1000 + 8 * 468.75;  // 4750
    TEST_ASSERT_UINT32_WITHIN(10, next_due, first_shows(clock, beat, 4600, 4900));
}


// A quiet feed: the clock holds, never more than kPredictBeats past the last edge.
void test_a_quiet_feed_holds_and_never_runs_on() {
    BeatClock clock;
    clock.edge(1, 1000);
    clock.edge(2, 1469);
    for (uint32_t t = 1469; t < 20000; t += 50) TEST_ASSERT_TRUE(clock.beat_at(t) == 2 || clock.beat_at(t) == 3);
}

// Beats coming back after a gap start the clock over: the gap is no beat length, and the first beat back shows as
// heard, not run on from before the gap.
void test_beats_after_a_gap_start_over() {
    BeatClock clock;
    clock.edge(1, 1000);
    clock.edge(2, 1469);
    clock.edge(3, 6000);  // the next value, but 4.5 s on
    TEST_ASSERT_EQUAL(3, clock.beat_at(6000));
    TEST_ASSERT_EQUAL(3, clock.beat_at(6400));
    TEST_ASSERT_EQUAL(3, clock.beat_at(7000));  // no tempo yet: one edge back
    clock.edge(4, 6469);
    TEST_ASSERT_EQUAL(1, clock.beat_at(6938));
}


// 8 beats in time at 128 BPM from 1000 ms: the last (beat 4) at 4281.
static BeatClock locked(uint32_t lead_ms = 0) {
    BeatClock clock(lead_ms);
    int beat = 1;
    for (int k = 0; k < 8; ++k) {
        clock.edge(beat, static_cast<uint32_t>(1000 + k * 468.75 + 0.5));
        beat = beat % 4 + 1;
    }
    return clock;
}

// A cue jump on the master: a beat out of turn, off the grid. It shows at once, and the tempo holds: the beat after
// it is due one beat length on.
void test_a_beat_out_of_turn_shows_at_once_and_keeps_the_tempo() {
    BeatClock clock = locked();
    clock.edge(3, 4500);  // 2 was next, at 4750
    TEST_ASSERT_EQUAL(3, clock.beat_at(4500));
    TEST_ASSERT_UINT32_WITHIN(3, 4969, first_shows(clock, 4, 4500, 5200));
}

// A loop wrapping on the master: the next beat, but early, far off the grid. The clock moves to it at once, not a
// quarter of the way, and the tempo holds.
void test_a_beat_far_off_the_grid_moves_the_clock_at_once() {
    BeatClock clock = locked();
    clock.edge(1, 4600);  // due at 4750
    TEST_ASSERT_EQUAL(1, clock.beat_at(4600));
    TEST_ASSERT_UINT32_WITHIN(3, 5069, first_shows(clock, 2, 4600, 5400));
}


// With the master clock's BPM (the feed's clockBpm, #674), one edge is enough: the next is due a beat length on.
void test_with_the_clock_bpm_one_edge_gives_the_next_beat() {
    BeatClock clock;
    clock.set_tempo(128);
    clock.edge(1, 1000);
    TEST_ASSERT_EQUAL(1, clock.beat_at(1468));
    TEST_ASSERT_EQUAL(2, clock.beat_at(1469));
}

// The BPM gives the beat length; jittered edges move only the beat's place, never its length.
void test_with_the_clock_bpm_jitter_never_changes_the_beat_length() {
    BeatClock clock;
    clock.set_tempo(128);
    const int jitter[] = {0, 9, 9, 9, 9, 9, 9, 9};  // late every time but the first
    int beat = 1;
    for (int k = 0; k < 8; ++k) {
        clock.edge(beat, static_cast<uint32_t>(1000 + k * 468.75 + jitter[k] + 0.5));
        beat = beat % 4 + 1;
    }
    // The last edge sits about 9 ms late (the lock follows a steady lateness), and the next is one 468.75 ms on.
    const uint32_t shown = first_shows(clock, beat, 4400, 5000);
    TEST_ASSERT_UINT32_WITHIN(4, 4759, shown);
}

// A tempo change on the master applies at once: the next beat is due at the new length.
void test_a_clock_bpm_change_applies_at_once() {
    BeatClock clock = locked();  // 128 BPM from the edges; the last, beat 4, at 4281
    clock.set_tempo(120);        // 500 ms
    TEST_ASSERT_UINT32_WITHIN(2, 4781, first_shows(clock, 1, 4281, 5000));
}

// 0 is "no master BPM" (an older DeckBridge, or a quiet clock): the edges give the beat length again.
void test_clock_bpm_0_leaves_the_beat_length_to_the_edges() {
    BeatClock clock;
    clock.set_tempo(0);
    clock.edge(1, 1000);
    TEST_ASSERT_EQUAL(1, clock.beat_at(1600));  // one edge, no length
    clock.edge(2, 1469);
    TEST_ASSERT_EQUAL(3, clock.beat_at(1938));
}


// DeckBridge sends the first clockBpm in the bundle with the first beat, just after it: it times that beat too.
void test_the_clock_bpm_just_after_the_first_edge_times_it() {
    BeatClock clock;
    clock.edge(1, 1000);
    clock.set_tempo(128);
    TEST_ASSERT_EQUAL(2, clock.beat_at(1469));
}

// Stopped, a BPM (a tempo change on the stopped master) doesn't start the clock again: only beats do.
void test_a_clock_bpm_after_a_stop_doesnt_restart_it() {
    BeatClock clock = locked();
    clock.stop();
    clock.set_tempo(120);
    TEST_ASSERT_EQUAL(4, clock.beat_at(6000));
}

// #718: a box lights `lead` ms before its beat is due, so it lands with the LC6000 instead of the path's delay behind.
void test_a_lead_lights_the_next_beat_that_much_early() {
    BeatClock clock(50);
    clock.edge(1, 1000);
    clock.edge(2, 1469);
    TEST_ASSERT_EQUAL(2, clock.beat_at(1887));
    TEST_ASSERT_EQUAL(3, clock.beat_at(1888));  // due at 1938, less 50
}

// #718: the lead is longer than the time since an edge just heard; that beat still shows, from its message until the
// lead brings the next, and the next holds through its own message: no box skipped or lit twice.
void test_a_lead_longer_than_the_time_since_the_edge_shows_that_edge() {
    BeatClock clock(50);
    clock.edge(1, 1000);
    clock.edge(2, 1469);
    for (uint32_t t = 1469; t < 1888; ++t) TEST_ASSERT_EQUAL(2, clock.beat_at(t));
    for (uint32_t t = 1888; t < 1938; ++t) TEST_ASSERT_EQUAL(3, clock.beat_at(t));
    clock.edge(3, 1938);
    for (uint32_t t = 1938; t < 2356; ++t) TEST_ASSERT_EQUAL(3, clock.beat_at(t));
    TEST_ASSERT_EQUAL(4, clock.beat_at(2357));
}

// #718: the lead is time, not part of a beat: after a tempo change the next box lights the same 50 ms early.
void test_a_lead_holds_through_a_tempo_change() {
    BeatClock clock = locked(50);  // 128 BPM; the last edge, beat 4, at 4281
    clock.set_tempo(140);          // 428.6 ms: due at 4709.6, lit at 4659.6
    TEST_ASSERT_UINT32_WITHIN(2, 4660, first_shows(clock, 1, 4281, 5000));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_no_beat_heard_is_none);
    RUN_TEST(test_one_edge_holds_its_beat);
    RUN_TEST(test_beat_0_is_none);
    RUN_TEST(test_the_next_beat_shows_when_due_before_its_message);
    RUN_TEST(test_after_4_comes_1);
    RUN_TEST(test_the_same_beat_again_is_no_edge);
    RUN_TEST(test_jittered_edges_lock_to_the_true_beat);
    RUN_TEST(test_one_late_message_barely_moves_the_next_beat);
    RUN_TEST(test_a_quiet_feed_holds_and_never_runs_on);
    RUN_TEST(test_beats_after_a_gap_start_over);
    RUN_TEST(test_a_beat_out_of_turn_shows_at_once_and_keeps_the_tempo);
    RUN_TEST(test_a_beat_far_off_the_grid_moves_the_clock_at_once);
    RUN_TEST(test_with_the_clock_bpm_one_edge_gives_the_next_beat);
    RUN_TEST(test_with_the_clock_bpm_jitter_never_changes_the_beat_length);
    RUN_TEST(test_a_clock_bpm_change_applies_at_once);
    RUN_TEST(test_clock_bpm_0_leaves_the_beat_length_to_the_edges);
    RUN_TEST(test_the_clock_bpm_just_after_the_first_edge_times_it);
    RUN_TEST(test_a_clock_bpm_after_a_stop_doesnt_restart_it);
    RUN_TEST(test_a_lead_lights_the_next_beat_that_much_early);
    RUN_TEST(test_a_lead_longer_than_the_time_since_the_edge_shows_that_edge);
    RUN_TEST(test_a_lead_holds_through_a_tempo_change);
    return UNITY_END();
}
