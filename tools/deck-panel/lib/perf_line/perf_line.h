// The perf build's serial line (#635, -DPANEL_PERF_LOG): one window's numbers as text. Kept free of Arduino so it's
// host-tested; src/perf_log.cpp gathers the numbers and prints it every 5 s.
#pragma once

#include <cstdint>
#include <string>

#include "bounce_budget.h"
#include "frame_clock.h"
#include "frame_ledger.h"
#include "scan_watch.h"


namespace perf_line {

struct Window {
    uint32_t ms = 0;                // how long the window was
    uint32_t frames = 0;            // LVGL refreshes in it that drew something
    uint64_t frame_us = 0;          // their time, start to end (a release still outstanding waits inside, #663)
    uint32_t frame_max_us = 0;
    uint32_t vsyncs = 0;            // the panel's (39 a second at 16 MHz, drawing or not)
    uint32_t swaps = 0;             // frames handed to the panel
    uint32_t swap_timeouts = 0;     // swaps the panel never released within 60 ms
    uint64_t swap_wait_us = 0;      // LVGL waiting for a release
    uint64_t draw_bitmap_us = 0;    // handing frames over
    uint32_t datagrams = 0;         // feed datagrams read; lwIP's own drops aren't visible here
    uint32_t too_big = 0;           // feed datagrams dropped for size
    uint32_t dropped = 0;           // feed datagrams dropped with the intake full (#664)
    bool drops_counted = true;      // false with no receive task: lwIP's drops past its mailbox aren't seen (#713)
    uint32_t internal_free = 0;     // bytes
    scan_watch::Report scan;        // the scan-out's steadiness
    uint32_t copy_budget_us = 0;    // a bounce chunk's deadline
    bounce_budget::Report copy;     // the bounce copies against it; no chunks when the build can't time them
    uint32_t copy_late_drawing = 0; // of copy.late, those during the loop's LVGL refresh (#663)
    uint32_t copy_late_turn = 0;    // of copy.late, those within 3 ms after a latch: the frame turn (#663)
    frame_ledger::Report ledger;    // feed data's arrival to glass (#662)
    frame_clock::Report clock;      // the frame clock's frames, late ones, missed latches, waits no latch ended (#663)
};

std::string format(const Window& w);

// Where the bounce copies ran (#663), perf build only: by eighth of the scan-out since the latch, and by the loop step
// the copy's interrupt broke into. Every copy is counted, and the late ones apart, so a bucket's lates read against
// its copies.
constexpr int kPhases = 8;
enum class Mark : uint8_t { wait, read, render, refresh, wifi, udp, touch, lvgl, perf, other, count };
constexpr int kMarks = static_cast<int>(Mark::count);

// One late copy: its start after the latch, its length, and the loop's step (a Mark).
struct LateCopy {
    uint32_t start_us;
    uint32_t took_us;
    uint8_t mark;
};

struct CopySpread {
    static constexpr int kKept = 8;  // late copies kept per window, the first ones
    uint32_t copies_by_phase[kPhases] = {};
    uint32_t late_by_phase[kPhases] = {};
    uint32_t copies_by_mark[kMarks] = {};
    uint32_t late_by_mark[kMarks] = {};
    // Not the panel interrupt's: in none of the above.
    uint32_t outside_isr = 0;
    uint32_t late_outside_isr = 0;
    // While the UART still drains the last print: also in the steps above.
    uint32_t while_printing = 0;
    uint32_t late_while_printing = 0;
    LateCopy lates[kKept] = {};
    int kept = 0;
};

// The eighth of a `period_us` scan-out that `since_latch_us` falls in; one period or more is the last.
// In the header so the board's IRAM copy wrapper inlines it, and 32-bit for a frame's period, so no 64-bit division
// per chunk (#666; __udivdi3 resolves to ROM here, but the 32-bit path is cheaper still).
inline int phase(uint32_t since_latch_us, uint32_t period_us) {
    if (period_us == 0 || since_latch_us >= period_us) return kPhases - 1;
    if (period_us <= UINT32_MAX / kPhases) return static_cast<int>(since_latch_us * kPhases / period_us);
    return static_cast<int>(static_cast<uint64_t>(since_latch_us) * kPhases / period_us);
}

// The second perf line: "perf copy: late/copies by eighth after the latch ...; by loop step ...".
std::string format_copy(const CopySpread& c);

}  // namespace perf_line
