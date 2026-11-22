// The live elements (#459): the lit master beat and the marker, checked against JogDisplayRenderer's simulator image:
// test/ref/*-beat*.ppm and *-needle*.ppm, made by test/ref/make_refs.sh from test/ref/manifest.json, never from this
// code. Every case is deck 4, blue, empty: its header is the chip alone, and nothing else is drawn near the ring.
#include "harness.h"
#include "draw.h"
#include "messages.h"
#include <string.h>

#define UNLIT "test/ref/deck4-blue-empty.ppm"
/// The ring band, 85-95 around (99, 99), with room for anti-aliasing, as test_draw.c compares it.
#define RING_IN 83.5f
#define RING_OUT 96.5f
/// As test_draw.c: the unlit ring within 6 levels everywhere.
#define RING_CLOSE 6
/// The lit section is the live green on the ground, 244 levels apart in green, three times the unlit sections' 79. The
/// renderers' anti-aliasing differs by the same fraction of that (about 4%), so a few of its edge pixels are up to 8
/// off. Measured: worst 8, with 6 or 7 pixels over 6 per beat. So 6 with a budget of 10, and nothing past 10: a green
/// off by 7 or more fails across the section, and a 1 px shift (hundreds of levels) fails the cap.
#define LIT_CLOSE 6
#define LIT_BUDGET 10
#define LIT_CAP 10

static dfw_pixel reference[DFW_SIZE * DFW_SIZE];
static dfw_pixel frame[DFW_SIZE * DFW_SIZE];

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

static float radius2(int x, int y) {
    float dx = (float)x + 0.5f - 99.0f, dy = (float)y + 0.5f - 99.0f;
    return dx * dx + dy * dy;
}

static int in_ring(int x, int y) {
    float d2 = radius2(x, y);
    return d2 >= RING_IN * RING_IN && d2 <= RING_OUT * RING_OUT;
}

static int channel_diff(dfw_pixel a, dfw_pixel b) {
    int worst = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        int d = (int)(a >> shift & 0xFF) - (int)(b >> shift & 0xFF);
        if (d < 0) d = -d;
        if (d > worst) worst = d;
    }
    return worst;
}

/// The ring band of `frame` against `reference`: at most `budget` pixels more than `close` off, and none more than
/// `cap`. Prints its numbers.
static int ring_matches(const char *name, int close, int budget, int cap) {
    int worst = 0, loose = 0, over = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            if (!in_ring(x, y)) continue;
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            if (d > worst) worst = d;
            if (d > close) loose++;
            if (d > cap) over++;
        }
    fprintf(stderr, "    %s ring: worst %d, %d over %d (budget %d)\n", name, worst, loose, close, budget);
    return over == 0 && loose <= budget;
}

/// The unit these tests drive through messages, as the host does (#573), and its clock.
static dfw_unit unit;
static recording drawn;
static uint32_t clock_ms;

/// Begin, then deck 4, blue, empty: what every case here draws.
static void start_deck4(void) {
    fresh(&unit, &drawn);
    clock_ms = 0;
    send_begin(&unit);
    send_deck(&unit, 4, 0, 128, 255, 0);
}

/// The next tick at `at` ms, and the frame the unit shows after it.
static void show_at(uint32_t at) {
    clock_ms = at;
    dfw_tick(&unit, clock_ms);
    memcpy(frame, drawn.last, sizeof frame);
}

static void show(void) { show_at(clock_ms); }

/// This master beat, then the frame.
static void draw_beat(uint8_t beat) {
    send_beat(&unit, beat);
    show();
}

static void each_beat_lights_its_section(void) {
    static const char *const files[] = { 0, "test/ref/deck4-blue-empty-beat1.ppm", "test/ref/deck4-blue-empty-beat2.ppm",
                                         "test/ref/deck4-blue-empty-beat3.ppm", "test/ref/deck4-blue-empty-beat4.ppm" };
    start_deck4();
    for (uint8_t beat = 1; beat <= 4; beat++) {
        CHECK(load_reference(files[beat]));
        draw_beat(beat);
        CHECK(ring_matches(files[beat] + 9, LIT_CLOSE, LIT_BUDGET, LIT_CAP));
    }
}

/// Not vacuous: each lit reference differs from the unlit one, in its own section only.
static void each_lit_reference_differs_from_the_unlit_one(void) {
    static dfw_pixel unlit[DFW_SIZE * DFW_SIZE];
    CHECK(load_reference(UNLIT));
    memcpy(unlit, reference, sizeof unlit);
    static const char *const files[] = { "test/ref/deck4-blue-empty-beat1.ppm", "test/ref/deck4-blue-empty-beat2.ppm",
                                         "test/ref/deck4-blue-empty-beat3.ppm", "test/ref/deck4-blue-empty-beat4.ppm" };
    for (int b = 0; b < 4; b++) {
        CHECK(load_reference(files[b]));
        int changed = 0;
        for (int i = 0; i < DFW_SIZE * DFW_SIZE; i++) changed += reference[i] != unlit[i];
        CHECK(changed > 1000);
    }
}

static void no_master_clock_lights_no_section(void) {
    start_deck4();
    CHECK(load_reference(UNLIT));
    draw_beat(0);
    CHECK(ring_matches("deck4-blue-empty.ppm (beat 0)", RING_CLOSE, 0, RING_CLOSE));
}

