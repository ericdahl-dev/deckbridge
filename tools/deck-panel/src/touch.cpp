// Implementation of the GT911 driver. From phrasedeck (#615); see LICENSE.crowpanel-drivers.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#include "touch.h"

#include <Arduino.h>
#include <Wire.h>
#include <lvgl.h>

#include "board_pins.h"
#include "gt911.h"
#include "panel_mcu.h"

namespace {

// GT911 register map, from the Goodix programming guide.
constexpr uint16_t REG_STATUS = 0x814E;

uint8_t g_addr = 0;
uint32_t g_last_poll_ms = 0;
gt911::Touch g_touch;

bool readRegs(uint16_t reg, uint8_t* out, size_t len) {
    Wire.beginTransmission(g_addr);
    Wire.write(static_cast<uint8_t>(reg >> 8));
    Wire.write(static_cast<uint8_t>(reg & 0xFF));
    if (Wire.endTransmission(false) != 0) return false;
    if (Wire.requestFrom(static_cast<int>(g_addr), static_cast<int>(len)) != static_cast<int>(len)) return false;
    for (size_t i = 0; i < len; ++i) out[i] = Wire.read();
    return true;
}

bool writeReg(uint16_t reg, uint8_t value) {
    Wire.beginTransmission(g_addr);
    Wire.write(static_cast<uint8_t>(reg >> 8));
    Wire.write(static_cast<uint8_t>(reg & 0xFF));
    Wire.write(value);
    return Wire.endTransmission() == 0;
}

bool probe(uint8_t addr) {
    Wire.beginTransmission(addr);
    return Wire.endTransmission() == 0;
}

// Cached state only: the I2C read happens in touch_poll() on its own interval.
void lvgl_read_cb(lv_indev_t*, lv_indev_data_t* data) {
    data->state = g_touch.pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
    data->point.x = g_touch.x;
    data->point.y = g_touch.y;
}

}  // namespace

bool touch_init() {
    pinMode(board::TP_INT, OUTPUT);
    digitalWrite(board::TP_INT, LOW);
    panel_mcu::activateTouch();
    delay(120);
    pinMode(board::TP_INT, INPUT);
    delay(100);

    if (probe(board::GT911_ADDR_PRIMARY)) {
        g_addr = board::GT911_ADDR_PRIMARY;
    } else if (probe(board::GT911_ADDR_BACKUP)) {
        g_addr = board::GT911_ADDR_BACKUP;
        Serial.println("touch: GT911 answered at 0x14, not 0x5D: the address latch did not take.");
    } else {
        Serial.println("touch: no GT911 at 0x5D or 0x14");
        return false;
    }
    Serial.printf("touch: GT911 at 0x%02X\n", g_addr);

    lv_indev_t* indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, lvgl_read_cb);
    return true;
}

uint8_t touch_address() { return g_addr; }

void touch_poll() {
    if (g_addr == 0) return;
    const uint32_t now = millis();
    if (now - g_last_poll_ms < board::TOUCH_POLL_MS) return;
    g_last_poll_ms = now;

    // Status and the first point are contiguous (0x814E..0x8153), so one six-byte read gets both.
    uint8_t buf[6] = {};
    const bool ok = readRegs(REG_STATUS, buf, sizeof(buf));
    gt911::decode(buf, ok, board::LCD_WIDTH, board::LCD_HEIGHT, g_touch);
    if (!ok || (buf[0] & 0x80) == 0) return;
    // The status register must be cleared or the controller stops reporting.
    writeReg(REG_STATUS, 0);
}

bool touch_pressed() { return g_touch.pressed; }
int16_t touch_x() { return g_touch.x; }
int16_t touch_y() { return g_touch.y; }
