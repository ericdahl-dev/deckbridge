// The drawing (#457), checked against design B as the Swift renderer draws it: test/ref/*.ppm, made by
// test/ref/make_refs.sh from JogDisplayRenderer, never from this code.
//
// Three bands are compared: the ring, the header, and the text below it (#458: the title or an untitled deck's words,
// the artist or caption, the rule in the deck color, key and BPM). Before a deck's text arrives, the text band is the
// rule alone.
#include "harness.h"
#include "draw.h"
#include "messages.h"
#include <string.h>
#include <math.h>

#define GROUND 0x0B0B0Bu
/// The header band (chip and badge, 24-50) with room for anti-aliasing; the title's glyphs start below 66.
#define HEADER_TOP 20
#define HEADER_BOTTOM 55
/// The ring band, 85-95 around (99, 99), with room for anti-aliasing; text stays inside 79.
#define RING_IN 83.5f
#define RING_OUT 96.5f

typedef struct {
    const char *file;
    uint8_t number, r, g, b, player;
} ref_case;

static const ref_case cases[] = {
    { "test/ref/deck2-red-track.ppm", 2, 255, 0, 0, 1 },
    { "test/ref/deck4-blue-empty.ppm", 4, 0, 128, 255, 0 },
    { "test/ref/deck1-white-midi.ppm", 1, 255, 255, 255, 3 },
    { "test/ref/deck3-green-other.ppm", 3, 0, 200, 80, 5 },
    { "test/ref/deck1-orange-osc.ppm", 1, 255, 128, 0, 2 },
    { "test/ref/deck3-purple-seq.ppm", 3, 180, 0, 255, 4 },
};
#define CASES (sizeof cases / sizeof cases[0])

static dfw_pixel reference[DFW_SIZE * DFW_SIZE];

/// Reads a binary PPM (P6, 198×198, maxval 255) into `reference`. A missing or short file fails, never skips.
static int load_reference(const char *file) {
    FILE *f = fopen(file, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", file); return 0; }
    int w = 0, h = 0, max = 0;
    int ok = fscanf(f, "P6 %d %d %d", &w, &h, &max) == 3 && w == DFW_SIZE && h == DFW_SIZE && max == 255
        && fgetc(f) == '\n';
    static uint8_t rgb[DFW_SIZE * DFW_SIZE * 3];
    ok = ok && fread(rgb, 1, sizeof rgb, f) == sizeof rgb;
    fclose(f);
    if (!ok) { fprintf(stderr, "%s is not a %dx%d P6 PPM\n", file, DFW_SIZE, DFW_SIZE); return 0; }
    for (size_t i = 0; i < DFW_SIZE * DFW_SIZE; i++)
        reference[i] = (dfw_pixel)rgb[i * 3] << 16 | (dfw_pixel)rgb[i * 3 + 1] << 8 | rgb[i * 3 + 2];
    return 1;
}

static int in_header(int y) { return y >= HEADER_TOP && y <= HEADER_BOTTOM; }

static int in_ring(int x, int y) {
    float dx = (float)x + 0.5f - 99.0f, dy = (float)y + 0.5f - 99.0f, d2 = dx * dx + dy * dy;
    return d2 >= RING_IN * RING_IN && d2 <= RING_OUT * RING_OUT;
}

static void every_reference_has_the_ring_and_header_to_compare(void) {
    for (size_t c = 0; c < CASES; c++) {
        CHECK(load_reference(cases[c].file));
        CHECK(reference[0] == GROUND);
        int ring = 0, header = 0;
        for (int y = 0; y < DFW_SIZE; y++)
            for (int x = 0; x < DFW_SIZE; x++) {
                if (reference[y * DFW_SIZE + x] == GROUND) continue;
                if (in_ring(x, y)) ring++;
                else if (in_header(y)) header++;
            }
        // Not vacuous: both bands hold drawing (the ring's band alone is thousands of pixels; the chip hundreds).
        CHECK(ring > 4000);
        CHECK(header > 300);
    }
}

/// Two limits per band: no pixel may be off by more than CAP in any channel, and at most BUDGET pixels may be off by
/// more than CLOSE.
///
/// Measured: the ring is within 3 levels everywhere, so it gets 6 and no budget. In the header, CoreGraphics' fill
/// anti-aliasing is not exact pixel area: near 45° on the chip's curve it covers up to about 7% less, which is up to 18
/// levels for a white chip on the ground (244 apart). That touches 8 to 16 pixels per case, all on the chip's edge; the
/// rest of the header, glyphs and badge included, is within 8. So 8 with a budget of 24, and nothing past 24 (9% of
/// full scale) anywhere. A color off by 17 or more (a ring section, the badge ink or outline, the deck color) fails the
/// close limit across hundreds of pixels; a shape off by a pixel or a glyph off by half fails the cap.
#define RING_CLOSE 6
#define RING_BUDGET 0
#define HEADER_CLOSE 8
#define HEADER_BUDGET 24
#define CAP 24

static dfw_pixel frame[DFW_SIZE * DFW_SIZE];

static int channel_diff(dfw_pixel a, dfw_pixel b) {
    int worst = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        int d = (int)(a >> shift & 0xFF) - (int)(b >> shift & 0xFF);
        if (d < 0) d = -d;
        if (d > worst) worst = d;
    }
    return worst;
}