/// The waiting look is agent3's; whatever it is, the beat changes none of it.
static void stale_lights_no_section(void) {
    static dfw_pixel without[DFW_SIZE * DFW_SIZE];
    start_deck4();
    send_state(&unit, 0x20);   // Syndicate's feedback stopped
    draw_beat(0);
    memcpy(without, frame, sizeof without);
    for (uint8_t beat = 1; beat <= 4; beat++) {
        draw_beat(beat);
        CHECK(memcmp(frame, without, sizeof frame) == 0);
    }
    // 3 s with no message: the same waiting look with no beat and with beat 3 (any message ends the silence, so the
    // beat comes first).
    start_deck4();
    show_at(0);
    show_at(3000);
    CHECK(dfw_stale(&unit));
    memcpy(without, frame, sizeof without);
    start_deck4();
    send_beat(&unit, 3);
    show_at(0);
    show_at(3000);
    CHECK(memcmp(frame, without, sizeof frame) == 0);
}

/// The marker reaches in to radius 78 (its tip at 79, less its keyline) and out past the frame's edge. The chip, the
/// only other thing drawn for this deck, stays inside 76. So everything from 77 out is compared.
#define MARKER_IN 77.0f
/// Measured: with the fill's exact area in each edge pixel, the marker is within 3 levels everywhere, at the five
/// references and at 19 more angles swept round the turn. So 6 and no budget, as the unlit ring. Turning the marker
/// half a degree puts dozens of pixels hundreds of levels off.
#define MARKER_CLOSE 6
#define MARKER_BUDGET 0
#define MARKER_CAP 6

/// Everything from MARKER_IN out against `reference`, within limits as test_draw.c's: at most `budget` pixels more than
/// `close` off, and none more than `cap`. Prints its numbers.
static int band_from_matches(const char *name, int close, int budget, int cap) {
    int worst = 0, loose = 0, over = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            if (radius2(x, y) < MARKER_IN * MARKER_IN) continue;
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            if (d > worst) worst = d;
            if (d > close) loose++;
            if (d > cap) over++;
        }
    fprintf(stderr, "    %s from %.0f out: worst %d, %d over %d (budget %d)\n", name, (double)MARKER_IN, worst, loose,
            close, budget);
    return over == 0 && loose <= budget;
}

static int marker_band_matches(const char *name) {
    return band_from_matches(name, MARKER_CLOSE, MARKER_BUDGET, MARKER_CAP);
}

typedef struct { const char *file; uint16_t needle; } needle_case;
static const needle_case needles[] = {
    { "test/ref/deck4-blue-empty-needle0.ppm", 0 },
    { "test/ref/deck4-blue-empty-needle4096.ppm", 4096 },
    { "test/ref/deck4-blue-empty-needle8192.ppm", 8192 },
    { "test/ref/deck4-blue-empty-needle12288.ppm", 12288 },
    // Off the quarter turns, so the angle's sine and cosine are really computed.
    { "test/ref/deck4-blue-empty-needle1500.ppm", 1500 },
};
#define NEEDLES (sizeof needles / sizeof needles[0])

static dfw_unit live;
static recording rec;

/// Begin, deck 4 blue empty, then a needle message at `angle`, then a tick.
static void begin_with_needle(uint16_t angle) {
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");   // deck 4, 0/128/255, empty
    char needle[64];
    snprintf(needle, sizeof needle, "F0 00 02 0B 7F 10 20 00 03 09 %02X %02X F7", angle >> 7, angle & 0x7F);
    feed(&live, needle);
    dfw_tick(&live, 0);
}

static void the_needle_is_drawn_as_the_marker(void) {
    for (size_t n = 0; n < NEEDLES; n++) {
        CHECK(load_reference(needles[n].file));
        begin_with_needle(needles[n].needle);
        CHECK(rec.presents == 1);
        memcpy(frame, rec.last, sizeof frame);
        CHECK(marker_band_matches(needles[n].file + 9));
    }
}

/// The marker drawn over the lit section it sits in: beat 3, needle 11000 (folded back from the last quarter turn).
static void the_marker_is_drawn_over_the_lit_section(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-beat3-needle11000.ppm"));
    begin_with_needle(11000);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 08 03 F7");   // beat 3
    dfw_tick(&live, 10);
    CHECK(rec.presents == 2);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(band_from_matches("deck4-blue-empty-beat3-needle11000.ppm", LIT_CLOSE, LIT_BUDGET, LIT_CAP));
}

/// Not vacuous: each marker reference differs from the unlit one from MARKER_IN out.
static void each_marker_reference_differs_from_the_unlit_one(void) {
    static dfw_pixel unlit[DFW_SIZE * DFW_SIZE];
    CHECK(load_reference(UNLIT));
    memcpy(unlit, reference, sizeof unlit);
    for (size_t n = 0; n < NEEDLES; n++) {
        CHECK(load_reference(needles[n].file));
        int changed = 0;
        for (int y = 0; y < DFW_SIZE; y++)
            for (int x = 0; x < DFW_SIZE; x++)
                changed += radius2(x, y) >= MARKER_IN * MARKER_IN && reference[y * DFW_SIZE + x] != unlit[y * DFW_SIZE + x];
        CHECK(changed > 150);
    }
}

/// Until a needle message comes there is no marker: the host's full state carries one, and nothing is made up.
static void no_needle_message_draws_no_marker(void) {
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");
    dfw_tick(&live, 0);
    CHECK(load_reference(UNLIT));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(marker_band_matches("deck4-blue-empty.ppm (no needle)"));
}

static void a_needle_message_changes_the_frame(void) {
    static dfw_pixel before[DFW_SIZE * DFW_SIZE];
    begin_with_needle(0);
    memcpy(before, rec.last, sizeof before);
    feed(&live, "F0 00 02 0B 7F 10 20 00 03 09 08 00 F7");   // 1024, an eighth of a turn
    dfw_tick(&live, 10);
    CHECK(rec.presents == 2);
    CHECK(memcmp(rec.last, before, sizeof before) != 0);
}

