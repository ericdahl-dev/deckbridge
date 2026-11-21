// The feed path's A/B switches (#664, PR #713's perf change): build flags that split a measurement change from a real
// cost. The defaults are #713 as merged; set one with PLATFORMIO_BUILD_FLAGS (platformio.ini, env crowpanel-perf).
//   FEED_RX_TASK=0        main's old path: no receive task, the loop drains the socket in the frame's read step
//                         (feed_drain::Drain) and the chores poll it; the ledger is stamped at the drain, as on main.
//   FEED_STAMP_AT_READ=1  the receive task and intake stay, but the ledger is told the drain's time, not the
//                         arrivals: main's measurement on #713's path.
//   FEED_RX_DELAY_TICKS=N the receive task sleeps N ticks (1 ms each) between looks, not 1: fewer core-0 wakes.
// The boot line names any that differ from the default.
#pragma once

#ifndef FEED_RX_TASK
#define FEED_RX_TASK 1
#endif
#ifndef FEED_STAMP_AT_READ
#define FEED_STAMP_AT_READ 0
#endif
#ifndef FEED_RX_DELAY_TICKS
#define FEED_RX_DELAY_TICKS 1
#endif

#if FEED_RX_DELAY_TICKS < 1
#error "FEED_RX_DELAY_TICKS must be 1 or more"
#endif
#if !FEED_RX_TASK && (FEED_STAMP_AT_READ || FEED_RX_DELAY_TICKS != 1)
#error "FEED_STAMP_AT_READ and FEED_RX_DELAY_TICKS are for the receive task; FEED_RX_TASK=0 has none"
#endif
