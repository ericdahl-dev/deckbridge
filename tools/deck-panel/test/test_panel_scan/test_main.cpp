// The panel scan module (#666): the panel's timing, swaps, frames and health in one place, run here against a scripted
// panel so the order of interrupts and loop calls is tested.
#include <unity.h>

#include "panel_scan.h"
#include "scripted_panel.h"

void setUp() {}
void tearDown() {}

using panel_scan::Config;
using panel_scan::Scan;
using panel_scan::Wait;

// The owner's panel: 800x480 at 12.3 MHz, porches 8/4/8 both ways, bounce chunks of 8000 px.
static Config owners(uint32_t bounce_px = 8000, uint32_t pclk_hz = 12300000) {
    return Config{{pclk_hz, 800, 480, 8, 4, 8, 8, 4, 8}, bounce_px};
}

void test_start_gives_the_panel_its_timing() {
    ScriptedPanel panel;
    Scan scan(panel);
    TEST_ASSERT_TRUE(scan.start(owners()));
    TEST_ASSERT_TRUE(panel.started);
    TEST_ASSERT_EQUAL(12300000, panel.config.timing.pclk_hz);
    TEST_ASSERT_EQUAL(8000, panel.config.bounce_px);
    // 820 x 500 clocks at 12.3 MHz: 33333 us a scan-out; a chunk of 8000 px is 10 rows, 666 us.
    TEST_ASSERT_EQUAL(33333, scan.frame_us());
    TEST_ASSERT_EQUAL(666, scan.copy_budget_us());
}

// An odd number of chunks a frame flips which buffer the interrupt refills each frame, and it refills the one going
// out (the banding of #635); a size that doesn't divide the frame is no chunk count at all. Refused, panel untouched.
void test_start_refuses_a_bounce_size_that_isnt_an_even_count_of_chunks() {
    for (uint32_t bad : {7000u, 128000u, 384000u / 3}) {
        ScriptedPanel panel;
        Scan scan(panel);
        TEST_ASSERT_FALSE_MESSAGE(scan.start(owners(bad)), "refused");
        TEST_ASSERT_FALSE(panel.started);
    }
}

// Without bounce buffers there's no copy and no budget.
void test_no_bounce_buffers_has_no_copy_budget() {
    ScriptedPanel panel;
    Scan scan(panel);
    TEST_ASSERT_TRUE(scan.start(owners(0)));
    TEST_ASSERT_EQUAL(0, scan.copy_budget_us());
}

// Another pixel clock is one config change: 16 MHz gives 25625 us and a 512 us chunk.
void test_another_pixel_clock_is_one_change() {
    ScriptedPanel panel;
    Scan scan(panel);
    TEST_ASSERT_TRUE(scan.start(owners(8000, 16000000)));
    TEST_ASSERT_EQUAL(25625, scan.frame_us());
    TEST_ASSERT_EQUAL(512, scan.copy_budget_us());
}


using Irq = ScriptedPanel::Irq;

// Areas before a frame's last are drawn in place and released at once; the last hands the buffer to the panel.
void test_only_a_frames_last_area_goes_to_the_panel() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    TEST_ASSERT_TRUE(scan.present(false));
    TEST_ASSERT_EQUAL(0, panel.hand_overs);
    TEST_ASSERT_FALSE(scan.present(true));
    TEST_ASSERT_EQUAL(1, panel.hand_overs);
}

// Bounce buffers: the driver takes the next buffer at frame complete, when the last chunk of this one is copied, not at
// the vsync. A swap released at the vsync would let LVGL draw into a buffer still feeding a whole frame (#635).
void test_with_bounce_buffers_the_frame_end_releases_a_swap_not_the_vsync() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{1000, Irq::vsync}, {20000, Irq::frame_complete}};
    scan.present(true);
    TEST_ASSERT_EQUAL(Wait::deferred, scan.wait_release(60));  // the one right after the swap
    TEST_ASSERT_EQUAL(Wait::released, scan.wait_release(60));
    TEST_ASSERT_EQUAL(20000, panel.now_us);  // not 1000
}

