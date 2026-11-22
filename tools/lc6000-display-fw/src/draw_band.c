// The progress ring in the panel's band outside the frame (#524), as JogDisplayRenderer.drawnImage draws it: r 103-107
// round the frame's center (99, 99 in the frame's pixels, a pixel's center at +0.5), a 0x4A4A4A track all round and the
// fill clockwise from 12 o'clock in the deck color, or the warning's red or white. Anti-aliased by coverage as
// draw_live.c is; its helpers are static there, so the few this needs are repeated here. No state of its own.
#include "draw_band.h"
#include "band_geometry.h"
#include "band_table.h"

/// sin and cos of `turns` (0-1) of a turn clockwise from 12 o'clock: folded to the nearest quarter turn, so the series
/// to the ninth power only sees up to an eighth of a turn, where it is within float precision.
static void turn_sin_cos(float turns, float *sin_out, float *cos_out) {
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

/// The ring as the unit has it: whether there is one, how far round its fill goes and in what color, and the end ray's
/// normal into the fill.
typedef struct { int on; float turns; dfw_pixel fill; float end_nx, end_ny; } ring_state;

static ring_state ring_of(const dfw_unit *unit) {
    ring_state ring = { 0, 0.0f, 0, 0.0f, 0.0f };
    if (!unit->drawn || unit->deck.number == 0 || dfw_stale(unit) || !unit->time_heard || unit->track_length == 0)
        return ring;
    uint16_t elapsed = unit->elapsed < unit->track_length ? unit->elapsed : unit->track_length;
    ring.on = 1;
    ring.turns = (float)elapsed / (float)unit->track_length;
    ring.fill = unit->time_look == DFW_TIME_RED ? WARNING_RED : unit->time_look == DFW_TIME_WHITE ? WARNING_WHITE
        : (dfw_pixel)unit->deck.r << 16 | (dfw_pixel)unit->deck.g << 8 | unit->deck.b;
    float sn, cs;
    turn_sin_cos(ring.turns, &sn, &cs);
    // Into the fill across the end's ray: counterclockwise of it.
    ring.end_nx = -cs;
    ring.end_ny = -sn;
    return ring;
}

/// The ring's color at one of the table's pixels (#558): the track and the band's cover come from the table, worked
/// out once; only the fill's end edge, which moves with the progress, is worked out here. The fill is the band on the
/// clockwise side of the 12 o'clock ray and before the end's: up to half a turn both half-planes (their covers' sum less
/// one), past it either (their sum). Swift draws no fill at 0 and the whole band, with no edge, at 1.
static dfw_pixel ring_color(const ring_state *ring, const dfw_band_entry *e) {
    dfw_pixel c = e->track;
    if (ring->turns > 0.0f) {
        float cover = 1.0f;
        if (ring->turns < 1.0f) {
            float dx = (float)e->x + 0.5f - CENTER, dy = (float)e->y + 0.5f - CENTER;
            // A pixel's center 0.75 px or more from the end's line is wholly on one side: edge_cover gives exactly 1
            // or 0 there (half its corner-to-corner reach is at most √2/2), so only the pixels on the line need it.
            float distance = dx * ring->end_nx + dy * ring->end_ny;
            float end = distance >= 0.75f ? 1.0f : distance <= -0.75f ? 0.0f
                : edge_cover(distance, ring->end_nx, ring->end_ny);
            cover = clamp01(ring->turns <= 0.5f ? e->start + end - 1.0f : e->start + end);
        }
        c = blend(c, ring->fill, e->band * cover);
    }
    return c;
}

void dfw_band_pixels(const dfw_unit *unit, dfw_put put, void *ctx) {
    ring_state ring = ring_of(unit);
    if (!ring.on) return;
    for (int i = 0; i < dfw_band_entries; i++) {
        const dfw_band_entry *e = &dfw_band_table[i];
        if (e->ring) put(ctx, e->x, e->y, ring_color(&ring, e));
    }
}


/// The band in the layer: every pixel of its clear annulus outside the square, once, with its final value (the ring, or
/// black where it doesn't reach), written only if the layer doesn't hold it already. So the visible layer never shows a
/// pixel between two values (#468: a clear pass turned the ring black on screen for the few ms the ring took to draw,
/// every present: the shimmer), and an unchanged ring writes nothing.
void dfw_band_layer(const dfw_unit *unit, const dfw_layer *layer) {
    ring_state ring = ring_of(unit);
    for (int i = 0; i < dfw_band_entries; i++) {
        const dfw_band_entry *e = &dfw_band_table[i];
        if (!e->layer) continue;
        int index = dfw_panel_index(e->x, e->y);
        if (index < 0) continue;
        uint16_t value = ring.on && e->ring ? dfw_rgb565(ring_color(&ring, e)) : 0;
        if (layer->read(layer->ctx, index) != value) layer->write(layer->ctx, index, value);
    }
}

/// The real layer's adapter: the only code that reads or writes the layer's pointer (#568).
static uint16_t memory_read(void *ctx, int index) { return ((const uint16_t *)ctx)[index]; }
static void memory_write(void *ctx, int index, uint16_t value) { ((uint16_t *)ctx)[index] = value; }

void dfw_draw_band(uint16_t *pixels, const dfw_unit *unit) {
    const dfw_layer layer = { memory_read, memory_write, pixels };
    dfw_band_layer(unit, &layer);
}
