// The deck panel's view types (#619, #665): what the core holds and what the waiting screen says. Apart from
// deck_core.h so deck_face.h, which the core holds, can use them.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace deck_core {

/// The longest title and artist shown, in characters; longer ones are cut and end in "…" (#490).
constexpr size_t kTitleMax = 40;
constexpr size_t kArtistMax = 40;
/// Room for 40 characters of up to 4 bytes each, and the NUL. No text is kept on the heap: the board's small
/// allocations come from the internal RAM LVGL and Wi-Fi use.
/// A key, such as "11B" or "F#m", fits in this many characters.
constexpr size_t kKeyMax = 4;
constexpr size_t kTextBytes = 40 * 4 + 1;
static_assert(kTitleMax <= 40 && kArtistMax <= 40, "kTextBytes holds 40 characters");

/// What the deck screen shows.
struct DeckView {
    int deck = 0;  ///< 1-4; 0 until the feed says
    uint32_t color = 0;  ///< 0xRRGGBB
    char title[kTextBytes] = "";  ///< UTF-8, shortened
    char artist[kTextBytes] = "";
    bool loaded = true;  ///< until the feed says 0
    char key[kKeyMax * 4 + 1] = "";  ///< shortened like the title
    float bpm = 0;
    float tempo = 0;  ///< percent
    bool playing = false, cue = false, sync = false, master = false, loop = false;
    float loop_length = 0;  ///< beats
    int beat = 0;  ///< 1-4; 0 none
    int32_t elapsed = 0, remaining = 0;  ///< whole seconds
    float progress = 0;  ///< 0-1
    float phase = -1;  ///< 0-1, 0.5 in phase; -1 unknown
    float level = 0;  ///< 0-1

    /// Every field: one added later goes here too, or a change to it won't redraw.
    bool operator==(const DeckView& o) const {
        return deck == o.deck && color == o.color && std::strcmp(title, o.title) == 0 &&
               std::strcmp(artist, o.artist) == 0 && loaded == o.loaded && std::strcmp(key, o.key) == 0 &&
               bpm == o.bpm && tempo == o.tempo && playing == o.playing && cue == o.cue && sync == o.sync &&
               master == o.master && loop == o.loop && loop_length == o.loop_length && beat == o.beat &&
               elapsed == o.elapsed && remaining == o.remaining && progress == o.progress && phase == o.phase &&
               level == o.level;
    }
};

/// The panel's network, as the board layer reports it (#620).
enum class Network {
    setup,    ///< no saved Wi-Fi: the panel's own setup network is up (#622)
    joining,  ///< joining, or lost and rejoining
    connected,
};

/// What the waiting screen says.
struct WaitingView {
    char headline[48] = "";
    char detail[96] = "";
    bool logo = false;  ///< the DeckBridge logo above the lines (#651)
    bool logo_small = false;  ///< at half size, for the setup screen's longer text (#677)

    bool operator==(const WaitingView& other) const {
        return std::strcmp(headline, other.headline) == 0 && std::strcmp(detail, other.detail) == 0 &&
               logo == other.logo && logo_small == other.logo_small;
    }
};

/// The waiting screen's parts that differ from what its objects hold.
struct WaitingChanges {
    bool headline = false;
    bool detail = false;
    bool logo = false;  ///< shown or hidden (#651)
    bool logo_small = false;  ///< its size (#677)

    bool any() const { return headline || detail || logo || logo_small; }
    static WaitingChanges all() { return {true, true, true, true}; }
};

/// What changed between two waiting views: every field of WaitingView, as its == compares them.
inline WaitingChanges changed(const WaitingView& was, const WaitingView& now) {
    WaitingChanges c;
    c.headline = std::strcmp(was.headline, now.headline) != 0;
    c.detail = std::strcmp(was.detail, now.detail) != 0;
    c.logo = was.logo != now.logo;
    c.logo_small = was.logo_small != now.logo_small;
    return c;
}

}  // namespace deck_core
