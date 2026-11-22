#include "deck_face.h"

#include <cmath>
#include <cstdio>
#include <cstring>

#include "font_fallback.h"

namespace deck_core {

namespace {

/// `text` fitted to the fonts: a character they lack is "?". For the texts from outside (title, artist, key); the
/// numbers and times are printed here in ASCII, which the fonts have.
template <size_t N>
void copy(char (&out)[N], const char* text) {
    font_fallback::fit(text, out, N);
}

/// Whole seconds as "m:ss", or "h:mm:ss" past an hour, after `sign`. Negative counts as 0.
template <size_t N>
void time_text(char (&out)[N], const char* sign, int32_t seconds) {
    const long s = seconds < 0 ? 0 : seconds;
    if (s >= 3600) {
        std::snprintf(out, N, "%s%ld:%02ld:%02ld", sign, s / 3600, s / 60 % 60, s % 60);
    } else {
        std::snprintf(out, N, "%s%ld:%02ld", sign, s / 60, s % 60);
    }
}

/// A loop's length in beats: whole ("4"), a fraction of one beat ("1/2" … "1/32"), else as it is ("1.5").
template <size_t N>
void loop_text(char (&out)[N], float beats) {
    if (beats <= 0) return;
    const long whole = static_cast<long>(beats + 0.5f);
    if (whole >= 1 && std::fabs(beats - static_cast<float>(whole)) < 0.001f) {
        std::snprintf(out, N, "%ld", whole);
        return;
    }
    for (long below = 2; below <= 64; below *= 2) {
        if (std::fabs(beats - 1.0f / static_cast<float>(below)) < 0.0001f) {
            std::snprintf(out, N, "1/%ld", below);
            return;
        }
    }
    std::snprintf(out, N, "%g", static_cast<double>(beats));
}

/// `x`, taken at 2 decimals, in tenths rounded half away from zero: 128.25 is 1283, -2.55 is -26.
long tenths(float x) {
    const long hundredths = std::lround(static_cast<double>(x) * 100);
    return (hundredths + (hundredths < 0 ? -5 : 5)) / 10;
}

/// `x` at one decimal, without its sign, after `sign` and before `unit`.
template <size_t N>
void tenths_text(char (&out)[N], const char* sign, float x, const char* unit = "") {
    const long signed_tenths = tenths(x);
    const long t = signed_tenths < 0 ? -signed_tenths : signed_tenths;
    std::snprintf(out, N, "%s%ld.%ld%s", sign, t / 10, t % 10, unit);
}

float clamp01(float x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

/// `fraction`, clamped to 0-1, of `span`, in whole pixels, half away from zero.
int32_t pixels(float fraction, int span) { return static_cast<int32_t>(std::lround(clamp01(fraction) * span)); }

/// The phase bar's center, its half width (#721).
constexpr int32_t kPhaseHalf = layout::kWidth / 2;

/// `color` at 35% over the dark track, each channel rounded: the phase bar's track off phase (#462's dim).
uint32_t dimmed(uint32_t color) {
    uint32_t out = 0;
    for (int shift = 16; shift >= 0; shift -= 8) {
        const float c = 0.35f * static_cast<float>(color >> shift & 0xFF) + 0.65f * static_cast<float>(palette::kTrack >> shift & 0xFF);
        out |= static_cast<uint32_t>(std::lround(c)) << shift;
    }
    return out;
}

/// The bar's length for an offset of `beats` (0 to 0.5) off phase: #462's curve, zoomed near 0, so a hundredth of a
/// beat is a third of the half bar and half a beat all of it; at least 1 px.
int32_t phase_bar_length(float beats) {
    const auto g = [](float p) { return p / (p + 0.02f); };
    const long length = std::lround(static_cast<float>(kPhaseHalf) * g(beats) / g(0.5f));
    return static_cast<int32_t>(length < 1 ? 1 : length > kPhaseHalf ? kPhaseHalf : length);
}

/// A color light enough that a white mark on it barely shows (#721): its lightness, Rec. 709's weights over 256,
/// at least 160 of 255.
bool light(uint32_t color) {
    const uint32_t r = color >> 16 & 0xFF, g = color >> 8 & 0xFF, b = color & 0xFF;
    return (54 * r + 183 * g + 19 * b) >> 8 >= 160;
}

}  // namespace

Face face(const DeckView& view) {
    Face f;
    if (view.deck >= 1 && view.deck <= 4) std::snprintf(f.deck, sizeof f.deck, "%d", view.deck);
    // Black is the background: a deck without a color shows white.
    f.deck_color = view.color == 0 ? palette::kWhite : view.color;
    if (!view.loaded) {
        // Empty: the deck and "No track loaded", nothing else, never the last track.
        copy(f.title, kNoTrack);
        return f;
    }
    copy(f.title, view.title);
    copy(f.artist, view.artist);
    copy(f.key, view.key);
    // One decimal (the owner's look at #633). Both arrive at 2 decimals; rounded from those, half away from zero, so
    // the result doesn't depend on how the float holds them. 0 BPM is unknown, and with it the tempo.
    if (view.bpm > 0) {
        tenths_text(f.bpm, "", view.bpm);
        const long tempo = tenths(view.tempo);
        if (tempo == 0) {
            copy(f.tempo, "0.0%");
        } else {
            tenths_text(f.tempo, tempo > 0 ? "+" : "-", view.tempo, "%");
        }
    }
    time_text(f.elapsed, "", view.elapsed);
    // A known length (#682): remaining above 0, or 0 at the track's end. DeckBridge sends progress 0 whenever it
    // doesn't know the length, so remaining 0 with progress above 0 is the end, never "not told yet".
    const bool length_known = view.remaining > 0 || view.progress > 0;
    if (length_known) time_text(f.remaining, "-", view.remaining);
    f.progress_px = pixels(view.progress, layout::kWidth);
    if (length_known && view.remaining <= kEndWarningSeconds) f.progress_color = palette::kWarning;
    if (view.beat >= 1 && view.beat <= 4) f.beat_color[view.beat - 1] = f.deck_color;
    const bool lit[kLamps] = {view.playing, view.cue, view.sync, view.master, view.loop};
    for (int i = 0; i < kLamps; ++i) {
        if (!lit[i]) continue;
        f.lamp_color[i] = palette::kLamp[i];
        f.lamp_text_color[i] = palette::kBlack;
    }
    char length[24] = "";
    loop_text(length, view.loop_length);
    if (length[0]) std::snprintf(f.loop_label, sizeof f.loop_label, "LOOP %s", length);
    // The phase bar (#721, the jog display's rule, #462). Locked is exactly 0.5: DeckBridge holds it there.
    if (view.phase == 0.5f) {
        f.phase_track_color = f.deck_color;
        f.phase_tick = 1;
        f.phase_tick_color = light(f.deck_color) ? palette::kBlack : palette::kWhite;
    } else if (view.phase >= 0) {
        f.phase_track_color = dimmed(f.deck_color);
        const float off = view.phase - 0.5f;  // beats: below 0 behind
        const int32_t length = phase_bar_length(off < 0 ? -off : off);
        f.phase_bar_w = length;
        f.phase_bar_x = off < 0 ? kPhaseHalf - length : kPhaseHalf;
    }
    f.level_px = pixels(view.level, layout::kMeterH);
    return f;
}

namespace {

bool same(uint32_t a, uint32_t b) { return a == b; }
bool same(int32_t a, int32_t b) { return a == b; }
template <size_t N>
bool same(const char (&a)[N], const char (&b)[N]) {
    return std::strcmp(a, b) == 0;
}

}  // namespace

Changes changed(const Face& was, const Face& now) {
    Changes c;
#define DECK_CHANGED_ONE(name) \
    if (!same(was.name, now.name)) c.set(Part::name);
#define DECK_CHANGED_MANY(name, n) \
    for (int i = 0; i < (n); ++i)  \
        if (!same(was.name[i], now.name[i])) c.set(Part::name, i);
    DECK_FACE_FIELDS(DECK_CHANGED_ONE, DECK_CHANGED_MANY)
#undef DECK_CHANGED_ONE
#undef DECK_CHANGED_MANY
    return c;
}

}  // namespace deck_core
