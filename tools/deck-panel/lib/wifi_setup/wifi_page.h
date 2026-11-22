// The setup page (#622), served by the panel on its setup network: the networks it can see, strongest first, and a
// form to pick one and give its password. Kept free of Arduino so it's host-tested. Every name is escaped: a network
// can be called anything.
#pragma once

#include <cstddef>
#include <string>

namespace wifi_setup {

// One network from a scan.
struct Seen {
    const char* ssid;
    int rssi;  // dBm
};

// error: the last form's problem, or "". The password is never put back into the form.
std::string setup_page(const Seen* seen, size_t count, const char* error, const char* panel_network);

// After a good form: the panel saves and restarts onto `ssid`. Only the name: never the password.
std::string saved_page(const char* ssid);

}  // namespace wifi_setup