typedef enum { RING, HEADER } band;

/// Compares one band with the reference: whether it is within its limits. Prints its numbers so they stay honest.
static int band_matches(const ref_case *c, band which) {
    int close = which == RING ? RING_CLOSE : HEADER_CLOSE, budget = which == RING ? RING_BUDGET : HEADER_BUDGET;
    int loose = 0, over_cap = 0, worst = 0, pixels = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            int ring = in_ring(x, y);
            if (which == RING ? !ring : (ring || !in_header(y))) continue;
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            pixels++;
            if (d > worst) worst = d;
            if (d > close) loose++;
            if (d > CAP) over_cap++;
        }
    fprintf(stderr, "    %s %s: %d px, worst %d, %d over %d (budget %d)\n", c->file + 9, which == RING ? "ring" : "header",
            pixels, worst, loose, close, budget);
    return over_cap == 0 && loose <= budget;
}

/// The unit the reference cases drive through messages (#573), as the host does.
static dfw_unit ref_unit;
static recording ref_rec;

/// Begin and the case's deck, one tick, and the frame the unit presented.
static void draw_case(const ref_case *c) {
    fresh(&ref_unit, &ref_rec);
    send_begin(&ref_unit);
    send_deck(&ref_unit, c->number, c->r, c->g, c->b, c->player);
    dfw_tick(&ref_unit, 0);
    memcpy(frame, ref_rec.last, sizeof frame);
}

/// The rule in the deck color, under the artist: x 50-147, y 127-128, as the renderer fills it.
static int in_rule(int x, int y) { return x >= 50 && x < 148 && y >= 127 && y < 129; }

static void before_the_text_arrives_the_text_band_is_the_rule_alone(void) {
    for (size_t c = 0; c < CASES; c++) {
        draw_case(&cases[c]);
        int stray = 0, rule = 0;
        dfw_pixel deck = (dfw_pixel)cases[c].r << 16 | (dfw_pixel)cases[c].g << 8 | cases[c].b;
        for (int y = 0; y < DFW_SIZE; y++)
            for (int x = 0; x < DFW_SIZE; x++) {
                if (in_ring(x, y) || in_header(y)) continue;
                dfw_pixel p = frame[y * DFW_SIZE + x];
                if (in_rule(x, y)) rule += p == deck;
                else stray += p != GROUND;
            }
        CHECK(stray == 0);
        CHECK(rule == 98 * 2);
    }
}

/// The text references (#458), with the messages the host sends for them: Windows-1252 texts, the untitled words in
/// field 3, the tempo in tenths.
typedef struct {
    const char *file;
    uint8_t number, r, g, b, player;
    const char *title, *artist, *key, *words;
    uint16_t tenths;
} text_case;