/// The first needle message draws the marker even at 0, the angle a fresh unit holds.
static void the_first_needle_at_12_oclock_presents(void) {
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");
    dfw_tick(&live, 0);
    CHECK(rec.presents == 1);
    feed(&live, "F0 00 02 0B 7F 10 20 00 03 09 00 00 F7");
    dfw_tick(&live, 10);
    CHECK(rec.presents == 2);
}

static void the_same_angle_does_not_present_again(void) {
    begin_with_needle(4096);
    CHECK(rec.presents == 1);
    feed(&live, "F0 00 02 0B 7F 10 20 00 03 09 20 00 F7");   // 4096 again
    dfw_tick(&live, 10);
    CHECK(rec.presents == 1);
}

/// End forgets the needle: after a new begin there is no marker until a needle message comes.
static void end_forgets_the_needle(void) {
    begin_with_needle(4096);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 02 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");
    dfw_tick(&live, 10);
    CHECK(load_reference(UNLIT));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(marker_band_matches("deck4-blue-empty.ppm (after end)"));
}

/// The waiting look is agent3's; whatever it is, the needle changes none of it.
static void stale_draws_no_marker(void) {
    static dfw_pixel without[DFW_SIZE * DFW_SIZE];
    start_deck4();
    send_state(&unit, 0x20);   // Syndicate's feedback stopped
    draw_beat(0);
    memcpy(without, frame, sizeof without);
    send_needle(&unit, 4096);
    show();
    CHECK(memcmp(frame, without, sizeof frame) == 0);
}

/// Play state shows only through the needle, as the unit's own does: it moves while playing and holds while paused.
/// Nothing is drawn for it: every combination of loaded, playing and play pending is the same frame.
static void the_play_flags_change_no_pixels(void) {
    static dfw_pixel first[DFW_SIZE * DFW_SIZE];
    begin_with_needle(1500);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 08 02 F7");   // beat 2
    for (uint8_t flags = 0; flags <= 7; flags++) {
        char state[64];
        snprintf(state, sizeof state, "F0 00 02 0B 7F 10 20 00 02 07 %02X F7", flags);
        feed(&live, state);
        dfw_tick(&live, 10u + flags);
        CHECK(rec.presents == 2 + flags);
        if (flags == 0) memcpy(first, rec.last, sizeof first);
        else CHECK(memcmp(rec.last, first, sizeof first) == 0);
    }
}

/// The level meter (#461): an arc 80-83 inside the ring on the left, Swift's drawMeter. Compared, as the marker is,
/// from MARKER_IN out: the meter, the ring and nothing else of this deck's. Its edges against the dark track are within
/// 3. Against the bright fill, the band's two circles land about 0.03 px further in in CoreGraphics than their exact
/// areas put them, as the lit section's do, and the band is all edge: measured, worst 13 with 46 pixels over 6, all on
/// the circles, none on the radial edges or the tick; at clip, the whole arc bright, 89. So 6 with a budget a little
/// over each case's count, and nothing past 16 in any: a quarter pixel off is 60 levels on every edge pixel of the fill.
#define METER_CLOSE 6
#define METER_CAP 16
/// The progress ring (#460, #524), now r 103-107 in the band outside the frame (test_draw_band.c); in the frame only
/// its four corners show, where the band crosses the 198 square. All edge as the meter is, and its circles land the
/// same way. Measured in the frame: the track alone within 3; the fill at 83/165 worst 10, 23 pixels over 6, and at
/// 120/165 in red 28, all on the circles. So 6 with a budget a little over the count, nothing past 16.
#define PROGRESS_CLOSE 6
#define PROGRESS_CAP 16
#define PROGRESS_BUDGET_START 0
#define PROGRESS_BUDGET_FILL 30
/// The time left (#460, #524), GeistMono-SemiBold 21 from CoreText's own glyphs at their own baseline and x phases, as the
/// header's badge. Measured: within 1 everywhere, so 2 and no budget; a 1 px shift or a wrong glyph is hundreds off.
#define TIME_CLOSE 2
#define TIME_BUDGET 0
#define TIME_CAP 2
/// The fill at 135/165 (294.5°) has more circle under it: measured in the frame worst 10, with 40 pixels over 6 in red
/// and 36 in white, all on the circles again. So 45.
#define PROGRESS_BUDGET_LONG 45
/// The warning's red text has its own glyphs (light text is drawn heavier): measured within 1 as the white's, so the same
/// limits. With the white's glyphs drawn red it was 47 off.
#define TIME_RED_CLOSE TIME_CLOSE
#define TIME_RED_BUDGET TIME_BUDGET
#define TIME_RED_CAP TIME_CAP

typedef struct { const char *file; uint8_t level, peak; int budget; } meter_case;
static const meter_case meters[] = {
    { "test/ref/deck4-blue-empty-meter0-0.ppm", 0, 0, 0 },
    { "test/ref/deck4-blue-empty-meter64-90.ppm", 64, 90, 50 },
    // High: green, then yellow above 0.75, the white tick over the yellow.
    { "test/ref/deck4-blue-empty-meter110-120.ppm", 110, 120, 30 },
    // Clip: the whole arc red, and the tick red at the top.
    { "test/ref/deck4-blue-empty-meter127-127.ppm", 127, 127, 95 },
};
#define METERS (sizeof meters / sizeof meters[0])

