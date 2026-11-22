// The progress ring in the band outside the frame (#524): dfw_band_pixels against the whole 216 drawn image the
// renderer draws (test/ref/band-*.ppm, a manifest entry with canvas 216, never from this code), and dfw_draw_band's layer.
#include "harness.h"
#include "draw_band.h"
#include "band_geometry.h"
#include "band_table.h"
#include "layer_record.h"
#include <string.h>

#define CANVAS 216
/// The frame sits 9 px in on the drawn image.
#define INSET ((CANVAS - DFW_SIZE) / 2)
#define GROUND DFW_GROUND

static dfw_pixel reference[CANVAS * CANVAS];
static dfw_pixel canvas[CANVAS * CANVAS];

static int load_canvas_reference(const char *file) {
    FILE *f = fopen(file, "rb");
    if (!f) { fprintf(stderr, "can't open %s\n", file); return 0; }
    int w = 0, h = 0, max = 0;
    int ok = fscanf(f, "P6 %d %d %d", &w, &h, &max) == 3 && w == CANVAS && h == CANVAS && max == 255 && fgetc(f) == '\n';
    static uint8_t rgb[CANVAS * CANVAS * 3];
    ok = ok && fread(rgb, 1, sizeof rgb, f) == sizeof rgb;
    fclose(f);
    if (!ok) { fprintf(stderr, "%s is not a %dx%d P6 PPM\n", file, CANVAS, CANVAS); return 0; }
    for (size_t i = 0; i < CANVAS * CANVAS; i++)
        reference[i] = (dfw_pixel)rgb[i * 3] << 16 | (dfw_pixel)rgb[i * 3 + 1] << 8 | rgb[i * 3 + 2];
    return 1;
}

typedef struct { int count, outside, twice; } put_log;
static uint8_t seen[CANVAS * CANVAS];

/// Puts onto the canvas at +INSET; counts them, those off the canvas, and any pixel put twice.
static void canvas_put(void *ctx, int x, int y, dfw_pixel color) {
    put_log *log = ctx;
    log->count++;
    int cx = x + INSET, cy = y + INSET;
    if (cx < 0 || cy < 0 || cx >= CANVAS || cy >= CANVAS) { log->outside++; return; }
    if (seen[cy * CANVAS + cx]++) log->twice++;
    canvas[cy * CANVAS + cx] = color;
}

/// The drawn image's ground with nothing on it: the panel's black, the frame's ground in the 198 square.
static void blank_canvas(void) {
    for (int y = 0; y < CANVAS; y++)
        for (int x = 0; x < CANVAS; x++)
            canvas[y * CANVAS + x] = x >= INSET && x < INSET + DFW_SIZE && y >= INSET && y < INSET + DFW_SIZE ? GROUND : 0;
    memset(seen, 0, sizeof seen);
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

/// Whether canvas pixel (x, y) is in the band, r 101-109 round the canvas's center (108, 108): the ring with a pixel
/// of ground either side. The reference's frame (its beat ring reaches r 95) is all inside it.
static int in_band(int x, int y) {
    float dx = (float)x + 0.5f - 108.0f, dy = (float)y + 0.5f - 108.0f, r2 = dx * dx + dy * dy;
    return r2 >= 101.0f * 101.0f && r2 <= 109.0f * 109.0f;
}

/// The band of the canvas against the reference's.
static int band_matches(const char *name, int close, int budget, int cap) {
    int worst = 0, loose = 0, over = 0;
    for (int i = 0; i < CANVAS * CANVAS; i++) {
        if (!in_band(i % CANVAS, i / CANVAS)) continue;
        int d = channel_diff(canvas[i], reference[i]);
        if (d > worst) worst = d;
        if (d > close) loose++;
        if (d > cap) over++;
    }
    fprintf(stderr, "    %s band: worst %d, %d over %d (budget %d)\n", name, worst, loose, close, budget);
    return over == 0 && loose <= budget;
}

/// draw_band.c's sin and cos of a turn, as it was.
static void reference_sin_cos(float turns, float *sin_out, float *cos_out) {
    int quarter = (int)(turns * 4.0f + 0.5f);
    float a = (turns - (float)quarter / 4.0f) * 6.2831853f, a2 = a * a;
    float s = a * (1.0f - a2 / 6.0f * (1.0f - a2 / 20.0f * (1.0f - a2 / 42.0f * (1.0f - a2 / 72.0f))));
    float c = 1.0f - a2 / 2.0f * (1.0f - a2 / 12.0f * (1.0f - a2 / 30.0f * (1.0f - a2 / 56.0f)));
    switch (quarter & 3) {
    case 0: *sin_out = s; *cos_out = c; break;
    case 1: *sin_out = c; *cos_out = -s; break;
    case 2: *sin_out = -s; *cos_out = -c; break;
    default: *sin_out = -c; *cos_out = s; break;
    }
}

static dfw_unit unit;
static recording rec;

#define DECK_4_BLUE_EMPTY "F0 00 02 0B 7F 10 20 00 09 03 04 00 00 01 00 01 7F 00 F7"
#define DECK_2_RED_EMPTY "F0 00 02 0B 7F 10 20 00 09 03 02 01 7F 00 00 00 00 00 F7"
#define PLAYING 0x03
#define PAUSED 0x01

/// Begin, the deck, the state, a time, then a tick at 0 and one at `later` (the blink's white at 500).
static void with_time(const char *deck, uint8_t flags, uint16_t elapsed, uint16_t length, uint32_t later) {
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, deck);
    char message[64];
    snprintf(message, sizeof message, "F0 00 02 0B 7F 10 20 00 02 07 %02X F7", flags);
    feed(&unit, message);
    snprintf(message, sizeof message, "F0 00 02 0B 7F 10 20 00 05 06 %02X %02X %02X %02X F7", elapsed >> 7,
             elapsed & 0x7F, length >> 7, length & 0x7F);
    feed(&unit, message);
    dfw_tick(&unit, 0);
    if (later) dfw_tick(&unit, later);
}