static const text_case text_cases[] = {
    { "test/ref/text-strobe.ppm", 2, 255, 0, 0, 1, "Strobe", "Deadmau5", "F#m", "", 1280 },
    { "test/ref/text-night-drive.ppm", 2, 255, 0, 0, 1, "Night Drive", "Caf\xE9 del Mar", "11B", "", 900 },
    { "test/ref/text-ten.ppm", 1, 255, 255, 255, 1, "Ten (Original Club Mix)", "Mark Knight", "8A", "", 1245 },
    { "test/ref/text-cut.ppm", 3, 0, 200, 80, 1, "Mark Knight Underworld Sander Van Doorn Remix Edition",
      "Wolfgang Amadeus Mozart and the Vienna Philharmonic", "", "", 0 },
    { "test/ref/text-accents.ppm", 4, 0, 128, 255, 1, "T\xE4nzer aus T\xFC" "bingen", "L\xE9" "a Seydoux & \x93" "Don\x92t\x94",
      "Ebm", "", 1740 },
    { "test/ref/text-automation.ppm", 3, 0, 200, 80, 5, "", "", "", "Automation", 0 },
    { "test/ref/deck2-red-track.ppm", 2, 255, 0, 0, 1, "", "", "", "No track", 0 },
    { "test/ref/deck4-blue-empty.ppm", 4, 0, 128, 255, 0, "", "", "", "No track", 0 },
    { "test/ref/deck1-white-midi.ppm", 1, 255, 255, 255, 3, "", "", "", "Midiclip", 0 },
    { "test/ref/deck1-orange-osc.ppm", 1, 255, 128, 0, 2, "", "", "", "OSC clip", 0 },
    { "test/ref/deck3-purple-seq.ppm", 3, 180, 0, 255, 4, "", "", "", "Sequencer", 0 },
};

/// One text field, its Windows-1252 codes as the host sends them.
static void send_codes(dfw_unit *unit, int field, const char *codes) {
    send_text(unit, (uint8_t)field, (const uint8_t *)codes, strlen(codes));
}

/// The case's deck, its four texts and its tempo, as the full state sends them; then the frame.
static void draw_text_case(const text_case *c) {
    fresh(&ref_unit, &ref_rec);
    send_begin(&ref_unit);
    send_deck(&ref_unit, c->number, c->r, c->g, c->b, c->player);
    send_codes(&ref_unit, 0, c->title);
    send_codes(&ref_unit, 1, c->artist);
    send_codes(&ref_unit, 2, c->key);
    send_codes(&ref_unit, 3, c->words);
    send_tempo(&ref_unit, (uint16_t)c->tenths);
    dfw_tick(&ref_unit, 0);
    memcpy(frame, ref_rec.last, sizeof frame);
}

/// The text band: below the header, inside the ring. The renderer's text is CoreText's, anti-aliased at half-pixel x
/// positions; ours is 4-bit coverage at whole ones. So most pixels are close, glyph edges a little further.
#define TEXT_CLOSE 8
#define TEXT_BUDGET 200
#define TEXT_CAP 56

static int text_band_matches(const char *file) {
    int loose = 0, over_cap = 0, worst = 0, pixels = 0;
    for (int y = HEADER_BOTTOM + 1; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            if (in_ring(x, y)) continue;
            float dx = (float)x + 0.5f - 99.0f, dy = (float)y + 0.5f - 99.0f;
            if (dx * dx + dy * dy > RING_IN * RING_IN) continue;
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            pixels++;
            if (d > worst) worst = d;
            if (d > TEXT_CLOSE) loose++;
            if (d > TEXT_CAP) over_cap++;
        }
    fprintf(stderr, "    %s text: %d px, worst %d, %d over %d (budget %d), %d over %d\n", file + 9, pixels, worst, loose,
            TEXT_CLOSE, TEXT_BUDGET, over_cap, TEXT_CAP);
    return over_cap == 0 && loose <= TEXT_BUDGET;
}