/// Begin, deck 4 blue empty, then a meter message, then a tick.
static void begin_with_meter(uint8_t level, uint8_t peak) {
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");
    char meter[64];
    snprintf(meter, sizeof meter, "F0 00 02 0B 7F 10 20 00 03 0A %02X %02X F7", level, peak);
    feed(&live, meter);
    dfw_tick(&live, 0);
}

static void the_meter_is_drawn(void) {
    for (size_t n = 0; n < METERS; n++) {
        CHECK(load_reference(meters[n].file));
        begin_with_meter(meters[n].level, meters[n].peak);
        CHECK(rec.presents == 1);
        memcpy(frame, rec.last, sizeof frame);
        CHECK(band_from_matches(meters[n].file + 9, METER_CLOSE, meters[n].budget, METER_CAP));
    }
}

/// No reference has a fill past the yellow; the spec's colors are exact where the band covers a pixel whole. Level 110
/// (0.87 of the arc), no peak: mid-band pixels at fractions 0.40 (green), 0.80 (yellow) and 0.96 (the track).
static void the_fill_turns_yellow_past_three_quarters(void) {
    start_deck4();
    send_meter(&unit, 110, 0);
    show();
    CHECK(frame[107 * DFW_SIZE + 17] == 0x00FF48u);
    CHECK(frame[73 * DFW_SIZE + 21] == 0xFFD400u);
    CHECK(frame[61 * DFW_SIZE + 26] == 0x2C2C2Cu);
}

/// No reference has the tick over the fill: level 110 with the peak at 64, a mid-band pixel whole inside the tick
/// (fractions 0.500-0.512 of the tick's 0.487-0.521) is the tick's white, not the fill's green.
static void the_tick_is_drawn_over_the_fill(void) {
    start_deck4();
    send_meter(&unit, 110, 64);
    show();
    CHECK(frame[98 * DFW_SIZE + 17] == 0xFFFFFFu);
}

/// No reference has the marker over the meter: at 9 o'clock (needle 12288) over a clipping meter, a pixel whole inside
/// the marker's wedge (half width 1.125 at 82 out) is the marker's white, not the clip red.
static void the_marker_is_drawn_over_the_meter(void) {
    begin_with_needle(12288);
    feed(&live, "F0 00 02 0B 7F 10 20 00 03 0A 7F 7F F7");
    dfw_tick(&live, 10);
    CHECK(rec.presents == 2);
    CHECK(rec.last[99 * DFW_SIZE + 16] == 0xFFFFFFu);
}

/// Not vacuous: each meter reference differs from the unlit one, from MARKER_IN out.
static void each_meter_reference_differs_from_the_unlit_one(void) {
    static dfw_pixel unlit[DFW_SIZE * DFW_SIZE];
    static const char *const files[] = { "test/ref/deck4-blue-empty-meter0-0.ppm",
                                         "test/ref/deck4-blue-empty-meter64-90.ppm",
                                         "test/ref/deck4-blue-empty-meter110-120.ppm",
                                         "test/ref/deck4-blue-empty-meter127-127.ppm" };
    CHECK(load_reference(UNLIT));
    memcpy(unlit, reference, sizeof unlit);
    for (int f = 0; f < 3; f++) {
        CHECK(load_reference(files[f]));
        int changed = 0;
        for (int y = 0; y < DFW_SIZE; y++)
            for (int x = 0; x < DFW_SIZE; x++)
                changed += radius2(x, y) >= MARKER_IN * MARKER_IN && reference[y * DFW_SIZE + x] != unlit[y * DFW_SIZE + x];
        CHECK(changed > 300);
    }
}

/// The waiting look is agent3's; whatever it is, the meter changes none of it.
static void stale_draws_no_meter(void) {
    static dfw_pixel without[DFW_SIZE * DFW_SIZE];
    start_deck4();
    send_state(&unit, 0x20);   // Syndicate's feedback stopped
    draw_beat(0);
    memcpy(without, frame, sizeof without);
    send_meter(&unit, 64, 90);
    show();
    CHECK(memcmp(frame, without, sizeof frame) == 0);
}

/// The phase rule (#462): the rule and room around it (rows 120-135, x 40-157, where no text or ring reaches) against the renderer's references, exactly.
/// Its shapes are whole-pixel rectangles and the dim is rounded to a whole level on both sides, so nothing is smoothed.
typedef struct { const char *file; int16_t phase; } phase_case;
static const phase_case phases[] = {
    { "test/ref/deck4-blue-empty-phase0.ppm", 0 },
    { "test/ref/deck4-blue-empty-phase-164.ppm", -164 },
    { "test/ref/deck4-blue-empty-phase164.ppm", 164 },
    { "test/ref/deck4-blue-empty-phase-1638.ppm", -1638 },
    { "test/ref/deck4-blue-empty-phase8191.ppm", 8191 },
    // Unknown: the plain rule, as every other reference draws it.
    { UNLIT, DFW_PHASE_UNKNOWN },
};
#define PHASES (sizeof phases / sizeof phases[0])

/// Rows 120-135, x 40-157 (the rule with room, inside the ring) of `frame` against `reference`: how many differ at all.
static int rule_rows_off(void) {
    int off = 0;
    for (int y = 120; y < 136; y++)
        for (int x = 40; x < 158; x++) off += frame[y * DFW_SIZE + x] != reference[y * DFW_SIZE + x];
    return off;
}

