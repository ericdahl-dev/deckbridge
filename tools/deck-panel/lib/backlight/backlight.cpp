// The encoding is Elecrow's, as phrasedeck's panel_mcu.cpp has it (see LICENSE.crowpanel-drivers).
#include "backlight.h"

namespace backlight {
namespace {

// V1.3 and later: the scale runs backwards, 0 brightest and 244 dimmest. 255 is out of range, not bright.
constexpr uint8_t kV13Brightest = 0;
constexpr uint8_t kV13Dimmest = 244;
constexpr uint8_t kV13Off = 245;
constexpr uint8_t kV13Touch = 250;

// V1.2: 0x05 to 0x10, and dimming needs 0x10 sent first.
constexpr uint8_t kV12On = 0x10;
constexpr uint8_t kV12Off = 0x05;
constexpr uint8_t kV12Touch = 0x19;

}  // namespace

Bytes level(int revision, uint8_t percent) {
    if (percent > 100) percent = 100;
    if (revision >= 130) {
        if (percent == 0) return {{kV13Off, 0}, 1};
        const unsigned span = kV13Dimmest - kV13Brightest;
        return {{static_cast<uint8_t>(span - span * percent / 100), 0}, 1};
    }
    if (percent == 0) return {{kV12Off, 0}, 1};
    const unsigned span = kV12On - kV12Off;
    return {{kV12On, static_cast<uint8_t>(kV12Off + span * percent / 100)}, 2};
}

uint8_t touch_activate(int revision) { return revision >= 130 ? kV13Touch : kV12Touch; }

bool send(const Bytes& bytes, const std::function<bool(uint8_t)>& put) {
    for (uint8_t i = 0; i < bytes.count; ++i) {
        bool acked = false;
        for (int t = 0; t < kTries && !acked; ++t) acked = put(bytes.bytes[i]);
        if (!acked) return false;
    }
    return true;
}

}  // namespace backlight
