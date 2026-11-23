// Whether a newly switched-to image confirms itself (#690). It boots as a trial (ESP-IDF rollback); it confirms only
// once it has brought up what recovery needs, so a bad release can always be replaced over Wi-Fi:
//   - with saved Wi-Fi: joined, and the update server listening;
//   - with none (setup mode, #622): the setup network up, and the update server listening on it.
// Not the display feed: a panel updated with DeckBridge closed would otherwise roll a good image back every time.
// If that isn't reached within kTrialMs, the panel restarts into the previous image.
#pragma once

#include <cstdint>

namespace update_boot {

constexpr uint32_t kTrialMs = 120000;

struct State {
    bool trial = false;             ///< this image runs as a trial: switched to, not yet confirmed
    bool saved_wifi = false;
    bool wifi_joined = false;
    bool setup_network_up = false;
    bool update_listening = false;
    uint32_t since_boot_ms = 0;
};

enum class Decision { nothing, wait, confirm, roll_back };

Decision decide(const State& state);

}  // namespace update_boot
