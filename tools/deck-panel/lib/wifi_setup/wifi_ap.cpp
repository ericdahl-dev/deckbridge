#include "wifi_ap.h"

#include <cstdio>
#include <cstring>

namespace wifi_setup {
namespace {

// 55 letters and digits without 0, O, o, 1, l, I.
constexpr char kAlphabet[] = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
constexpr uint32_t kSize = sizeof kAlphabet - 1;
// 10 of 55: about 58 bits, against cracking a captured handshake offline. Still short to type.
constexpr size_t kLength = 10;

}  // namespace

void network_name(const uint8_t mac[6], char* out, size_t room) {
    std::snprintf(out, room, "DeckPanel-%02X%02X", mac[4], mac[5]);
}

void setup_password(const std::function<uint32_t()>& random, char* out, size_t room) {
    if (room == 0) return;
    // Rejects the top of the range that doesn't divide evenly, so every character is as likely.
    const uint32_t limit = UINT32_MAX - UINT32_MAX % kSize;
    size_t n = 0;
    while (n < kLength && n + 1 < room) {
        const uint32_t r = random();
        if (r >= limit) continue;
        out[n++] = kAlphabet[r % kSize];
    }
    out[n] = 0;
}

}  // namespace wifi_setup