/// As the ring's in the frame were (#460): the band is all edge, and CoreGraphics lands its circles a little off the
/// exact areas. Measured: the track alone within 3; the fills worst 10, with 51 (83/165), 59 (120/165, red) and 68
/// (135/165, white) pixels over 6. So 6 with a budget a little over each case's count, and nothing past 16.
#define BAND_CLOSE 6
#define BAND_CAP 16

typedef struct { const char *file, *deck; uint8_t flags; uint16_t elapsed, length; uint32_t later; int budget; } band_case;
static const band_case cases[] = {
    { "test/ref/band-deck4-blue-empty-time0-165.ppm", DECK_4_BLUE_EMPTY, PAUSED, 0, 165, 0, 0 },
    { "test/ref/band-deck4-blue-empty-time83-165.ppm", DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0, 55 },
    { "test/ref/band-deck4-blue-empty-time120-165-red.ppm", DECK_4_BLUE_EMPTY, PLAYING, 120, 165, 0, 65 },
    { "test/ref/band-deck4-blue-empty-time135-165-white.ppm", DECK_4_BLUE_EMPTY, PLAYING, 135, 165, 500, 75 },
    { "test/ref/band-deck2-red-empty-time135-165-white.ppm", DECK_2_RED_EMPTY, PLAYING, 135, 165, 500, 75 },
};
#define CASES (sizeof cases / sizeof cases[0])

static void the_band_ring_is_the_renderers(void) {
    for (size_t n = 0; n < CASES; n++) {
        CHECK(load_canvas_reference(cases[n].file));
        with_time(cases[n].deck, cases[n].flags, cases[n].elapsed, cases[n].length, cases[n].later);
        blank_canvas();
        put_log log = { 0, 0, 0 };
        dfw_band_pixels(&unit, canvas_put, &log);
        CHECK(log.count > 0 && log.outside == 0 && log.twice == 0);
        CHECK(band_matches(cases[n].file + 9, BAND_CLOSE, cases[n].budget, BAND_CAP));
    }
}

