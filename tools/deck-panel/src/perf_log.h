// The perf build's serial line (#635), env crowpanel-perf (-DPANEL_PERF_LOG): every 5 s, frames/s, render and swap
// times, vsyncs, swap timeouts, the feed's datagrams and free internal RAM, so a try on the panel has numbers, not
// only eyes. The text is lib/perf_line's, host-tested. Without PANEL_PERF_LOG these do nothing.
#pragma once

#include <cstdint>

#include "frame_clock.h"

namespace perf_log {

// After display_init(): times LVGL's refreshes and flushes.
void begin();

// Every frame, in the chores (#673), after the frame's render and refresh: `datagrams` read by this frame's drain,
// `too_big` the drains' running count of datagrams too big for a slot, `dropped` the core's lost datagrams from
// DeckBridge's bundle numbers (#750), counted only when `drops_counted` (a numbered feed came). Prints the line when a 5 s window is up and `may_print` (the frame has time
// left), else at a later frame; `clock`'s report goes in it. The print goes into Serial's TX buffer, so it costs the
// loop only the formatting while the buffer has room; the ledger can't see that time.
void tick(uint32_t now_ms, int datagrams, uint32_t too_big, uint32_t dropped, bool drops_counted, bool may_print,
          frame_clock::Clock& clock);

#ifdef PANEL_PERF_LOG
// The frame ledger's hooks (#662), perf build only, all on the loop's task (LVGL's too); times are esp_timer
// microseconds. The panel interrupt only stamps latches (display_latch()); these replay them into the ledger before
// each event, so a latch is always seen in its place between the events around it. A refresh that drew nothing tells
// the ledger itself (LVGL's REFR_READY with no flush): the frame clock refreshes every frame.

// FeedUdp: a datagram was first seen waiting on the socket, and was read.
void feed_seen(uint32_t us);
void feed_read(uint32_t us);
// The display driver: a frame was handed to the panel with `latches` latches so far (the last at `latch_us`), and
// the latch that released it, the start of its scan-out.
void frame_swapped(uint32_t latches, uint32_t latch_us, uint32_t swapped_us);
void frame_on_glass(uint32_t release_us);
#endif

}  // namespace perf_log
