// GT911 capacitive touch over raw I2C, polled. From phrasedeck's touch driver (#615), without its rotation; see
// LICENSE.crowpanel-drivers. The decoding is lib/gt911, host-tested.
//
// The GT911 latches its I2C address from its interrupt line during reset (low 0x5D, high 0x14), and reset belongs to
// the companion chip: hold the line low, ask panel_mcu, wait, release, then probe both addresses. Polling too eagerly
// starves the panel's DMA and shakes the picture (Elecrow's issue #8), so touch_poll() limits itself to
// board::TOUCH_POLL_MS and is safe to call every loop.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#pragma once

#include <cstdint>

// Runs the address-latching reset, probes both addresses and registers an LVGL pointer device. Wire.begin() and
// panel_mcu::begin() must have run first. False if neither address answered; not fatal.
bool touch_init();

// The address that answered, or 0.
uint8_t touch_address();

// Reads the controller at most once per board::TOUCH_POLL_MS.
void touch_poll();

// As of the last poll: whether a finger is down, and where it is (or last was).
bool touch_pressed();
int16_t touch_x();
int16_t touch_y();
