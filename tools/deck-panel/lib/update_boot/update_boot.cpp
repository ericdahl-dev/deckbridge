#include "update_boot.h"

namespace update_boot {

Decision decide(const State& s) {
    if (!s.trial) return Decision::nothing;
    const bool network = s.saved_wifi ? s.wifi_joined : s.setup_network_up;
    if (network && s.update_listening) return Decision::confirm;
    return s.since_boot_ms >= kTrialMs ? Decision::roll_back : Decision::wait;
}

}  // namespace update_boot