// Without bounce buffers the GDMA reads the framebuffer itself, from the vsync on: the vsync releases it.
void test_without_bounce_buffers_the_vsync_releases_a_swap() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners(0));
    panel.script = {{1000, Irq::vsync}};
    scan.present(true);
    TEST_ASSERT_EQUAL(Wait::deferred, scan.wait_release(60));
    TEST_ASSERT_EQUAL(Wait::released, scan.wait_release(60));
    TEST_ASSERT_EQUAL(1000, panel.now_us);
}

// Nothing handed over: nothing to wait for.
void test_with_no_swap_out_the_wait_returns_at_once() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{20000, Irq::frame_complete}};
    TEST_ASSERT_EQUAL(Wait::released, scan.wait_release(60));
    TEST_ASSERT_EQUAL(0, panel.now_us);
}


// No latch in time (a stopped panel): the wait gives up and says so.
void test_a_release_that_never_comes_times_out() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    scan.present(true);
    scan.wait_release(60);
    TEST_ASSERT_EQUAL(Wait::timed_out, scan.wait_release(60));
    TEST_ASSERT_EQUAL(60000, panel.now_us);
}

// The latch for a timed-out swap comes as the wait gives up, after the semaphore timed out but before the gate hears
// of it, so it gives. That give is stale: the next swap still waits for its own latch, or LVGL draws into the buffer
// on glass.
void test_a_late_latch_never_releases_the_next_swap() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{60000, Irq::frame_complete}, {93333, Irq::frame_complete}};
    scan.present(true);
    scan.wait_release(60);
    TEST_ASSERT_EQUAL(Wait::timed_out, scan.wait_release(60));  // gives up at 60 ms, as the latch comes
    scan.present(true);
    scan.wait_release(60);
    TEST_ASSERT_EQUAL(Wait::released, scan.wait_release(60));
    TEST_ASSERT_EQUAL(93333, panel.now_us);  // its own latch, not the stale one
}


// #663: LVGL waits once more right after the swap, in the same refresh. Blocking there would hold the loop to the next
// latch and starve the chores, so that wait returns at once with the swap still out. The next frame's first wait,
// before anything is drawn into the buffer that may be on glass, takes the release; it came at the latch the frame
// woke on, so that wait doesn't block.
void test_the_wait_right_after_the_swap_is_deferred_to_the_next_frame() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{33333, Irq::frame_complete}};
    panel.run_until(5000);
    scan.present(true);
    TEST_ASSERT_EQUAL(Wait::deferred, scan.wait_release(60));
    TEST_ASSERT_EQUAL(5000, panel.now_us);  // no time spent
    panel.run_until(34000);                 // the chores, then the next frame wakes after the latch
    TEST_ASSERT_EQUAL(Wait::released, scan.wait_release(60));
    TEST_ASSERT_EQUAL(34000, panel.now_us);  // already given: no wait
}


using panel_scan::Latches;

// The frame clock's wait (#663): until a latch newer than the one current on entry, so a frame always starts just
// after a latch. It returns the latch, and the one before it for the ledger (#664), in esp_timer microseconds.
void test_the_next_frame_starts_at_the_next_latch() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{33333, Irq::frame_complete}};
    panel.run_until(5000);
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_next_frame(70, l));
    TEST_ASSERT_EQUAL(33333, panel.now_us);
    TEST_ASSERT_EQUAL(1, l.count);
    TEST_ASSERT_EQUAL_UINT64(33333, l.us);
    TEST_ASSERT_EQUAL_UINT64(0, l.previous_us);
}

// A latch that came before the call, its give still pending, never starts the frame: the frame waits for the next.
void test_a_latch_from_before_the_call_doesnt_start_the_frame() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{1000, Irq::frame_complete}, {34333, Irq::frame_complete}};
    panel.run_until(2000);  // the loop was busy through the first latch
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_next_frame(70, l));
    TEST_ASSERT_EQUAL(34333, panel.now_us);
    TEST_ASSERT_EQUAL(2, l.count);
    TEST_ASSERT_EQUAL_UINT64(34333, l.us);
    TEST_ASSERT_EQUAL_UINT64(1000, l.previous_us);
}