/// A letter the font lacks (#458): the host sends 0x81, and the chip draws Geist's own .notdef, a box. The renderer
/// would draw another font's glyph there, so there's no reference: this checks that the box has ink where a space has
/// none, and that it's a box (its ink's top and bottom rows are wider than a stroke).
static void a_letter_the_font_lacks_draws_a_box(void) {
    static const text_case boxed = { "", 2, 255, 0, 0, 1, "\x81", "x", "", "", 0 };
    static const text_case spaced = { "", 2, 255, 0, 0, 1, " ", "x", "", "", 0 };
    static dfw_pixel with_box[DFW_SIZE * DFW_SIZE];
    draw_text_case(&boxed);
    memcpy(with_box, frame, sizeof frame);
    draw_text_case(&spaced);
    int left = DFW_SIZE, right = -1, top = DFW_SIZE, bottom = -1;
    for (int y = 56; y < 94; y++)
        for (int x = 0; x < DFW_SIZE; x++)
            if (with_box[y * DFW_SIZE + x] != frame[y * DFW_SIZE + x] && with_box[y * DFW_SIZE + x] != GROUND) {
                if (x < left) left = x;
                if (x > right) right = x;
                if (y < top) top = y;
                if (y > bottom) bottom = y;
            }
    CHECK(right > left && bottom > top);
    if (right <= left || bottom <= top) return;
    // A box: its top and bottom rows are inked most of its width.
    int top_ink = 0, bottom_ink = 0;
    for (int x = left; x <= right; x++) {
        top_ink += with_box[top * DFW_SIZE + x] != GROUND;
        bottom_ink += with_box[bottom * DFW_SIZE + x] != GROUND;
    }
    CHECK(right - left >= 6 && bottom - top >= 10);
    CHECK(top_ink * 2 > right - left && bottom_ink * 2 > right - left);
}

static void the_text_matches_the_reference(void) {
    for (size_t c = 0; c < sizeof text_cases / sizeof text_cases[0]; c++) {
        CHECK(load_reference(text_cases[c].file));
        draw_text_case(&text_cases[c]);
        CHECK(text_band_matches(text_cases[c].file));
    }
}

static void the_ring_matches_the_reference(void) {
    for (size_t c = 0; c < CASES; c++) {
        CHECK(load_reference(cases[c].file));
        draw_case(&cases[c]);
        CHECK(band_matches(&cases[c], RING));
    }
}

static void the_header_matches_the_reference(uint8_t player) {
    for (size_t c = 0; c < CASES; c++) {
        if (cases[c].player != player) continue;
        CHECK(load_reference(cases[c].file));
        draw_case(&cases[c]);
        CHECK(band_matches(&cases[c], HEADER));
    }
}

static void an_empty_deck_draws_its_chip_alone(void) { the_header_matches_the_reference(0); }
static void another_player_draws_its_chip_alone(void) { the_header_matches_the_reference(5); }

static void a_track_draws_the_trk_badge(void) { the_header_matches_the_reference(1); }
static void an_osc_clip_draws_the_osc_badge(void) { the_header_matches_the_reference(2); }
static void a_midi_clip_draws_the_midi_badge(void) { the_header_matches_the_reference(3); }
static void a_sequencer_draws_the_seq_badge(void) { the_header_matches_the_reference(4); }

/// Every deck number and every player the protocol takes, drawn into a frame filled with garbage: no pixel is left.
/// (Decks and players out of range never reach drawing: the decoder drops them, as the invalid vectors check.)
static void every_pixel_is_written_whatever_the_deck(void) {
    static dfw_pixel garbage[DFW_SIZE * DFW_SIZE];
    for (uint8_t number = 1; number <= DFW_DECK_MAX; number++) {
        for (uint8_t player = 0; player <= DFW_PLAYER_MAX; player++) {
            for (size_t i = 0; i < DFW_SIZE * DFW_SIZE; i++) garbage[i] = 0xDEADBEEFu;
            fresh_without_frame(&ref_unit, &ref_rec);
            dfw_set_frame(&ref_unit, garbage);
            send_begin(&ref_unit);
            send_deck(&ref_unit, number, (uint8_t)(number * 60), 9, 255, player);
            dfw_tick(&ref_unit, 0);
            int unwritten = 0;
            for (size_t i = 0; i < DFW_SIZE * DFW_SIZE; i++) unwritten += (garbage[i] & 0xFF000000u) != 0;
            CHECK(ref_rec.presents == 1 && unwritten == 0);
        }
    }
}

/// The whole path (#457): begin then a deck message, and the tick presents design B for that deck.
static dfw_unit unit;
static recording rec;