static void the_phase_rule_is_drawn(void) {
    for (size_t n = 0; n < PHASES; n++) {
        CHECK(load_reference(phases[n].file));
        fresh(&live, &rec);
        feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
        feed(&live, "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7");   // deck 4, 0/128/255, empty
        if (phases[n].phase != DFW_PHASE_UNKNOWN) {
            char phase[64];
            int raw = phases[n].phase & 0x3FFF;
            snprintf(phase, sizeof phase, "F0 00 02 0B 7F 10 20 00 03 0B %02X %02X F7", raw >> 7, raw & 0x7F);
            feed(&live, phase);
        }
        dfw_tick(&live, 0);
        memcpy(frame, rec.last, sizeof frame);
        int off = rule_rows_off();
        if (off) fprintf(stderr, "    %s: %d pixels of the rule's rows off\n", phases[n].file + 9, off);
        CHECK(off == 0);
    }
}

/// Track time (#460): the progress ring (r 96-98, just outside the beat ring) and the time left under key/BPM, against
/// test/ref/*-time*.ppm. The ring's corners are compared from PROGRESS_FROM out: only the ring there for these decks.
#define PROGRESS_FROM 95.5f

/// Everything from PROGRESS_FROM out against `reference`: at most `budget` pixels more than `close` off, none past `cap`.
static int progress_matches(const char *name, int close, int budget, int cap) {
    int worst = 0, loose = 0, over = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            if (radius2(x, y) < PROGRESS_FROM * PROGRESS_FROM) continue;
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            if (d > worst) worst = d;
            if (d > close) loose++;
            if (d > cap) over++;
        }
    fprintf(stderr, "    %s ring from %.1f out: worst %d, %d over %d (budget %d)\n", name, (double)PROGRESS_FROM, worst,
            loose, close, budget);
    return over == 0 && loose <= budget;
}

#define PLAYING 0x03
#define PAUSED 0x01

/// Begin, the deck, the state, then a time message, then a tick at `now`.
static void begin_with_time(const char *deck, uint8_t flags, uint16_t elapsed, uint16_t length, uint32_t now) {
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, deck);
    char message[64];
    snprintf(message, sizeof message, "F0 00 02 0B 7F 10 20 00 02 07 %02X F7", flags);
    feed(&live, message);
    snprintf(message, sizeof message, "F0 00 02 0B 7F 10 20 00 05 06 %02X %02X %02X %02X F7", elapsed >> 7,
             elapsed & 0x7F, length >> 7, length & 0x7F);
    feed(&live, message);
    dfw_tick(&live, now);
}

#define DECK_4_BLUE_EMPTY "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7"
#define DECK_2_RED_EMPTY "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 00 F7"

typedef struct { const char *file; uint16_t elapsed, length; int budget; } time_case;
static const time_case times[] = {
    // The start: the dark track all round, no fill.
    { "test/ref/deck4-blue-empty-time0-165.ppm", 0, 165, PROGRESS_BUDGET_START },
    // Just past half: the fill past 180°.
    { "test/ref/deck4-blue-empty-time83-165.ppm", 83, 165, PROGRESS_BUDGET_FILL },
    { "test/ref/deck4-blue-empty-time0-5999.ppm", 0, 5999, PROGRESS_BUDGET_START },
};
#define TIMES (sizeof times / sizeof times[0])

/// The time left, centered at (99, 160) at 21 px (#524; ink y 152-168): compared over a box around its line that holds
/// nothing else for these decks.
#define TIME_LEFT 60
#define TIME_RIGHT 139
#define TIME_TOP 148
#define TIME_BOTTOM 174

static int time_text_matches(const char *name, int close, int budget, int cap) {
    int worst = 0, loose = 0, over = 0;
    for (int y = TIME_TOP; y < TIME_BOTTOM; y++)
        for (int x = TIME_LEFT; x < TIME_RIGHT; x++) {
            int d = channel_diff(frame[y * DFW_SIZE + x], reference[y * DFW_SIZE + x]);
            if (d > worst) worst = d;
            if (d > close) loose++;
            if (d > cap) over++;
        }
    fprintf(stderr, "    %s time: worst %d, %d over %d (budget %d)\n", name, worst, loose, close, budget);
    return over == 0 && loose <= budget;
}

static void the_time_left_is_drawn(void) {
    for (size_t n = 0; n < TIMES; n++) {
        CHECK(load_reference(times[n].file));
        begin_with_time(DECK_4_BLUE_EMPTY, PAUSED, times[n].elapsed, times[n].length, 0);
        memcpy(frame, rec.last, sizeof frame);
        CHECK(time_text_matches(times[n].file + 9, TIME_CLOSE, TIME_BUDGET, TIME_CAP));
    }
}

/// The wire's longest, 16383 s, is "-273:03": minutes never wrap to hours, and its seventh character is drawn, wider
/// than "-99:59" (from x 61.2 at 21 px) on the left.
static void the_longest_time_has_three_digit_minutes(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, PAUSED, 0, 16383, 0);
    int ink = 0;
    for (int y = TIME_TOP; y < TIME_BOTTOM; y++)
        for (int x = 55; x < 60; x++) ink += rec.last[y * DFW_SIZE + x] != 0x0B0B0Bu;
    CHECK(ink > 10);
}

/// The needle crosses the ring on top: the marker at 3 o'clock over the fill at 83/165, compared from MARKER_IN out.
static void the_marker_is_drawn_over_the_progress_ring(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-time83-165-needle4096.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
    feed(&live, "F0 00 02 0B 7F 10 20 00 03 09 20 00 F7");   // 4096
    dfw_tick(&live, 10);
    CHECK(rec.presents == 2);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(band_from_matches("deck4-blue-empty-time83-165-needle4096.ppm", PROGRESS_CLOSE, PROGRESS_BUDGET_FILL,
                            PROGRESS_CAP));
}

/// The last minute's warning (#460, #524, JogTrackTime): while playing with 30 s or less left, red (text and fill) for the
/// first 500 ms after the time changes, then white, whatever the deck color. 135 of 165 is 30 s left.

