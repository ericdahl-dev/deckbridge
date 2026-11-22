// The CrowPanel Advance's companion chip (STC8H1K28 at I2C 0x30) takes single bare bytes for the backlight and the
// touch reset, and their meaning changed between board revisions (#615). Kept free of Arduino so it's host-tested;
// src/panel_mcu.cpp sends what this returns.
#pragma once

#include <cstdint>
#include <functional>

namespace backlight {

// The bytes to send, in order: one, or two for V1.2's dimming.
struct Bytes {
    uint8_t bytes[2];
    uint8_t count;
};

// revision: 130 or more for V1.3 and later, 120 for V1.2 (CROWPANEL_ADVANCE_REV). percent: 0 (off) to 100.
Bytes level(int revision, uint8_t percent);

uint8_t touch_activate(int revision);

// Tries for each byte before giving up: the chip can NAK while it's busy, and it comes up after the ESP32.
constexpr int kTries = 3;

// Sends the bytes in order through put, which returns whether the chip ACKed (and does any wait between tries). Each
// byte is tried up to kTries times; false, and nothing more sent, once a byte never gets an ACK.
bool send(const Bytes& bytes, const std::function<bool(uint8_t)>& put);

}  // namespace backlight