/// Not vacuous: each band reference has the ring, thousands of pixels in the band off the blank ground, and nothing
/// past r 109 but the panel's black.
static void each_band_reference_has_the_ring(void) {
    blank_canvas();
    for (size_t n = 0; n < CASES; n++) {
        CHECK(load_canvas_reference(cases[n].file));
        int ring = 0, outside = 0;
        for (int y = 0; y < CANVAS; y++)
            for (int x = 0; x < CANVAS; x++) {
                float dx = (float)x + 0.5f - 108.0f, dy = (float)y + 0.5f - 108.0f;
                if (in_band(x, y)) ring += reference[y * CANVAS + x] != canvas[y * CANVAS + x];
                else if (dx * dx + dy * dy > 109.0f * 109.0f) outside += reference[y * CANVAS + x] != canvas[y * CANVAS + x];
            }
        CHECK(ring > 2000 && outside == 0);
    }
}

/// No time, an unknown length, the display stale, or not drawing: no pixels at all.
static void no_ring_puts_nothing(void) {
    put_log log = { 0, 0, 0 };
    fresh(&unit, &rec);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 01 01 F7");
    feed(&unit, DECK_4_BLUE_EMPTY);
    dfw_tick(&unit, 0);
    blank_canvas();
    dfw_band_pixels(&unit, canvas_put, &log);
    CHECK(log.count == 0);
    with_time(DECK_4_BLUE_EMPTY, PLAYING, 42, 0, 0);
    dfw_band_pixels(&unit, canvas_put, &log);
    CHECK(log.count == 0);
    with_time(DECK_4_BLUE_EMPTY, 0x21, 83, 165, 0);   // feedback stale
    dfw_band_pixels(&unit, canvas_put, &log);
    CHECK(log.count == 0);
    with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
    dfw_tick(&unit, 3000);   // silent
    dfw_band_pixels(&unit, canvas_put, &log);
    CHECK(log.count == 0);
    with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
    feed(&unit, "F0 00 02 0B 7F 10 20 00 02 02 01 F7");   // end
    dfw_tick(&unit, 10);
    dfw_band_pixels(&unit, canvas_put, &log);
    CHECK(log.count == 0);
}

static uint16_t layer[DFW_LAYER_W * DFW_LAYER_H];
static uint16_t want[DFW_LAYER_W * DFW_LAYER_H];


/// What the layer should get: each band pixel outside the 198 square, turned as the frame is, in RGB565.
static void want_put(void *ctx, int x, int y, dfw_pixel color) {
    (void)ctx;
    if (x >= 0 && x < DFW_SIZE && y >= 0 && y < DFW_SIZE) return;
    want[dfw_panel_index(x, y)] = dfw_rgb565(color);
}

/// Whether the panel pixel (px, py) is in the band's annulus outside the frame: what dfw_draw_band clears.
static int in_cleared_band(int px, int py) {
    int x, y;
    dfw_panel_to_frame(py * DFW_LAYER_STRIDE + px, &x, &y);
    if (dfw_in_frame(x, y)) return 0;
    float dx = (float)x + 0.5f - 99.0f, dy = (float)y + 0.5f - 99.0f, r2 = dx * dx + dy * dy;
    return r2 >= 101.5f * 101.5f && r2 <= 108.5f * 108.5f;
}

/// dfw_draw_band writes the ring's pixels outside the frame into the 320 x 240 layer, turned and in RGB565; the frame's
/// square and everything outside the band keep what they had. With no ring, the band is cleared to black.
static void the_band_lands_on_the_layer_turned_and_in_rgb565(void) {
    with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) layer[i] = want[i] = 0x1234u;
    for (int py = 0; py < DFW_LAYER_H; py++)
        for (int px = 0; px < DFW_LAYER_W; px++)
            if (in_cleared_band(px, py)) want[py * DFW_LAYER_W + px] = 0;
    dfw_band_pixels(&unit, want_put, 0);
    dfw_draw_band(layer, &unit);
    int off = 0, set = 0;
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) {
        off += layer[i] != want[i];
        set += layer[i] != 0x1234u && layer[i] != 0;
    }
    CHECK(off == 0);
    // Over half the band is inside the square, at the diagonals: the rest is still well over a thousand pixels.
    CHECK(set > 1000);
    // 12 o'clock, r 105, is the fill's start in the deck's blue: frame (98, -7) lands at panel (160, 225).
    CHECK(layer[dfw_panel_index(99, -7)] != 0x1234u);
    // The ring gone: the band's black, the rest untouched.
    feed(&unit, "F0 00 02 0B 7F 10 20 00 05 06 00 2A 00 00 F7");   // unknown length
    dfw_tick(&unit, 10);
    dfw_draw_band(layer, &unit);
    off = 0;
    for (int py = 0; py < DFW_LAYER_H; py++)
        for (int px = 0; px < DFW_LAYER_W; px++) {
            uint16_t p = layer[py * DFW_LAYER_W + px];
            off += in_cleared_band(px, py) ? p != 0 : p != want[py * DFW_LAYER_W + px];
        }
    CHECK(off == 0);
}

