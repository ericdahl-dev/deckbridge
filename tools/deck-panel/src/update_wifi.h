// The firmware update over Wi-Fi, board side (#690, ADR 0012, docs/DECK-PANEL-UPDATE-PROTOCOL.md): the TCP server
// on port 3310 in its own task on core 0, the spare slot over esp_ota, the floor in NVS, the still "Updating" screen,
// and the trial after a switch (confirm, or roll back to the previous image). The protocol and the rules are
// lib/update_link, lib/update_session and lib/update_boot; this only plugs the board into their seams.
//
// Everything here but the task is called from the loop task (Arduino's, core 1). The task and the loop share only
// atomics: the network being up, the server listening, the still screen wanted and on glass, the floor changed.
#pragma once

#include <cstdint>

namespace update_wifi {

/// Call once in setup(), after display_init() and wifi_link::begin(): reads the floor and the trial state from flash,
/// builds the still screen (hidden) and starts the update task. The task listens once the network is up.
void begin();

/// Every frame, from the chores: tells the task whether the network is up, and runs the trial after an update
/// (lib/update_boot): confirms the image, raising the floor, or rolls back and restarts. Cheap when not on trial.
void chores(uint32_t now_ms);

/// In render(): true while an update holds the screen; skip drawing the deck. The first call that returns true puts
/// the still screen up (LVGL, loop task); the call after the update ends hides it again and returns false.
bool hold_render();

/// In refresh(): true when there's nothing to hand the panel. While held, one refresh puts the still screen on glass,
/// then none until the update ends.
bool hold_refresh();

}  // namespace update_wifi
