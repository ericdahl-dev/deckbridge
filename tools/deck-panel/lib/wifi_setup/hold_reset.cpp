#include "hold_reset.h"

namespace wifi_setup {

bool HoldReset::update(bool pressed, bool waiting_screen, uint32_t now_ms) {
    if (!pressed) {
        holding_ = false;
        fired_ = false;
        on_deck_ = false;
        return false;
    }
    if (!waiting_screen) {
        holding_ = false;
        on_deck_ = true;
        return false;
    }
    if (fired_ || on_deck_) return false;
    if (!holding_) {
        holding_ = true;
        since_ms_ = now_ms;
    }
    // Unsigned subtraction, so the clock wrapping is no jump.
    if (now_ms - since_ms_ < kHoldMs) return false;
    fired_ = true;
    return true;
}

}  // namespace wifi_setup
