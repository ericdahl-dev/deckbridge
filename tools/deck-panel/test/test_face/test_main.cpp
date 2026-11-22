// The deck screen's model (#621): what each widget shows, decided from the deck's state, so the board only draws.
#include <unity.h>

#include <cstring>
#include <initializer_list>

#include "deck_face.h"

void setUp() {}
void tearDown() {}

using deck_core::DeckView;
using deck_core::Face;

static DeckView loaded_deck() {
    DeckView v;
    v.deck = 1;
    v.color = 0xFF0000;
    v.loaded = true;
    std::strcpy(v.title, "Night Drive");
    std::strcpy(v.artist, "Example Artist");
    std::strcpy(v.key, "Am");
    v.bpm = 126;
    v.tempo = 0.8f;
    v.playing = v.sync = v.master = v.loop = true;
    v.loop_length = 0.5f;
    v.beat = 3;
    v.elapsed = 95;
    v.remaining = 212;
    v.progress = 0.3125f;
    v.phase = 0.5f;
    v.level = 0.75f;
    return v;
}

// An empty deck shows as empty: the deck number in its color and "No track loaded", every other widget blank or off.
void test_an_empty_deck_shows_no_track_loaded_and_nothing_else() {
    DeckView v = loaded_deck();
    v.loaded = false;
    const Face f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("1", f.deck);
    TEST_ASSERT_EQUAL_HEX32(0xFF0000, f.deck_color);
    TEST_ASSERT_EQUAL_STRING("No track loaded", f.title);
    for (const char* text : {f.artist, f.key, f.bpm, f.tempo, f.elapsed, f.remaining})
        TEST_ASSERT_EQUAL_STRING("", text);
    TEST_ASSERT_EQUAL_STRING("LOOP", f.loop_label);
    TEST_ASSERT_EQUAL(deck_core::kPhaseHidden, f.phase_px);
    TEST_ASSERT_EQUAL_HEX32(0xE0E0E0, f.progress_color);
    for (uint32_t c : f.beat_color) TEST_ASSERT_EQUAL_HEX32(0x262626, c);
    for (uint32_t c : f.lamp_color) TEST_ASSERT_EQUAL_HEX32(0x262626, c);
    TEST_ASSERT_EQUAL(0, f.progress_px);
    TEST_ASSERT_EQUAL(0, f.level_px);
}

void test_a_loaded_deck_shows_its_title_and_artist() {
    const Face f = deck_core::face(loaded_deck());
    TEST_ASSERT_EQUAL_STRING("Night Drive", f.title);
    TEST_ASSERT_EQUAL_STRING("Example Artist", f.artist);
    TEST_ASSERT_EQUAL_STRING("Am", f.key);
}

// BPM and tempo show at one decimal (the owner's look at #633), rounded half away from zero from the 2 decimals they
// arrive at, so the panel rounds them one way whatever the float holds.
void test_bpm_and_tempo_show_at_1_decimal_tempo_signed() {
    DeckView v = loaded_deck();
    TEST_ASSERT_EQUAL_STRING("126.0", deck_core::face(v).bpm);
    TEST_ASSERT_EQUAL_STRING("+0.8%", deck_core::face(v).tempo);
    v.bpm = 128.25f;
    v.tempo = -2.55f;
    TEST_ASSERT_EQUAL_STRING("128.3", deck_core::face(v).bpm);
    TEST_ASSERT_EQUAL_STRING("-2.6%", deck_core::face(v).tempo);
    v.bpm = 174.04f;
    v.tempo = 0.85f;
    TEST_ASSERT_EQUAL_STRING("174.0", deck_core::face(v).bpm);
    TEST_ASSERT_EQUAL_STRING("+0.9%", deck_core::face(v).tempo);
    v.tempo = 0;
    TEST_ASSERT_EQUAL_STRING("0.0%", deck_core::face(v).tempo);
    v.tempo = -0.04f;  // rounds to 0: no sign
    TEST_ASSERT_EQUAL_STRING("0.0%", deck_core::face(v).tempo);
}

void test_an_unknown_bpm_shows_neither_bpm_nor_tempo() {
    DeckView v = loaded_deck();
    v.bpm = 0;
    TEST_ASSERT_EQUAL_STRING("", deck_core::face(v).bpm);
    TEST_ASSERT_EQUAL_STRING("", deck_core::face(v).tempo);
}