/// The red half: the frame the time message lands on.
static void the_warning_starts_red(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-red.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 0);
    CHECK(rec.presents == 1);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(progress_matches("deck4-blue-empty-time135-165-red.ppm", PROGRESS_CLOSE, PROGRESS_BUDGET_LONG, PROGRESS_CAP));
    CHECK(time_text_matches("deck4-blue-empty-time135-165-red.ppm", TIME_RED_CLOSE, TIME_RED_BUDGET, TIME_RED_CAP));
}

/// 500 ms after the time came, the white half, with a frame of its own; none before.
static void the_blink_turns_white_at_500_ms(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-white.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 1000);
    dfw_tick(&live, 1499);
    CHECK(rec.presents == 1);
    dfw_tick(&live, 1500);
    CHECK(rec.presents == 2);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(progress_matches("deck4-blue-empty-time135-165-white.ppm", PROGRESS_CLOSE, PROGRESS_BUDGET_LONG,
                           PROGRESS_CAP));
    CHECK(time_text_matches("deck4-blue-empty-time135-165-white.ppm", TIME_CLOSE, TIME_BUDGET, TIME_CAP));
}

/// A red deck's white half is the same white.
static void a_red_decks_white_half_is_white(void) {
    CHECK(load_reference("test/ref/deck2-red-empty-time135-165-white.ppm"));
    begin_with_time(DECK_2_RED_EMPTY, PLAYING, 135, 165, 0);
    dfw_tick(&live, 500);
    CHECK(rec.presents == 2);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(progress_matches("deck2-red-empty-time135-165-white.ppm", PROGRESS_CLOSE, PROGRESS_BUDGET_LONG,
                           PROGRESS_CAP));
    CHECK(time_text_matches("deck2-red-empty-time135-165-white.ppm", TIME_CLOSE, TIME_BUDGET, TIME_CAP));
}

/// Not vacuous: red and white halves differ, in the ring and in the text; both decks' white halves are white.
static void the_warning_references_differ(void) {
    static dfw_pixel red[DFW_SIZE * DFW_SIZE];
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-red.ppm"));
    memcpy(red, reference, sizeof red);
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-white.ppm"));
    int ring = 0, text = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++) {
            int differs = red[y * DFW_SIZE + x] != reference[y * DFW_SIZE + x];
            ring += differs && radius2(x, y) >= PROGRESS_FROM * PROGRESS_FROM;
            text += differs && x >= TIME_LEFT && x < TIME_RIGHT && y >= TIME_TOP && y < TIME_BOTTOM;
        }
    CHECK(ring > 1000 && text > 100);
    // The ring at 1:30, r 105 (frame 173, 25: the band crosses the frame's corner there), inside the fill: white, red,
    // white.
    CHECK(reference[25 * DFW_SIZE + 173] == 0xEDEDEAu);
    CHECK(red[25 * DFW_SIZE + 173] == 0xFF3B30u);
    CHECK(load_reference("test/ref/deck2-red-empty-time135-165-white.ppm"));
    CHECK(reference[25 * DFW_SIZE + 173] == 0xEDEDEAu);
}

/// The blink keeps going off the last change when no new second comes (a dropped message): red again at 1 s, white
/// at 1.5 s, never frozen in either half.
static void the_warning_keeps_blinking_without_a_new_second(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 0);
    dfw_tick(&live, 500);
    CHECK(rec.presents == 2);
    dfw_tick(&live, 1000);
    CHECK(rec.presents == 3);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
    dfw_tick(&live, 1500);
    CHECK(rec.presents == 4);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xEDEDEAu);
}

/// Each new second starts red again, on the frame the digit changes; the heartbeat's same time doesn't restart it.
static void a_new_second_restarts_the_red(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 0);
    dfw_tick(&live, 700);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xEDEDEAu);
    feed(&live, "F0 00 02 0B 7F 10 20 00 05 06 01 07 01 25 F7");   // 135 of 165 again
    dfw_tick(&live, 800);
    CHECK(rec.presents == 2);
    feed(&live, "F0 00 02 0B 7F 10 20 00 05 06 01 08 01 25 F7");   // 136 of 165
    dfw_tick(&live, 900);
    CHECK(rec.presents == 3);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
    dfw_tick(&live, 1399);
    CHECK(rec.presents == 3);
    dfw_tick(&live, 1400);
    CHECK(rec.presents == 4);
}

/// Paused inside the last minute: no warning, the normal colors (the text white, as the white half's, the fill the
/// deck's), and nothing blinks.
static void paused_in_the_last_minute_draws_the_normal_colors(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-white.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, PAUSED, 135, 165, 0);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(frame[25 * DFW_SIZE + 173] == 0x0080FFu);
    CHECK(time_text_matches("deck4-blue-empty-time135-165-white.ppm (paused)", TIME_CLOSE, TIME_BUDGET, TIME_CAP));
    dfw_tick(&live, 500);
    dfw_tick(&live, 1000);
    CHECK(rec.presents == 1);
    // A red deck paused keeps its own color.
    begin_with_time(DECK_2_RED_EMPTY, PAUSED, 135, 165, 0);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF0000u);
}