static void begin_then_deck_presents_the_reference(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");   // deck 2, red, track
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1);
    const ref_case *c = &cases[0];
    CHECK(load_reference(c->file));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(band_matches(c, RING));
    CHECK(band_matches(c, HEADER));
}

/// The waiting look (#464), compared over the whole frame: our logo is all of it. The limits are the header's: the
/// logo is curves and a turned capsule, anti-aliased like the chip.
#define STALE_REF "test/ref/stale.ppm"
#define STALE_BUDGET 64

static int stale_matches(void) {
    int loose = 0, over_cap = 0, worst = 0;
    for (int i = 0; i < DFW_SIZE * DFW_SIZE; i++) {
        int d = channel_diff(frame[i], reference[i]);
        if (d > worst) worst = d;
        if (d > HEADER_CLOSE) loose++;
        if (d > CAP) over_cap++;
    }
    fprintf(stderr, "    stale: worst %d, %d over %d (budget %d), %d over %d\n", worst, loose, HEADER_CLOSE, STALE_BUDGET,
            over_cap, CAP);
    return over_cap == 0 && loose <= STALE_BUDGET;
}

static void stale_draws_the_logo(void) {
    fresh(&ref_unit, &ref_rec);
    send_begin(&ref_unit);
    send_deck(&ref_unit, 2, 255, 0, 0, 1);
    send_state(&ref_unit, 0x21);   // loaded, feedback stale
    dfw_tick(&ref_unit, 0);
    memcpy(frame, ref_rec.last, sizeof frame);
    CHECK(load_reference(STALE_REF));
    CHECK(stale_matches());
}

static void three_silent_seconds_present_the_logo(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");
    dfw_tick(&unit, 0);
    dfw_tick(&unit, 3000);
    CHECK(rec.presents == 2);
    CHECK(load_reference(STALE_REF));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(stale_matches());
}

/// The quit look (#600): the app leaves our logo, the last deck's number on a neutral hub (the icon's own, D5D5D5),
/// by sending that deck again with the neutral color, then the state with stale, and no end. The reference is the
/// Swift renderer's (test/ref/quit-deck2.ppm), compared over the whole frame as the waiting look.
#define QUIT_REF "test/ref/quit-deck2.ppm"

static void the_quit_bytes_leave_the_logo_on_a_neutral_hub(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");                         // begin
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");    // deck 2, red, track
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 03 F7");                         // loaded, playing
    dfw_tick(&unit, 0);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 55 01 55 01 55 01 F7");    // deck 2, D5D5D5, track
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 23 F7");                         // loaded, playing, stale
    dfw_tick(&unit, 40);
    CHECK(rec.presents == 2);
    CHECK(load_reference(QUIT_REF));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(stale_matches());
}

/// Which pixels of the hub's middle (the number's box) are the number's ink: near the ground, not the hub's color.
static void number_ink(const dfw_pixel *drawn, uint8_t *ink) {
    for (int y = 0; y < 24; y++)
        for (int x = 0; x < 24; x++) ink[y * 24 + x] = channel_diff(drawn[(87 + y) * DFW_SIZE + 87 + x], 0x0B0B0Bu) < 40;
}

/// The stale look shows the deck in the logo's hub (#524): a deck message while stale (it keeps the stale flag)
/// presents the hub in the new deck's color with the new number. Hub at (111, 99): 12 px out, past the number,
/// inside the hub's 17.8.
static void a_new_deck_while_stale_shows_in_the_hub(void) {
    static uint8_t before[24 * 24], after[24 * 24];
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");   // deck 2, red, track
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 21 F7");                         // loaded, feedback stale
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1 && dfw_stale(&unit));
    CHECK(rec.last[99 * DFW_SIZE + 111] == 0xFF0000u);
    number_ink(rec.last, before);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 03 00 00 01 48 00 50 00 F7");   // deck 3, 0/200/80
    dfw_tick(&unit, 100);
    CHECK(rec.presents == 2 && dfw_stale(&unit));
    CHECK(rec.last[99 * DFW_SIZE + 111] == 0x00C850u);
    number_ink(rec.last, after);
    int ink = 0, moved = 0;
    for (int i = 0; i < 24 * 24; i++) {
        ink += after[i];
        moved += after[i] != before[i];
    }
    CHECK(ink > 20 && moved > 10);
}

