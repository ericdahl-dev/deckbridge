// The panel's Wi-Fi (#620, #622): a station on the network saved in NVS, or, with none saved, the panel's own setup
// network with a captive page to pick one. No blocking waits: everything is polled from the loop task, which reports
// the state to the core.
#pragma once

#include <cstdint>

#include "deck_core.h"

namespace wifi_link {

/// Starts joining the saved network, or opens setup when none is saved. Call once, after the first frame.
void begin();

/// Reads the station's state, or serves setup (the page, the scan, the restart after a save); call every loop.
/// Cheap: the address is read at most twice a second.
void poll(uint32_t now_ms);

/// Valid before begin(): the first call loads the saved network, so the first frame says what's true.
deck_core::Network state();

/// The panel's IPv4 address, dotted: the setup network's own while in setup, "" while joining.
const char* ip();

/// The setup network's name and password, for the screen only; "" unless in setup. Valid before begin().
const char* setup_name();
const char* setup_password();

/// Counts connections: changes each time the station (re)joins, so the UDP socket knows to open again.
uint32_t joins();

/// Forgets the saved network and restarts into setup. Does not return.
[[noreturn]] void forget_and_restart();

}  // namespace wifi_link