// Latches the loop missed are in the count; latches() is the same stamp, for any task.
void test_latches_counts_every_latch_and_keeps_the_last_two() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{33333, Irq::frame_complete}, {66666, Irq::frame_complete}, {99999, Irq::frame_complete}};
    panel.run_until(100000);
    const Latches l = scan.latches();
    TEST_ASSERT_EQUAL(3, l.count);
    TEST_ASSERT_EQUAL_UINT64(99999, l.us);
    TEST_ASSERT_EQUAL_UINT64(66666, l.previous_us);
}

// Microseconds past 2^32 (71 minutes) stay whole: the ledger compares them with 64-bit arrival stamps.
void test_latch_times_are_64_bit() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    const uint64_t late = (uint64_t(1) << 32) + 5000;
    panel.script = {{late, Irq::frame_complete}};
    panel.run_until(late);
    TEST_ASSERT_EQUAL_UINT64(late, scan.latches().us);
}

// A stopped panel: no frame, the wait gives up.
void test_no_latch_in_time_is_no_frame() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    Latches l;
    TEST_ASSERT_FALSE(scan.wait_next_frame(70, l));
    TEST_ASSERT_EQUAL(70000, panel.now_us);
}

// The other wake (#679's option A): the vsync after a latch, about 1.9 ms later with bounce buffers. If it already
// came, at once.
void test_the_vsync_after_a_latch() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{31400, Irq::frame_complete}, {33333, Irq::vsync}};
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_next_frame(70, l));
    TEST_ASSERT_EQUAL(31400, panel.now_us);
    TEST_ASSERT_TRUE(scan.wait_vsync_after(l, 70));
    TEST_ASSERT_EQUAL(33333, panel.now_us);
    TEST_ASSERT_TRUE(scan.wait_vsync_after(l, 70));  // already came
    TEST_ASSERT_EQUAL(33333, panel.now_us);
}


// The health since the last look, one report: what the panel scanned, what was swapped and timed out, the scan's
// steadiness (scan_watch) and the copy's margin (bounce_budget). A look starts a new window.
void test_health_reports_one_window_then_starts_another() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    // Frames 33333 us apart; the frame end 31400 us after each vsync (the copy finishing the last chunk).
    panel.script = {{0, Irq::vsync},     {31400, Irq::frame_complete}, {33333, Irq::vsync},
                    {64733, Irq::frame_complete}, {66666, Irq::vsync}, {98066, Irq::frame_complete}};
    scan.present(true);
    scan.wait_release(60);
    scan.wait_release(60);  // released at 31400
    scan.present(true);
    scan.wait_release(60);
    panel.run_until(100000);
    scan.present(true);
    scan.wait_release(60);
    scan.wait_release(60);  // nothing more scripted: times out
    const panel_scan::Health h = scan.take_health();
    TEST_ASSERT_EQUAL(3, h.vsyncs);
    TEST_ASSERT_EQUAL(3, h.swaps);
    TEST_ASSERT_EQUAL(1, h.swap_timeouts);
    TEST_ASSERT_EQUAL(3, h.latches);
    TEST_ASSERT_EQUAL(31400, h.scan.lag_min_us);
    TEST_ASSERT_EQUAL(31400, h.scan.lag_max_us);
    TEST_ASSERT_EQUAL(33333, h.scan.vsync_min_us);
    TEST_ASSERT_EQUAL(0, h.scan.resyncs);
    const panel_scan::Health next = scan.take_health();
    TEST_ASSERT_EQUAL(0, next.vsyncs + next.swaps + next.swap_timeouts + next.latches);
}

// A frame end that moves more than 500 us against its vsync is a resync: the panel lost its place.
void test_a_frame_end_that_jumps_is_a_resync() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{0, Irq::vsync}, {31400, Irq::frame_complete}, {33333, Irq::vsync}, {65733, Irq::frame_complete}};
    panel.run_until(70000);
    TEST_ASSERT_EQUAL(1, scan.take_health().scan.resyncs);
}

