#include "swap_gate.h"

namespace swap_gate {

bool Gate::flush(bool last_area) { return !last_area; }

void Gate::swapped() {
    // Outstanding first, then armed: armed first, a vsync in between could release a wait that isn't set up yet.
    outstanding_ = true;
    armed_.store(true);
}

bool Gate::vsync() { return armed_.exchange(false); }

bool Gate::must_wait() const { return outstanding_; }

void Gate::waited(bool got_vsync) {
    // Disarmed, so a vsync after a timeout doesn't release the next frame early.
    armed_.store(false);
    outstanding_ = false;
    if (!got_vsync) ++timeouts_;
}

uint32_t Gate::timeouts() const { return timeouts_; }

}  // namespace swap_gate
