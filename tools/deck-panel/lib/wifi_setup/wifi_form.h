// The panel's Wi-Fi setup (#622): the setup page's form, as the phone posts it (application/x-www-form-urlencoded),
// decoded and checked before anything is saved. Kept free of Arduino so it's host-tested.
#pragma once

#include <cstddef>

namespace wifi_setup {

struct Credentials {
    char ssid[33] = "";      // 1 to 32 bytes, any bytes
    char password[65] = "";  // empty (open), 8 to 63 printable ASCII, or 64 hex digits
};

struct FormResult {
    bool ok = false;
    Credentials credentials;
    const char* error = "";  // for the page, when not ok
};

// Fields: ssid (a network from the list), ssid_other (a typed name, which wins when not empty), password.
FormResult parse_form(const char* body, size_t length);

}  // namespace wifi_setup