void test_times_show_as_minutes_and_seconds_remaining_with_a_minus() {
    DeckView v = loaded_deck();
    TEST_ASSERT_EQUAL_STRING("1:35", deck_core::face(v).elapsed);
    TEST_ASSERT_EQUAL_STRING("-3:32", deck_core::face(v).remaining);
    v.elapsed = 0;
    v.remaining = 5;
    TEST_ASSERT_EQUAL_STRING("0:00", deck_core::face(v).elapsed);
    TEST_ASSERT_EQUAL_STRING("-0:05", deck_core::face(v).remaining);
}

void test_past_an_hour_times_show_hours() {
    DeckView v = loaded_deck();
    v.elapsed = 3723;
    v.remaining = 3600;
    TEST_ASSERT_EQUAL_STRING("1:02:03", deck_core::face(v).elapsed);
    TEST_ASSERT_EQUAL_STRING("-1:00:00", deck_core::face(v).remaining);
}

// No known length: DeckBridge sends remaining 0 and progress 0 (it can't place the position without the length).
void test_with_no_known_length_remaining_is_blank() {
    DeckView v = loaded_deck();
    v.remaining = 0;
    v.progress = 0;
    TEST_ASSERT_EQUAL_STRING("", deck_core::face(v).remaining);
    TEST_ASSERT_EQUAL_STRING("1:35", deck_core::face(v).elapsed);
}

// The bar is 704 px; its fill in whole pixels, so a change too small to move a pixel is no change.
void test_the_progress_fill_is_whole_pixels_of_the_704_px_bar() {
    DeckView v = loaded_deck();
    TEST_ASSERT_EQUAL(220, deck_core::face(v).progress_px);  // 0.3125 of 704
    v.progress = 1.5f;
    TEST_ASSERT_EQUAL(704, deck_core::face(v).progress_px);
    v.progress = -0.2f;
    TEST_ASSERT_EQUAL(0, deck_core::face(v).progress_px);
    v.progress = 0.0007f;  // 0.49 px
    TEST_ASSERT_EQUAL(0, deck_core::face(v).progress_px);
    v.progress = 0.0010f;  // 0.70 px
    TEST_ASSERT_EQUAL(1, deck_core::face(v).progress_px);
}

// The warning: the last 30 seconds, as DJ players flash it, the bar in red. Not with no known length (remaining and
// progress 0); at the end it stays (#682, below).
void test_the_bar_turns_red_in_the_last_30_seconds() {
    TEST_ASSERT_EQUAL(30, deck_core::kEndWarningSeconds);
    DeckView v = loaded_deck();
    v.remaining = 31;
    TEST_ASSERT_EQUAL_HEX32(0xE0E0E0, deck_core::face(v).progress_color);
    v.remaining = 30;
    TEST_ASSERT_EQUAL_HEX32(0xFF3B30, deck_core::face(v).progress_color);
    v.remaining = 1;
    TEST_ASSERT_EQUAL_HEX32(0xFF3B30, deck_core::face(v).progress_color);
    v.remaining = 0;
    v.progress = 0;
    TEST_ASSERT_EQUAL_HEX32(0xE0E0E0, deck_core::face(v).progress_color);
}

// The lit block is the deck's color, the others the track's gray; none outside 1-4.
void test_the_beat_lights_its_block_in_the_deck_color() {
    DeckView v = loaded_deck();
    Face f = deck_core::face(v);
    const uint32_t beat3[] = {0x262626, 0x262626, 0xFF0000, 0x262626};
    TEST_ASSERT_EQUAL_HEX32_ARRAY(beat3, f.beat_color, 4);
    for (int beat : {0, 5}) {
        v.beat = beat;
        f = deck_core::face(v);
        for (uint32_t c : f.beat_color) TEST_ASSERT_EQUAL_HEX32(0x262626, c);
    }
}

// Black is the background, so a deck without a color shows white, the number and the lit block both.
void test_a_deck_without_a_color_shows_white() {
    DeckView v = loaded_deck();
    v.color = 0;
    const Face f = deck_core::face(v);
    TEST_ASSERT_EQUAL_HEX32(0xFFFFFF, f.deck_color);
    TEST_ASSERT_EQUAL_HEX32(0xFFFFFF, f.beat_color[2]);
}

