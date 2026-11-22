#include "test_screen.h"

#include <Arduino.h>
#include <lvgl.h>

#include <cstdio>

#include "board_pins.h"
#include "test_pattern.h"
#include "touch.h"

#ifndef DECK_PANEL_SHA
#define DECK_PANEL_SHA "unknown"
#endif

namespace test_screen {

namespace {

lv_obj_t* g_touch_label = nullptr;
bool g_was_pressed = false;
int16_t g_shown_x = -1, g_shown_y = -1;

lv_obj_t* plain_box(lv_obj_t* parent) {
    lv_obj_t* box = lv_obj_create(parent);
    lv_obj_remove_style_all(box);  // no border, radius, padding or shadow: the box is exactly its area
    lv_obj_set_style_bg_opa(box, LV_OPA_COVER, 0);
    lv_obj_remove_flag(box, LV_OBJ_FLAG_SCROLLABLE);
    return box;
}

}  // namespace

void build() {
    lv_obj_t* screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    for (const test_pattern::Bar& bar : test_pattern::bars(board::LCD_WIDTH)) {
        lv_obj_t* box = plain_box(screen);
        lv_obj_set_pos(box, bar.x, 0);
        lv_obj_set_size(box, bar.width, board::LCD_HEIGHT);
        lv_obj_set_style_bg_color(box, lv_color_make(bar.r, bar.g, bar.b), 0);
    }

    // A black band across the middle carries the text, readable over every bar.
    lv_obj_t* band = plain_box(screen);
    lv_obj_set_size(band, board::LCD_WIDTH, 120);
    lv_obj_align(band, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(band, lv_color_black(), 0);

    char line[128];
    snprintf(line, sizeof line, "DeckBridge deck panel  %dx%d  V%d.%d  build %s", board::LCD_WIDTH,
             board::LCD_HEIGHT, CROWPANEL_ADVANCE_REV / 100, (CROWPANEL_ADVANCE_REV / 10) % 10, DECK_PANEL_SHA);
    lv_obj_t* title = lv_label_create(band);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_28, 0);
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_label_set_text(title, line);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 18);

    g_touch_label = lv_label_create(band);
    lv_obj_set_style_text_font(g_touch_label, &lv_font_montserrat_20, 0);
    lv_obj_set_style_text_color(g_touch_label, lv_color_white(), 0);
    lv_label_set_text(g_touch_label, touch_address() ? "Touch the screen" : "No touch controller found");
    lv_obj_align(g_touch_label, LV_ALIGN_BOTTOM_MID, 0, -18);
}

void show_touch() {
    const bool pressed = touch_pressed();
    if (!pressed || g_touch_label == nullptr) {
        g_was_pressed = pressed;
        return;
    }
    if (!g_was_pressed) Serial.printf("touch: %d,%d\n", touch_x(), touch_y());
    g_was_pressed = true;
    // Only when the point moves: each set redraws the label, and every redraw writes the framebuffer the panel is
    // scanning out.
    if (touch_x() == g_shown_x && touch_y() == g_shown_y) return;
    g_shown_x = touch_x();
    g_shown_y = touch_y();
    lv_label_set_text_fmt(g_touch_label, "Touch at %d, %d", g_shown_x, g_shown_y);
}

}  // namespace test_screen