// The copy (#635, #650): each chunk's time against its 666 us budget. A late one is counted where it fell (#663): while
// the loop draws, or within 3 ms after a latch, the frame turn. Anywhere else it's late all the same.
void test_late_copies_are_counted_where_they_fell() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{31400, Irq::frame_complete}};
    panel.run_until(31400);
    scan.copied(500, 31900, false);   // in time
    scan.copied(700, 32400, false);   // late, 1 ms after the latch: the turn
    scan.copied(800, 40000, true);    // late, while drawing
    scan.copied(670, 50000, false);   // late, neither
    const panel_scan::Health h = scan.take_health();
    TEST_ASSERT_EQUAL(4, h.copy.chunks);
    TEST_ASSERT_EQUAL(800, h.copy.worst_us);
    TEST_ASSERT_EQUAL(3, h.copy.late);
    TEST_ASSERT_EQUAL(1, h.copy_late_turn);
    TEST_ASSERT_EQUAL(1, h.copy_late_drawing);
}

// The panel's interrupts start inside its start(), before start() returns: the scan already knows its config then, so
// an early vsync with bounce buffers is no latch (the frame end is).
struct EarlyPanel : ScriptedPanel {
    bool start(const panel_scan::Config& c) override {
        ScriptedPanel::start(c);
        scan->vsync(500);
        return true;
    }
};

void test_interrupts_during_start_see_the_config() {
    EarlyPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    TEST_ASSERT_TRUE(scan.start(owners()));
    TEST_ASSERT_EQUAL(0, scan.latches().count);
}

// Without bounce buffers the latch is the vsync, one interrupt: the vsync after it has come with it, not a frame later.
void test_without_bounce_buffers_the_vsync_after_a_latch_is_the_latch() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners(0));
    panel.script = {{33333, Irq::vsync}, {66666, Irq::vsync}};
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_next_frame(70, l));
    TEST_ASSERT_TRUE(scan.wait_vsync_after(l, 70));
    TEST_ASSERT_EQUAL(33333, panel.now_us);
}

// Where a copy fell is where it started (#663, as the copy line files it): one that starts 2.5 ms after the latch is in
// the turn even if it ends past 3 ms.
void test_a_late_copy_is_placed_by_its_start() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{31400, Irq::frame_complete}};
    panel.run_until(31400);
    scan.copied(700, 31400 + 3200, false);  // started 2500 us after the latch
    TEST_ASSERT_EQUAL(1, scan.take_health().copy_late_turn);
}

// The perf line looks at the health in three parts (the counts, the scan, the copy), one after another. They share one
// window: each part comes from it once, and looking at a part again takes a new window.
void test_the_health_is_looked_at_in_parts_of_one_window() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{0, Irq::vsync}, {31400, Irq::frame_complete}, {33333, Irq::vsync}, {65733, Irq::frame_complete}};
    panel.run_until(70000);
    scan.copied(700, 70000, false);
    panel_scan::HealthLooks looks;
    using Part = panel_scan::HealthLooks::Part;
    TEST_ASSERT_EQUAL(2, looks.look(scan, Part::counts).vsyncs);
    TEST_ASSERT_EQUAL(1, looks.look(scan, Part::scan).scan.resyncs);
    TEST_ASSERT_EQUAL(1, looks.look(scan, Part::copy).copy.chunks);
    panel.script.push_back({99999, Irq::vsync});
    panel.run_until(100000);
    const panel_scan::Health& next = looks.look(scan, Part::counts);
    TEST_ASSERT_EQUAL(1, next.vsyncs);
    TEST_ASSERT_EQUAL(0, next.copy.chunks);
}

// The frame wait in one wake (#666): the vsync after the next latch, so the loop wakes once a frame and not again
// between the latch and the draw (#663: nothing but the feed in that gap).
void test_the_frame_wait_wakes_once_at_the_vsync_after_the_next_latch() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{31400, Irq::frame_complete}, {33333, Irq::vsync}};
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_frame(70, l));
    TEST_ASSERT_EQUAL(33333, panel.now_us);
    TEST_ASSERT_EQUAL(1, l.count);
    TEST_ASSERT_EQUAL(31400, l.us);
    TEST_ASSERT_EQUAL(1, panel.wakes);
}

