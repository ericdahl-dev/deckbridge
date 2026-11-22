// The progress ring's geometry (#524, #558): the band's shape and its anti-aliasing, shared by the table generator
// (gen/band_table_gen.c, on the host) and draw_band.c (on the chip), so the table holds exactly what draw_band.c
// worked out per pixel before it had one. Float only, no libm.
#ifndef DFW_BAND_GEOMETRY_H
#define DFW_BAND_GEOMETRY_H
#include "dfw.h"
#include "layout_generated.h"
#include "geometry.h"
#include "panel_geometry.h"

#define CENTER DFW_CENTER
#define BAND_INNER DFW_BAND_INNER
#define BAND_OUTER DFW_BAND_OUTER
#define BAND_TRACK DFW_BAND_TRACK
/// Under the ring: the frame's ground inside the 198 square, the panel's black outside it.
#define GROUND DFW_GROUND
#define PANEL 0x000000u
/// The time's white (the blink's other half) and the warning's red, as draw_live.c's.
#define WARNING_WHITE DFW_WARNING_WHITE
#define WARNING_RED DFW_WARNING_RED
/// The band's reach either side, for the frame (x, y) loops: center ± (outer + 1).
#define REACH 109

/// The band's annulus as far as any of its pixels reach (r 102-108, with half a pixel to spare): every pixel of it
/// outside the square is the band's in the layer, black where the ring doesn't cover it.
#define CLEAR_INNER 101.5f
#define CLEAR_OUTER 108.5f


/// The frame's own square (panel_geometry.h).
static inline int in_frame(int x, int y) { return dfw_in_frame(x, y); }

/// The ring's shape at frame pixel (x, y), whatever its progress: how much of the pixel the band covers (0 when none),
/// how much lies clockwise of the 12 o'clock ray (the fill's start edge), and the track blended over what lies under it
/// there (the frame's ground in the square, the panel's black outside). Returns whether the band covers any of it.
static inline int band_shape(int x, int y, float *band, float *start, dfw_pixel *track) {
    float dx = (float)x + 0.5f - CENTER, dy = (float)y + 0.5f - CENTER;
    float d2 = dx * dx + dy * dy;
    *band = 0.0f;
    *start = 0.0f;
    *track = in_frame(x, y) ? GROUND : PANEL;
    if (d2 > (BAND_OUTER + 1.0f) * (BAND_OUTER + 1.0f) || d2 < (BAND_INNER - 1.0f) * (BAND_INNER - 1.0f)) return 0;
    float r = root(d2), nx = dx / r, ny = dy / r;
    float cover = edge_cover(BAND_OUTER - r, nx, ny) + edge_cover(r - BAND_INNER, nx, ny) - 1.0f;
    if (cover <= 0.0f) return 0;
    *band = cover;
    *start = edge_cover(dx, 1.0f, 0.0f);
    *track = blend(*track, BAND_TRACK, cover);
    return 1;
}

/// Whether frame pixel (x, y) is in the band's clear annulus: dfw_draw_band gives every one outside the square a value.
static inline int band_clear(int x, int y) {
    float dx = (float)x + 0.5f - CENTER, dy = (float)y + 0.5f - CENTER, d2 = dx * dx + dy * dy;
    return d2 >= CLEAR_INNER * CLEAR_INNER && d2 <= CLEAR_OUTER * CLEAR_OUTER;
}

#endif