/// The warning's first stage (#524): steady red from 60 s left to 31 s, whatever the phase. At 45 s left it is the
/// renderer's red, and stays red past 500 ms and 1.5 s with no white frame and no redraw for a flip.
static void the_warning_is_steady_red_from_60_to_31_seconds(void) {
    CHECK(load_reference("test/ref/deck4-blue-empty-time120-165-red.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 120, 165, 0);
    CHECK(rec.presents == 1);
    memcpy(frame, rec.last, sizeof frame);
    // The fill at 120/165 (262°): measured worst 7, 31 pixels over 6, all on the circles, as 83/165's.
    CHECK(progress_matches("deck4-blue-empty-time120-165-red.ppm", PROGRESS_CLOSE, PROGRESS_BUDGET_FILL, PROGRESS_CAP));
    CHECK(time_text_matches("deck4-blue-empty-time120-165-red.ppm", TIME_RED_CLOSE, TIME_RED_BUDGET, TIME_RED_CAP));
    dfw_tick(&live, 500);
    dfw_tick(&live, 1000);
    dfw_tick(&live, 1500);
    CHECK(rec.presents == 1);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
}

/// Loaded, playing and loop on (state bit 4).
#define LOOPING 0x13

/// A loop holds the warning (#524): with loop on, the normal look at 45 s left and at 20 s, and nothing blinks.
static void a_loop_holds_the_warning(void) {
    static const uint16_t elapsed[] = { 120, 145 };
    for (size_t n = 0; n < 2; n++) {
        begin_with_time(DECK_4_BLUE_EMPTY, LOOPING, elapsed[n], 165, 0);
        CHECK(rec.last[25 * DFW_SIZE + 173] == 0x0080FFu);
        dfw_tick(&live, 500);
        dfw_tick(&live, 1000);
        CHECK(rec.presents == 1);
    }
    CHECK(load_reference("test/ref/deck4-blue-empty-time135-165-white.ppm"));
    begin_with_time(DECK_4_BLUE_EMPTY, LOOPING, 135, 165, 0);
    memcpy(frame, rec.last, sizeof frame);
    CHECK(time_text_matches("deck4-blue-empty-time135-165-white.ppm (looping)", TIME_CLOSE, TIME_BUDGET, TIME_CAP));
}

/// The state that clears the loop brings the warning back on that same tick's frame: red, steady at 45 s left, and
/// at 20 s the blink from the time's last change.
static void releasing_the_loop_redraws_the_warning_at_once(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, LOOPING, 120, 165, 0);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 07 03 F7");
    dfw_tick(&live, 600);
    CHECK(rec.presents == 2);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
    begin_with_time(DECK_4_BLUE_EMPTY, LOOPING, 145, 165, 0);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 07 03 F7");
    dfw_tick(&live, 100);
    CHECK(rec.presents == 2);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
    // And a loop set again drops it at once.
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 07 13 F7");
    dfw_tick(&live, 200);
    CHECK(rec.presents == 3);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0x0080FFu);
}

/// The stages' edges: 61 s left is normal; 60 s and 31 s are steady red; 30 s blinks; past the end (elapsed over the
/// length) blinks.
static void the_warning_stages_start_at_60_and_30_seconds(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 104, 165, 0);
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0x0080FFu);
    dfw_tick(&live, 500);
    CHECK(rec.presents == 1);
    static const uint16_t steady[] = { 105, 134 };
    for (size_t n = 0; n < 2; n++) {
        begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, steady[n], 165, 0);
        CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
        dfw_tick(&live, 500);
        CHECK(rec.presents == 1);
    }
    static const uint16_t blinking[] = { 135, 200 };
    for (size_t n = 0; n < 2; n++) {
        begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, blinking[n], 165, 0);
        CHECK(rec.last[25 * DFW_SIZE + 173] == 0xFF3B30u);
        dfw_tick(&live, 500);
        CHECK(rec.presents == 2 && rec.last[25 * DFW_SIZE + 173] == 0xEDEDEAu);
    }
}

/// The clock wrapping mid-blink is 500 ms like any other.
static void the_blink_survives_the_clock_wrapping(void) {
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 0xFFFFFF00u);
    dfw_tick(&live, 0xFFFFFF00u + 499u);
    CHECK(rec.presents == 1);
    dfw_tick(&live, 0xFFFFFF00u + 500u);   // wrapped past 0
    CHECK(rec.presents == 2);
}

/// The blink's white is the same for every deck color (#524): no near-red rule. Orange, a pale red and white itself.
static void every_decks_white_half_is_white(void) {
    static const char *const decks[] = {
        "F0 00 02 0B 7F 10 20 00 09 03 01 01 7F 01 00 00 00 00 F7",   // 255 128 0
        "F0 00 02 0B 7F 10 20 00 09 03 01 01 7F 01 0C 01 0C 00 F7",   // 255 140 140
        "F0 00 02 0B 7F 10 20 00 09 03 01 01 7F 01 7F 01 7F 00 F7",   // 255 255 255
    };
    for (size_t n = 0; n < sizeof decks / sizeof decks[0]; n++) {
        begin_with_time(decks[n], PLAYING, 135, 165, 0);
        dfw_tick(&live, 500);
        CHECK(rec.presents == 2);
        CHECK(rec.last[25 * DFW_SIZE + 173] == 0xEDEDEAu);
    }
}

static void the_progress_ring_is_drawn(void) {
    for (size_t n = 0; n < TIMES; n++) {
        CHECK(load_reference(times[n].file));
        begin_with_time(DECK_4_BLUE_EMPTY, PAUSED, times[n].elapsed, times[n].length, 0);
        CHECK(rec.presents == 1);
        memcpy(frame, rec.last, sizeof frame);
        CHECK(progress_matches(times[n].file + 9, PROGRESS_CLOSE, times[n].budget, PROGRESS_CAP));
    }
}

