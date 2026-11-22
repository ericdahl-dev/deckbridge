// The deck panel's test screen (#615), in the crowpanel-test build: color bars across the whole 800 x 480, a line
// saying what's running, and the last touch. It proves the screen, the color order, the backlight and touch before any
// of the display feed.
#pragma once

namespace test_screen {

/// Builds the screen on the active LVGL screen. touch_init() must have run.
void build();

/// Shows the last touch; call every loop after touch_poll().
void show_touch();

}  // namespace test_screen