// A vsync with no new latch before it (the latch late, or the call just after a latch) doesn't end the wait.
void test_the_frame_wait_needs_a_latch_newer_than_the_call() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{1000, Irq::frame_complete}};
    panel.run_until(1500);
    panel.script.push_back({2933, Irq::vsync});
    panel.script.push_back({34733, Irq::frame_complete});
    panel.script.push_back({36666, Irq::vsync});
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_frame(70, l));
    TEST_ASSERT_EQUAL(36666, panel.now_us);
    TEST_ASSERT_EQUAL(2, l.count);
    TEST_ASSERT_EQUAL(34733, l.us);
}

// Without bounce buffers the latch is the vsync: one interrupt, one wake.
void test_without_bounce_buffers_the_frame_wait_ends_at_the_latch() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners(0));
    panel.script = {{33333, Irq::vsync}};
    Latches l;
    TEST_ASSERT_TRUE(scan.wait_frame(70, l));
    TEST_ASSERT_EQUAL(33333, panel.now_us);
    TEST_ASSERT_EQUAL(33333, l.us);
    TEST_ASSERT_EQUAL(1, panel.wakes);
}

// No frame in time: false at the timeout.
void test_the_frame_wait_times_out() {
    ScriptedPanel panel;
    Scan scan(panel);
    panel.scan = &scan;
    scan.start(owners());
    panel.script = {{31400, Irq::frame_complete}};
    Latches l;
    TEST_ASSERT_FALSE(scan.wait_frame(70, l));
    TEST_ASSERT_EQUAL(70000, panel.now_us);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_start_gives_the_panel_its_timing);
    RUN_TEST(test_start_refuses_a_bounce_size_that_isnt_an_even_count_of_chunks);
    RUN_TEST(test_no_bounce_buffers_has_no_copy_budget);
    RUN_TEST(test_another_pixel_clock_is_one_change);
    RUN_TEST(test_only_a_frames_last_area_goes_to_the_panel);
    RUN_TEST(test_with_bounce_buffers_the_frame_end_releases_a_swap_not_the_vsync);
    RUN_TEST(test_without_bounce_buffers_the_vsync_releases_a_swap);
    RUN_TEST(test_with_no_swap_out_the_wait_returns_at_once);
    RUN_TEST(test_a_release_that_never_comes_times_out);
    RUN_TEST(test_a_late_latch_never_releases_the_next_swap);
    RUN_TEST(test_the_wait_right_after_the_swap_is_deferred_to_the_next_frame);
    RUN_TEST(test_the_next_frame_starts_at_the_next_latch);
    RUN_TEST(test_a_latch_from_before_the_call_doesnt_start_the_frame);
    RUN_TEST(test_latches_counts_every_latch_and_keeps_the_last_two);
    RUN_TEST(test_latch_times_are_64_bit);
    RUN_TEST(test_no_latch_in_time_is_no_frame);
    RUN_TEST(test_the_vsync_after_a_latch);
    RUN_TEST(test_health_reports_one_window_then_starts_another);
    RUN_TEST(test_a_frame_end_that_jumps_is_a_resync);
    RUN_TEST(test_late_copies_are_counted_where_they_fell);
    RUN_TEST(test_interrupts_during_start_see_the_config);
    RUN_TEST(test_without_bounce_buffers_the_vsync_after_a_latch_is_the_latch);
    RUN_TEST(test_a_late_copy_is_placed_by_its_start);
    RUN_TEST(test_the_health_is_looked_at_in_parts_of_one_window);
    RUN_TEST(test_the_frame_wait_wakes_once_at_the_vsync_after_the_next_latch);
    RUN_TEST(test_the_frame_wait_needs_a_latch_newer_than_the_call);
    RUN_TEST(test_without_bounce_buffers_the_frame_wait_ends_at_the_latch);
    RUN_TEST(test_the_frame_wait_times_out);
    return UNITY_END();
}