/// The present copies the frame, the ring's corners with it, and the band follows: its clear must leave the square
/// alone as its draw does (agent2's review). At 1:30, r 105, frame (173, 25), panel (85, 193): still the frame's color.
static void the_bands_clear_leaves_the_frames_corners(void) {
    with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) layer[i] = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++)
            layer[dfw_panel_index(x, y)] = dfw_rgb565(rec.last[y * DFW_SIZE + x]);
    uint16_t corner = layer[dfw_panel_index(173, 25)];
    CHECK(corner == dfw_rgb565(0x0080FFu));   // the fill, past 1:30 at 83/165
    dfw_draw_band(layer, &unit);
    CHECK(layer[dfw_panel_index(173, 25)] == corner);
    // And every pixel of the square is the frame's still.
    int off = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++)
            off += layer[dfw_panel_index(x, y)] != dfw_rgb565(rec.last[y * DFW_SIZE + x]);
    CHECK(off == 0);
}

/// The frame draws the ring's corners itself: the band at r 103-107 crosses the 198 square at its diagonals, and the
/// layer's band leaves the square to the frame.
static void the_frame_draws_the_rings_corners(void) {
    with_time(DECK_4_BLUE_EMPTY, PAUSED, 0, 165, 0);
    // 1:30 on the clock face, r 105: frame (173, 25), the track's gray.
    CHECK(rec.last[25 * DFW_SIZE + 173] == 0x4A4A4Au);
}

/// The recording adapter (test/layer_record.c): the seam's every write, per present.
static layer_recorder record;

/// One present's band through the recorder.
static void record_band(void) {
    recorder_next_present(&record);
    const dfw_layer layer = recorder_layer(&record);
    dfw_band_layer(&unit, &layer);
}

static int most_writes(void) { return recorder_most_writes(&record); }

// Each pixel once with its final value, and an unchanged ring writing nothing, are checked at the whole panel, through
// the same dfw_band_layer seam (#573: one behavior test per seam): test_panel_record.c's "every present writes each
// pixel once and never black then lit" (no pixel twice, none black then lit, the band writing no unchanged pixel, none
// in the square, which A's copy writes) and "an unchanged scene writes nothing".

/// (4), (5): a ring that goes (an unknown length, stale, a deck change) leaves the band black outside the square, the
/// square untouched; and writes only what was lit.
static void a_ring_that_goes_leaves_black(void) {
    static const struct { const char *message; uint32_t now; } goes[] = {
        { "F0 00 02 0B 7F 10 20 00 05 06 00 2A 00 00 F7", 10 },                        // unknown length
        { "F0 00 02 0B 7F 10 20 00 02 07 21 F7", 10 },                                  // feedback stale
        { "F0 00 02 0B 7F 10 20 00 09 03 03 00 00 01 48 00 50 00 F7", 10 },             // another deck
    };
    for (size_t n = 0; n < sizeof goes / sizeof goes[0]; n++) {
        for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) record.pixels[i] = 0x1234u;
        for (int py = 0; py < DFW_LAYER_H; py++)
            for (int px = 0; px < DFW_LAYER_W; px++)
                if (in_cleared_band(px, py)) record.pixels[py * DFW_LAYER_W + px] = 0;
        with_time(DECK_4_BLUE_EMPTY, PAUSED, 83, 165, 0);
        record_band();
        int lit = record.total;
        feed(&unit, goes[n].message);
        dfw_tick(&unit, goes[n].now);
        record_band();
        int off = 0;
        for (int py = 0; py < DFW_LAYER_H; py++)
            for (int px = 0; px < DFW_LAYER_W; px++) {
                uint16_t p = record.pixels[py * DFW_LAYER_W + px];
                off += in_cleared_band(px, py) ? p != 0 : p != 0x1234u;
            }
        CHECK(off == 0 && record.in_square == 0 && most_writes() == 1);
        CHECK(record.total > 0 && record.total <= lit);
    }
}

