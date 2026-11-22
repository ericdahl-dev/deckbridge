// The STC8H1K28 companion microcontroller at I2C 0x30. Taken over from the owner's phrasedeck firmware (#615);
// see LICENSE.crowpanel-drivers. The bytes themselves come from lib/backlight, which is host-tested.
//
// On this board the backlight is NOT on a GPIO. An MT9201 boost is driven by a
// second microcontroller, and you turn the backlight on by sending it an I2C
// command. The same part owns the GT911's reset line, the buzzer, the
// amplifier's mute, and the battery charger's status lines.
//
// The command encoding INVERTED between board revisions:
//
//   V1.2    0x10 = on (brightest), 0x05 = off.   Touch activation: 0x19
//   V1.3+   0 = brightest, 244 = dimmest,        Touch activation: 250
//           245 = off. Writing 255 is out of range, not bright.
//
// Writes are a single bare byte with no register address.
//
// Getting this wrong produces a black screen with no error, no serial
// complaint, and a correctly scanning panel behind it - which reads as a dead
// board. The companion MCU acknowledges any byte, so a write cannot report
// whether it was understood; therefore begin() does not probe. The revision
// comes from the compile-time constant CROWPANEL_ADVANCE_REV (which defaults to
// V1.3 and later—the current stock). begin() logs which revision it is driving
// and what to change if the screen stays dark.
//
// Once the revision is known, set CROWPANEL_ADVANCE_REV in platformio.ini.
//
// The part is a black box. Elecrow publish no source and no register
// specification, its behavior changed between revisions, and it is not
// reflashable through the ESP32. Do not probe undefined command bytes to
// discover the rest of its table; Elecrow advise against it and there is no way
// to undo a mistake.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#pragma once

#include <cstdint>

namespace panel_mcu {

// Probes for the companion MCU on the I2C bus. Wire.begin() must already have
// been called. Returns false if nothing answered at 0x30, which on a V1.0 board
// is expected - that revision has an I/O expander at 0x18 instead and is not
// supported here.
bool begin();

// Whether anything answers at 0x30, with nothing logged: for waiting on a chip that comes up after the ESP32.
bool probe();

// CROWPANEL_ADVANCE_REV (140 for the owner's V1.4; 130 or more is V1.3 and later, 120 V1.2), or 0 if begin() has
// not run or found
// nothing. Log this at startup: on a board whose revision you have not checked,
// it is the fastest way to find out.
int detectedRevision();

// Each returns false if the chip never acknowledged a byte (lib/backlight retries each byte, and this logs it).
//
// Full brightness. Call this LAST, after the panel is initialized and the RGB
// clocks have settled, or the screen flashes on boot.
bool backlightOn();

bool backlightOff();

// 0 (off) to 100 (brightest). The revision's encoding is applied internally, so
// callers never see the inverted V1.3+ scale.
bool backlightLevel(uint8_t percent);

// Asks the companion MCU to reset the touch controller. The caller must hold
// board::TP_INT low across this call to latch the GT911 at address 0x5D.
bool activateTouch();

}  // namespace panel_mcu