/// Not vacuous: each time reference has the ring the plain one doesn't.
static void each_time_reference_differs_from_the_plain_one(void) {
    static dfw_pixel plain[DFW_SIZE * DFW_SIZE];
    CHECK(load_reference(UNLIT));
    memcpy(plain, reference, sizeof plain);
    for (size_t n = 0; n < TIMES; n++) {
        CHECK(load_reference(times[n].file));
        int changed = 0;
        for (int y = 0; y < DFW_SIZE; y++)
            for (int x = 0; x < DFW_SIZE; x++)
                changed += radius2(x, y) >= PROGRESS_FROM * PROGRESS_FROM && reference[y * DFW_SIZE + x] != plain[y * DFW_SIZE + x];
        CHECK(changed > 1000);
        changed = 0;
        for (int y = TIME_TOP; y < TIME_BOTTOM; y++)
            for (int x = TIME_LEFT; x < TIME_RIGHT; x++) changed += reference[y * DFW_SIZE + x] != plain[y * DFW_SIZE + x];
        CHECK(changed > 150);
    }
}

/// An unknown length (0) draws no time and no ring: the whole frame is the plain one's, as Swift's
/// deck4-blue-empty-time42-0 is, and as a fresh unit with no time draws.
static void an_unknown_length_draws_nothing(void) {
    static dfw_pixel without[DFW_SIZE * DFW_SIZE];
    fresh(&live, &rec);
    feed(&live, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&live, DECK_4_BLUE_EMPTY);
    dfw_tick(&live, 0);
    memcpy(without, rec.last, sizeof without);
    begin_with_time(DECK_4_BLUE_EMPTY, PLAYING, 42, 0, 0);
    CHECK(rec.presents == 1);
    CHECK(memcmp(rec.last, without, sizeof without) == 0);
    CHECK(load_reference("test/ref/deck4-blue-empty-time42-0.ppm"));
    memcpy(frame, rec.last, sizeof frame);
    CHECK(progress_matches("deck4-blue-empty-time42-0.ppm", RING_CLOSE, 0, RING_CLOSE));
}

/// The waiting look is agent3's; whatever it is, the time changes none of it.
static void stale_draws_no_time(void) {
    static dfw_pixel without[DFW_SIZE * DFW_SIZE];
    start_deck4();
    send_state(&unit, 0x20);   // Syndicate's feedback stopped
    draw_beat(0);
    memcpy(without, frame, sizeof without);
    send_time(&unit, 83, 165);
    show();
    CHECK(memcmp(frame, without, sizeof frame) == 0);
}

const test_case draw_live_tests[] = {
    { "the progress ring is drawn", the_progress_ring_is_drawn },
    { "the time left is drawn", the_time_left_is_drawn },
    { "the warning starts red", the_warning_starts_red },
    { "the blink turns white at 500 ms", the_blink_turns_white_at_500_ms },
    { "a red deck's white half is white", a_red_decks_white_half_is_white },
    { "the warning references differ", the_warning_references_differ },
    { "the warning keeps blinking without a new second", the_warning_keeps_blinking_without_a_new_second },
    { "a new second restarts the red", a_new_second_restarts_the_red },
    { "paused in the last minute draws the normal colors", paused_in_the_last_minute_draws_the_normal_colors },
    { "the warning is steady red from 60 to 31 seconds", the_warning_is_steady_red_from_60_to_31_seconds },
    { "the warning stages start at 60 and 30 seconds", the_warning_stages_start_at_60_and_30_seconds },
    { "a loop holds the warning", a_loop_holds_the_warning },
    { "releasing the loop redraws the warning at once", releasing_the_loop_redraws_the_warning_at_once },
    { "the blink survives the clock wrapping", the_blink_survives_the_clock_wrapping },
    { "every deck's white half is white", every_decks_white_half_is_white },
    { "the marker is drawn over the progress ring", the_marker_is_drawn_over_the_progress_ring },
    { "the longest time has three digit minutes", the_longest_time_has_three_digit_minutes },
    { "each time reference differs from the plain one", each_time_reference_differs_from_the_plain_one },
    { "an unknown length draws nothing", an_unknown_length_draws_nothing },
    { "stale draws no time", stale_draws_no_time },
    { "the phase rule is drawn", the_phase_rule_is_drawn },
    { "the meter is drawn", the_meter_is_drawn },
    { "each meter reference differs from the unlit one", each_meter_reference_differs_from_the_unlit_one },
    { "stale draws no meter", stale_draws_no_meter },
    { "the fill turns yellow past three quarters", the_fill_turns_yellow_past_three_quarters },
    { "the tick is drawn over the fill", the_tick_is_drawn_over_the_fill },
    { "the marker is drawn over the meter", the_marker_is_drawn_over_the_meter },
    { "the play flags change no pixels", the_play_flags_change_no_pixels },
    { "the needle is drawn as the marker", the_needle_is_drawn_as_the_marker },
    { "the marker is drawn over the lit section", the_marker_is_drawn_over_the_lit_section },
    { "each marker reference differs from the unlit one", each_marker_reference_differs_from_the_unlit_one },
    { "no needle message draws no marker", no_needle_message_draws_no_marker },
    { "a needle message changes the frame", a_needle_message_changes_the_frame },
    { "the first needle at 12 o'clock presents", the_first_needle_at_12_oclock_presents },
    { "the same angle does not present again", the_same_angle_does_not_present_again },
    { "end forgets the needle", end_forgets_the_needle },
    { "stale draws no marker", stale_draws_no_marker },
    { "each beat lights its section", each_beat_lights_its_section },
    { "each lit reference differs from the unlit one", each_lit_reference_differs_from_the_unlit_one },
    { "no master clock lights no section", no_master_clock_lights_no_section },
    { "stale lights no section", stale_lights_no_section },
    { 0, 0 },
};