/// On a dark deck color the number is white (#542 follow-up, DeckNumberInk): navy (0, 0, 128) in the stale hub shows its
/// number's ink in the text white, and none in the ground's black.
static void a_dark_decks_hub_number_is_white(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 01 00 00 00 00 01 00 00 F7");   // deck 1, 0/0/128, empty
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 21 F7");                         // loaded, feedback stale
    dfw_tick(&unit, 0);
    CHECK(rec.presents == 1 && rec.last[99 * DFW_SIZE + 111] == 0x000080u);
    int white = 0, black = 0;
    for (int y = 87; y < 111; y++)
        for (int x = 87; x < 111; x++) {
            white += channel_diff(rec.last[y * DFW_SIZE + x], 0xEDEDEAu) < 40;
            black += channel_diff(rec.last[y * DFW_SIZE + x], 0x0B0B0Bu) < 40;
        }
    CHECK(white > 20 && black == 0);
}

/// The linearization table is the WCAG formula, to float precision.
static void the_linear_channel_table_is_wcags(void) {
    int off = 0;
    for (int c = 0; c < 256; c++) {
        double x = c / 255.0, want = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
        off += fabs((double)dfw_linear_channel[c] - want) > 1e-7;
    }
    CHECK(off == 0);
}

/// The state's feedback-stale bit (#464): set, the presented frame is the logo; cleared, it's the deck again.
static void the_stale_flag_draws_the_logo_and_fresh_feedback_clears_it(void) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 01 F7");   // deck 2, red, track
    dfw_tick(&unit, 0);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 21 F7");                         // loaded, feedback stale
    dfw_tick(&unit, 100);
    CHECK(rec.presents == 2);
    CHECK(load_reference(STALE_REF));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(stale_matches());
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 07 01 F7");                         // loaded, fresh
    dfw_tick(&unit, 200);
    CHECK(rec.presents == 3);
    CHECK(load_reference(cases[0].file));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(band_matches(&cases[0], RING));
    CHECK(band_matches(&cases[0], HEADER));
}

const test_case draw_tests[] = {
    { "before the text arrives the text band is the rule alone", before_the_text_arrives_the_text_band_is_the_rule_alone },
    { "the text matches the reference", the_text_matches_the_reference },
    { "a letter the font lacks draws a box", a_letter_the_font_lacks_draws_a_box },
    { "the ring matches the reference", the_ring_matches_the_reference },
    { "an empty deck draws its chip alone", an_empty_deck_draws_its_chip_alone },
    { "another player draws its chip alone", another_player_draws_its_chip_alone },
    { "a track draws the TRK badge", a_track_draws_the_trk_badge },
    { "an OSC clip draws the OSC badge", an_osc_clip_draws_the_osc_badge },
    { "a MIDI clip draws the MIDI badge", a_midi_clip_draws_the_midi_badge },
    { "a sequencer draws the SEQ badge", a_sequencer_draws_the_seq_badge },
    { "every pixel is written whatever the deck", every_pixel_is_written_whatever_the_deck },
    { "every reference has the ring and header to compare", every_reference_has_the_ring_and_header_to_compare },
    { "begin then deck presents the reference", begin_then_deck_presents_the_reference },
    { "stale draws the logo", stale_draws_the_logo },
    { "a new deck while stale shows in the hub", a_new_deck_while_stale_shows_in_the_hub },
    { "a dark deck's hub number is white", a_dark_decks_hub_number_is_white },
    { "the linear channel table is WCAG's", the_linear_channel_table_is_wcags },
    { "three silent seconds present the logo", three_silent_seconds_present_the_logo },
    { "the quit bytes leave the logo on a neutral hub", the_quit_bytes_leave_the_logo_on_a_neutral_hub },
    { "the stale flag draws the logo and fresh feedback clears it",
      the_stale_flag_draws_the_logo_and_fresh_feedback_clears_it },
    { 0, 0 },
};
