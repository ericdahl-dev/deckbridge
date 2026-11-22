// The panel's setup network (#622): "DeckPanel-" and the MAC's last two bytes, and a WPA2 password made fresh each
// time setup opens, shown on the panel's screen. The home Wi-Fi's password crosses this network, so it isn't open.
// Kept free of Arduino so it's host-tested; the board passes esp_random.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

namespace wifi_setup {

void network_name(const uint8_t mac[6], char* out, size_t room);

// 10 characters a person reads off a screen and types on a phone: letters and digits, without 0/O/o, 1/l/I.
void setup_password(const std::function<uint32_t()>& random, char* out, size_t room);

}  // namespace wifi_setup
