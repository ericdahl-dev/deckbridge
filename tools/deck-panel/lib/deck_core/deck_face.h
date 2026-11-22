// The deck screen's model (#621): what each widget shows, decided here from the deck's state so the board layer only
// draws, and compares widget by widget to redraw only what changed (fast fields come at up to 30 a second).
#pragma once

#include <cstdint>
#include <cstring>

#include "deck_types.h"
#include "deck_layout.h"

namespace deck_core {

/// The deck screen's colors, 0xRRGGBB.
namespace palette {
constexpr uint32_t kWhite = 0xFFFFFF, kBlack = 0x000000;
constexpr uint32_t kGray = 0xA0A0A0;   ///< names, the artist
constexpr uint32_t kDim = 0x5A5A5A;    ///< an unlit lamp's text
constexpr uint32_t kTrack = 0x262626;  ///< bars, unlit blocks and lamps
constexpr uint32_t kProgress = 0xE0E0E0, kWarning = 0xFF3B30, kLevel = 0x30D158;
/// Lit lamps: play, cue, sync, master, loop.
constexpr uint32_t kLamp[] = {0x30D158, 0xFF9F0A, 0x0A84FF, 0xFFD60A, 0x64D2FF};
}  // namespace palette

constexpr int kLamps = 5;

/// What the deck screen shows. Texts are UTF-8, fitted to the fonts (font_fallback); "" draws nothing. The number texts' sizes fit any long their format
/// can print, as GCC's -Wformat-truncation checks under -Werror (CI's Linux build), though real values are short.
struct Face {
    // Numbers and colors first, texts after, so the struct has padding only at its end (the field check below).
    uint32_t deck_color = palette::kWhite;  ///< the deck number's, 0xRRGGBB
    int32_t progress_px = 0;  ///< the bar's fill, 0 to layout::kWidth
    uint32_t progress_color = palette::kProgress;  ///< the fill: kWarning in the track's last seconds
    /// The phase bar (#721, the jog display's rule, #462): its track, the bar from the center (left edge and width
    /// from the bar's left, 0 wide for none) and the locked tick (1 shown).
    uint32_t phase_track_color = palette::kTrack;
    int32_t phase_bar_x = 0;
    int32_t phase_bar_w = 0;
    int32_t phase_tick = 0;
    int32_t level_px = 0;  ///< the meter's fill from the bottom, 0 to layout::kMeterH
    uint32_t beat_color[4] = {palette::kTrack, palette::kTrack, palette::kTrack, palette::kTrack};  ///< each block
    /// Play, cue, sync, master, loop: each lamp's box and text.
    uint32_t lamp_color[kLamps] = {palette::kTrack, palette::kTrack, palette::kTrack, palette::kTrack, palette::kTrack};
    uint32_t lamp_text_color[kLamps] = {palette::kDim, palette::kDim, palette::kDim, palette::kDim, palette::kDim};
    char deck[13] = "";  ///< "1"-"4"; 13, so the fields' sizes add up to the struct's with no padding (the check below)
    char title[kTextBytes] = "";
    char artist[kTextBytes] = "";
    char key[kKeyMax * 4 + 1] = "";
    char bpm[32] = "";
    char tempo[32] = "";
    char elapsed[32] = "";
    char remaining[32] = "";
    char loop_label[32] = "LOOP";  ///< the loop lamp's text, with the length when there is one: "LOOP 1/2"
};

/// Every field of Face, once: the parts below, what changed() compares and the check that none is left out all come
/// from this list. A new field goes in Face and here; one left out of here fails to compile.
#define DECK_FACE_FIELDS(ONE, MANY)                                                                                  \
    ONE(deck_color) ONE(progress_px) ONE(progress_color) ONE(phase_track_color) ONE(phase_bar_x) ONE(phase_bar_w)   \
    ONE(phase_tick) ONE(level_px) MANY(beat_color, 4) MANY(lamp_color, kLamps) MANY(lamp_text_color, kLamps)        \
    ONE(deck) ONE(title) ONE(artist) ONE(key) ONE(bpm) ONE(tempo) ONE(elapsed) ONE(remaining) ONE(loop_label)

/// A part of the screen that redraws on its own: one per field, one per element of an array field.
enum class Part : uint8_t {
#define DECK_PART_ONE(name) name,
#define DECK_PART_MANY(name, n) name, name##_end_ = name + (n)-1,
    DECK_FACE_FIELDS(DECK_PART_ONE, DECK_PART_MANY)
#undef DECK_PART_ONE
#undef DECK_PART_MANY
    count
};
static_assert(static_cast<int>(Part::count) <= 32, "Changes holds a bit per part");

namespace detail {
#define DECK_BYTES_ONE(name) +sizeof(Face::name)
#define DECK_BYTES_MANY(name, n) +sizeof(Face::name)
constexpr size_t kListedBytes = 0 DECK_FACE_FIELDS(DECK_BYTES_ONE, DECK_BYTES_MANY);
#undef DECK_BYTES_ONE
#undef DECK_BYTES_MANY
}  // namespace detail
// The listed fields fill the struct exactly, so a field of any size left out of the list fails here. A field whose
// size breaks the no-padding sum fails too: resize a text so the sum comes out a multiple of 4 again.
static_assert(sizeof(Face) == detail::kListedBytes, "a Face field is missing from DECK_FACE_FIELDS, or it pads");

/// The parts that differ between two faces.
class Changes {
  public:
    void set(Part part, int index = 0) { bits_ |= 1u << (static_cast<int>(part) + index); }
    bool has(Part part, int index = 0) const { return bits_ >> (static_cast<int>(part) + index) & 1u; }
    bool any() const { return bits_ != 0; }
    int count() const { return __builtin_popcount(bits_); }
    /// Every part: a screen that has drawn nothing yet.
    static Changes all() {
        Changes c;
        c.bits_ = static_cast<int>(Part::count) == 32 ? ~0u : (1u << static_cast<int>(Part::count)) - 1;
        return c;
    }

  private:
    uint32_t bits_ = 0;
};

Changes changed(const Face& was, const Face& now);

/// The progress bar warns for the track's last this many seconds.
constexpr int32_t kEndWarningSeconds = 30;

/// The text an empty deck shows in the title's place.
constexpr const char* kNoTrack = "No track loaded";

Face face(const DeckView& view);

}  // namespace deck_core
