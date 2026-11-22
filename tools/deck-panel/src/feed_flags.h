// The feed path's A/B switches (#664, PR #713's perf change): build flags that split a measurement change from a real
// cost. The defaults are the panel's build; set one with PLATFORMIO_BUILD_FLAGS (platformio.ini, env crowpanel-perf).
//   FEED_RX_TASK=0        main's old path: no receive task, the loop drains the socket in the frame's read step
//                         (feed_drain::Drain) and the chores poll it; the ledger is stamped at the drain, as on main.
//   FEED_STAMP_AT_READ=1  the receive task and intake stay, but the ledger is told the drain's time, not the
//                         arrivals: main's measurement on #713's path.
//   FEED_RX_WAIT_MS=N     the receive task waits on the socket (select) for up to N ms, then minds Wi-Fi (and the
//                         cable, #711) and waits again: woken by a datagram, else N ms on. Bounded, never forever: the
//                         cable isn't a socket, so nothing could wake a wait for it. Default 5.
//   FEED_RX_DELAY_TICKS=N the receive task doesn't wait on the socket: it looks, then sleeps N ticks (1 ms each), as
//                         #713 did (1 there; env crowpanel-perf-rx-5ms is 5). 0, the default, is the wait above.
// The boot line names any that differ from the default.
#pragma once

#ifndef FEED_RX_TASK
#define FEED_RX_TASK 1
#endif
#ifndef FEED_STAMP_AT_READ
#define FEED_STAMP_AT_READ 0
#endif
#ifndef FEED_RX_WAIT_MS
#define FEED_RX_WAIT_MS 5
#endif
#ifndef FEED_RX_DELAY_TICKS
#define FEED_RX_DELAY_TICKS 0
#endif

#if FEED_RX_WAIT_MS < 1
#error "FEED_RX_WAIT_MS must be 1 or more: select() given no time only looks, and the task would spin"
#endif
#if FEED_RX_DELAY_TICKS < 0
#error "FEED_RX_DELAY_TICKS must be 0 (wait on the socket) or more"
#endif
#if !FEED_RX_TASK && (FEED_STAMP_AT_READ || FEED_RX_DELAY_TICKS != 0 || FEED_RX_WAIT_MS != 5)
#error "FEED_STAMP_AT_READ, FEED_RX_WAIT_MS and FEED_RX_DELAY_TICKS are for the receive task; FEED_RX_TASK=0 has none"
#endif