// Lit: the lamp's own color with black text. Unlit: the track's gray with dim text.
void test_the_lamps_light_in_their_colors() {
    DeckView v = loaded_deck();  // play, sync, master, loop on; cue off
    Face f = deck_core::face(v);
    const uint32_t lit[] = {0x30D158, 0x262626, 0x0A84FF, 0xFFD60A, 0x64D2FF};
    const uint32_t text[] = {0x000000, 0x5A5A5A, 0x000000, 0x000000, 0x000000};
    TEST_ASSERT_EQUAL_HEX32_ARRAY(lit, f.lamp_color, 5);
    TEST_ASSERT_EQUAL_HEX32_ARRAY(text, f.lamp_text_color, 5);
    v.playing = v.sync = v.master = v.loop = false;
    v.cue = true;
    f = deck_core::face(v);
    const uint32_t cue[] = {0x262626, 0xFF9F0A, 0x262626, 0x262626, 0x262626};
    TEST_ASSERT_EQUAL_HEX32_ARRAY(cue, f.lamp_color, 5);
}

// The loop lamp's label: the length in beats, as the LC6000's loop display shows them, whole or a fraction of one.
void test_the_loop_lamp_shows_whole_beats_or_fractions() {
    DeckView v = loaded_deck();
    const struct { float beats; const char* text; } cases[] = {
        {0.5f, "LOOP 1/2"}, {0.25f, "LOOP 1/4"}, {0.125f, "LOOP 1/8"}, {0.0625f, "LOOP 1/16"}, {0.03125f, "LOOP 1/32"},
        {1, "LOOP 1"}, {4, "LOOP 4"}, {16, "LOOP 16"}, {1.5f, "LOOP 1.5"}, {0, "LOOP"},
    };
    for (const auto& c : cases) {
        v.loop_length = c.beats;
        TEST_ASSERT_EQUAL_STRING(c.text, deck_core::face(v).loop_label);
    }
}

// Texts come fitted to the fonts: a character they don't have is "?", never an empty box.
void test_texts_come_fitted_to_the_fonts() {
    DeckView v = loaded_deck();
    std::strcpy(v.title, "T\xC5\x8Dky\xC5\x8D \xE6\x9D\xB1");  // "Tōkyō 東": ō is in the fonts, 東 isn't
    std::strcpy(v.artist, "\xE2\x98\x85 Star");  // ★
    const Face f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("T\xC5\x8Dky\xC5\x8D ?", f.title);
    TEST_ASSERT_EQUAL_STRING("? Star", f.artist);
}

// Phase -1 is unknown (the deck stopped, or no offset since it loaded): no marker, never one parked in the middle.
void test_the_phase_marker_hides_while_unknown_and_stays_on_the_bar() {
    DeckView v = loaded_deck();
    Face f = deck_core::face(v);
    // The 10 px marker's left edge on the 704 px bar: 0-694 px, 347 in phase.
    TEST_ASSERT_EQUAL(347, f.phase_px);
    v.phase = 0.2f;
    TEST_ASSERT_EQUAL(139, deck_core::face(v).phase_px);  // 138.8
    v.phase = 1.3f;
    TEST_ASSERT_EQUAL(694, deck_core::face(v).phase_px);
    v.phase = -1;
    TEST_ASSERT_EQUAL(-1, deck_core::face(v).phase_px);
    v.phase = -0.5f;  // any value below 0 is unknown
    TEST_ASSERT_EQUAL(-1, deck_core::face(v).phase_px);
}

// #721, the jog display's phase rule (#462) at panel size. No phase (-1, or any value below 0: the deck stopped, or no
// offset since it loaded): the plain dark bar, no bar from the center and no tick, never anything that reads as locked.
void test_no_phase_is_the_plain_dark_bar() {
    DeckView v = loaded_deck();
    for (float phase : {-1.0f, -0.5f}) {
        v.phase = phase;
        const Face f = deck_core::face(v);
        TEST_ASSERT_EQUAL_HEX32(0x262626, f.phase_track_color);
        TEST_ASSERT_EQUAL(0, f.phase_bar_w);
        TEST_ASSERT_EQUAL(0, f.phase_tick);
    }
}