/// The ring as draw_band.c worked it out per pixel before its table (#558), from the same geometry: the reference the
/// table walk must equal bit for bit, for any progress and fill.
static int reference_pixel(float turns, dfw_pixel fill, int x, int y, dfw_pixel *color) {
    float band, start;
    dfw_pixel track;
    if (!band_shape(x, y, &band, &start, &track)) return 0;
    float dx = (float)x + 0.5f - CENTER, dy = (float)y + 0.5f - CENTER;
    dfw_pixel c = track;
    if (turns > 0.0f) {
        float cover = 1.0f;
        if (turns < 1.0f) {
            float sn, cs;
            reference_sin_cos(turns, &sn, &cs);
            float end = edge_cover(dx * -cs + dy * -sn, -cs, -sn);
            cover = clamp01(turns <= 0.5f ? start + end - 1.0f : start + end);
        }
        c = blend(c, fill, band * cover);
    }
    *color = c;
    return 1;
}

typedef struct { int count, off; float turns; dfw_pixel fill; } compare_log;

static void compare_put(void *ctx, int x, int y, dfw_pixel color) {
    compare_log *log = ctx;
    dfw_pixel want;
    log->count++;
    if (!reference_pixel(log->turns, log->fill, x, y, &want) || want != color) log->off++;
}

/// The table walk is the geometry, pixel for pixel: every elapsed second of a 165 s track and of a 3600 s one's first
/// and last minutes, in the deck color, and in red and white where the warning shows them; and the number of pixels is
/// the geometry's.
static void the_band_table_walk_is_the_geometry(void) {
    int ring_pixels = 0;
    for (int y = -10; y <= 208; y++)
        for (int x = -10; x <= 208; x++) {
            dfw_pixel c;
            ring_pixels += reference_pixel(0.0f, 0, x, y, &c);
        }
    static const struct { uint16_t length, from, to; } spans[] = { { 165, 0, 165 }, { 3600, 0, 60 }, { 3600, 3540, 3600 } };
    // Each look where the unit really shows it (#573: through messages and the clock, not a set field): normal while
    // paused on every second; steady red while playing with 31-60 s left; with 30 s or fewer, red at the time's
    // change and white half a second later.
    int off = 0, checked = 0;
    for (size_t s = 0; s < 3; s++)
        for (uint16_t e = spans[s].from; e <= spans[s].to; e++) {
            int left = spans[s].length - e;
            struct { uint8_t flags; uint32_t later; dfw_pixel fill; int shown; } looks[] = {
                { PAUSED, 0, 0xFF0000u, 1 },
                { PLAYING, 0, 0xFF3B30u, left <= 60 },
                { PLAYING, 600, 0xEDEDEAu, left <= 30 },
            };
            for (int l = 0; l < 3; l++) {
                if (!looks[l].shown) continue;
                with_time(DECK_2_RED_EMPTY, looks[l].flags, e, spans[s].length, looks[l].later);
                compare_log log = { 0, 0, (float)e / (float)spans[s].length, looks[l].fill };
                dfw_band_pixels(&unit, compare_put, &log);
                off += log.off + (log.count != ring_pixels);
                checked++;
            }
        }
    // 288 seconds paused, 122 with a minute or less left (red), 62 with 30 s or less (white).
    CHECK(ring_pixels > 2000 && checked == 472 && off == 0);
}

const test_case draw_band_tests[] = {
    { "the band table walk is the geometry", the_band_table_walk_is_the_geometry },
    { "a ring that goes leaves black", a_ring_that_goes_leaves_black },
    { "the band ring is the renderer's", the_band_ring_is_the_renderers },
    { "each band reference has the ring", each_band_reference_has_the_ring },
    { "no ring puts nothing", no_ring_puts_nothing },
    { "the band lands on the layer turned and in rgb565", the_band_lands_on_the_layer_turned_and_in_rgb565 },
    { "the frame draws the ring's corners", the_frame_draws_the_rings_corners },
    { "the band's clear leaves the frame's corners", the_bands_clear_leaves_the_frames_corners },
    { 0, 0 },
};
