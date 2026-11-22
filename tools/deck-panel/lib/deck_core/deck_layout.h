// The deck screen's layout in pixels (#490, #621), on the 800x480. Here, not in the board layer, because the core
// decides what is drawn down to the pixel (#665): a fill or bar moves only when a whole pixel changes.
#pragma once

#include <cstdint>

namespace deck_core::layout {

constexpr int kScreenW = 800, kScreenH = 480;
constexpr int kMargin = 40;  // the waiting screen's
constexpr int kLeft = 24;
constexpr int kWidth = 704;  // the rows under the header, left of the meter
constexpr int kHeaderX = 100, kHeaderY = 16;
constexpr int kInfoY = 146;  // key, BPM, tempo
constexpr int kTimeY = 190;
constexpr int kProgressY = 280, kProgressH = 36;
constexpr int kBeatY = 328, kBeatH = 24, kBeatGap = 8;
constexpr int kPhaseY = 366, kPhaseH = 28;
/// The phase bar's locked tick (#721): white, centered on the bar, reaching past it above and below (into the gaps
/// to the beats, which end at 352, and the lamps, which start at 410).
constexpr int kPhaseTickW = 6, kPhaseTickReach = 6;
constexpr int kLampY = 410, kLampH = 46, kLampGap = 12;
constexpr int kMeterX = 748, kMeterW = 28, kMeterY = kInfoY, kMeterH = kLampY + kLampH - kInfoY;

}  // namespace deck_core::layout
