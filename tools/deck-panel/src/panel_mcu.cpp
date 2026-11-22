// Implementation of the companion MCU driver. From phrasedeck's panel_mcu.cpp (#615); see LICENSE.crowpanel-drivers.
// The revision's bytes are lib/backlight's; this file only puts them on the bus.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#include "panel_mcu.h"

#include <Arduino.h>
#include <Wire.h>

#include "backlight.h"
#include "board_pins.h"

namespace panel_mcu {
namespace {

int g_revision = 0;

// A single bare byte, no register address. Returns true if the device ACKed.
bool send(uint8_t command) {
    Wire.beginTransmission(board::PANEL_MCU_ADDR);
    Wire.write(command);
    return Wire.endTransmission() == 0;
}

bool present() {
    Wire.beginTransmission(board::PANEL_MCU_ADDR);
    return Wire.endTransmission() == 0;
}

// Sends through lib/backlight's retries, 10 ms apart, and says so if the chip never ACKed: a lost backlight byte is
// otherwise a dark screen with nothing in the log.
bool put(const backlight::Bytes& bytes, const char* what) {
    const bool ok = backlight::send(bytes, [](uint8_t b) {
        if (send(b)) return true;
        delay(10);
        return false;
    });
    if (!ok) Serial.printf("panel_mcu: %s byte not acknowledged after %d tries\n", what, backlight::kTries);
    return ok;
}

}  // namespace

bool begin() {
    g_revision = 0;

    if (!present()) {
        Serial.printf("panel_mcu: nothing at 0x%02X.\n", board::PANEL_MCU_ADDR);
        Serial.println("panel_mcu: a V1.0 board has an expander at 0x18 instead,");
        Serial.println("panel_mcu: which this firmware does not support.");
        return false;
    }

    // The device ACKs any byte, so probing cannot tell the revisions apart. Trust the compile-time setting.
    g_revision = CROWPANEL_ADVANCE_REV;
    Serial.printf("panel_mcu: found at 0x%02X, driving it as V%d.%d\n",
                  board::PANEL_MCU_ADDR, g_revision / 100, (g_revision / 10) % 10);
    Serial.println("panel_mcu: if the screen stays dark, check the silkscreen and");
    Serial.println("panel_mcu: set CROWPANEL_ADVANCE_REV in platformio.ini.");
    return true;
}

bool probe() { return present(); }

int detectedRevision() { return g_revision; }

bool backlightOn() { return backlightLevel(100); }

bool backlightOff() { return backlightLevel(0); }

bool backlightLevel(uint8_t percent) { return put(backlight::level(CROWPANEL_ADVANCE_REV, percent), "backlight"); }

bool activateTouch() {
    return put({{backlight::touch_activate(CROWPANEL_ADVANCE_REV), 0}, 1}, "touch activation");
}

}  // namespace panel_mcu