// #721: locked is exactly 0.5 (DeckBridge's DrawnPhase holds it there within #462's 0.002 of a beat): the whole bar in
// the deck color and the tick at its center, no bar from the center.
void test_locked_is_the_whole_bar_in_the_deck_color_with_the_tick() {
    const Face f = deck_core::face(loaded_deck());  // red, phase 0.5
    TEST_ASSERT_EQUAL_HEX32(0xFF0000, f.phase_track_color);
    TEST_ASSERT_EQUAL(1, f.phase_tick);
    TEST_ASSERT_EQUAL(0, f.phase_bar_w);
}

// The meter is 310 px tall, from the key row to the lamps' bottom.
void test_the_level_fill_is_whole_pixels_of_the_310_px_meter() {
    DeckView v = loaded_deck();
    TEST_ASSERT_EQUAL(233, deck_core::face(v).level_px);  // 232.5, half away from zero
    v.level = 2;
    TEST_ASSERT_EQUAL(310, deck_core::face(v).level_px);
    v.level = -1;
    TEST_ASSERT_EQUAL(0, deck_core::face(v).level_px);
}


// #682: a loaded track at its end shows -0:00 and the bar stays red, as the LC6000 does. At the end is remaining 0
// with progress above 0: DeckBridge sends progress 0 whenever it doesn't know the length, so this zero is a known
// length with nothing left, never "not told yet".
void test_a_loaded_track_at_its_end_shows_minus_0_00_and_a_red_bar() {
    DeckView v = loaded_deck();
    v.elapsed = 390;
    v.remaining = 0;
    v.progress = 1;
    Face f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("-0:00", f.remaining);
    TEST_ASSERT_EQUAL_HEX32(0xFF3B30, f.progress_color);
    // The last fraction of a second, still playing: already 0 in whole seconds, so the red never blinks off.
    v.elapsed = 389;
    v.progress = 0.999f;
    f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("-0:00", f.remaining);
    TEST_ASSERT_EQUAL_HEX32(0xFF3B30, f.progress_color);
}


// #682: just loaded, no times told yet (everything 0), and no track at all: no remaining time and no red bar.
void test_not_told_yet_or_no_track_is_no_end() {
    DeckView v = loaded_deck();
    v.elapsed = v.remaining = 0;
    v.progress = 0;
    Face f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("", f.remaining);
    TEST_ASSERT_EQUAL_HEX32(0xE0E0E0, f.progress_color);
    v.loaded = false;
    v.progress = 1;  // whatever else came, an empty deck is never at an end
    f = deck_core::face(v);
    TEST_ASSERT_EQUAL_STRING("", f.remaining);
    TEST_ASSERT_EQUAL_HEX32(0xE0E0E0, f.progress_color);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_an_empty_deck_shows_no_track_loaded_and_nothing_else);
    RUN_TEST(test_a_loaded_deck_shows_its_title_and_artist);
    RUN_TEST(test_bpm_and_tempo_show_at_1_decimal_tempo_signed);
    RUN_TEST(test_an_unknown_bpm_shows_neither_bpm_nor_tempo);
    RUN_TEST(test_times_show_as_minutes_and_seconds_remaining_with_a_minus);
    RUN_TEST(test_past_an_hour_times_show_hours);
    RUN_TEST(test_with_no_known_length_remaining_is_blank);
    RUN_TEST(test_the_progress_fill_is_whole_pixels_of_the_704_px_bar);
    RUN_TEST(test_the_bar_turns_red_in_the_last_30_seconds);
    RUN_TEST(test_a_loaded_track_at_its_end_shows_minus_0_00_and_a_red_bar);
    RUN_TEST(test_not_told_yet_or_no_track_is_no_end);
    RUN_TEST(test_the_beat_lights_its_block_in_the_deck_color);
    RUN_TEST(test_a_deck_without_a_color_shows_white);
    RUN_TEST(test_the_lamps_light_in_their_colors);
    RUN_TEST(test_the_loop_lamp_shows_whole_beats_or_fractions);
    RUN_TEST(test_texts_come_fitted_to_the_fonts);
    RUN_TEST(test_the_phase_marker_hides_while_unknown_and_stays_on_the_bar);
    RUN_TEST(test_no_phase_is_the_plain_dark_bar);
    RUN_TEST(test_locked_is_the_whole_bar_in_the_deck_color_with_the_tick);
    RUN_TEST(test_the_level_fill_is_whole_pixels_of_the_310_px_meter);
    return UNITY_END();
}
