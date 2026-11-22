// The beat ring's geometry (#558): draw.c's ring() and draw_live.c's lit_section(), moved here verbatim (each pixel it
// writes also marked in `touched`), for the table generator (gen/ring_table_gen.c) on the host. On the chip the ring is
// drawn from the table, src/ring_table.c. Float only, no libm.
#ifndef DFW_RING_GEOMETRY_H
#define DFW_RING_GEOMETRY_H
#include "band_geometry.h"
#include "layout_generated.h"

#define RING_OUTER DFW_RING_OUTER
#define RING_INNER DFW_RING_INNER
/// The gap between beat sections, measured at mid-band.
#define RING_GAP DFW_RING_GAP
#define DOWNBEAT_OFF DFW_DOWNBEAT_OFF
#define BEAT_OFF DFW_BEAT_OFF
#define LIVE DFW_LIVE

/// sin and cos of a small angle by their series; ample for the ring's half gap (0.04 rad).
static inline void small_sin_cos(float a, float *s, float *c) {
    float a2 = a * a;
    *s = a * (1.0f - a2 / 6.0f * (1.0f - a2 / 20.0f));
    *c = 1.0f - a2 / 2.0f * (1.0f - a2 / 12.0f);
}

/// The four beat sections, clockwise from 12 o'clock, beat 1 a step brighter. Angles run from 12 o'clock clockwise,
/// which on screen (y down) is the direction (sin a, −cos a), and clockwise from it is (cos a, sin a). Each section is
/// under half a turn, so it is the band between the two radii cut by two half-planes through the center.
static inline void ring_geometry(dfw_pixel *frame, int all_dark, uint8_t *touched) {
    float s, c;
    small_sin_cos(RING_GAP / ((RING_OUTER + RING_INNER) / 2.0f) / 2.0f, &s, &c);
    // Beat 1's edges, at half and π/2 − half, as normals pointing into the section.
    const float start_nx = c, start_ny = s, end_nx = -s, end_ny = -c;
    for (int y = 0; y < DFW_SIZE; y++) {
        float dy = (float)y + 0.5f - CENTER;
        for (int x = 0; x < DFW_SIZE; x++) {
            float dx = (float)x + 0.5f - CENTER;
            float d2 = dx * dx + dy * dy;
            if (d2 > (RING_OUTER + 1.0f) * (RING_OUTER + 1.0f) || d2 < (RING_INNER - 1.0f) * (RING_INNER - 1.0f)) continue;
            float r = root(d2);
            float nx = r > 0.0f ? dx / r : 1.0f, ny = r > 0.0f ? dy / r : 0.0f;
            float band = edge_cover(RING_OUTER - r, nx, ny) + edge_cover(r - RING_INNER, nx, ny) - 1.0f;
            if (band <= 0.0f) continue;
            // Each step turns the point a quarter turn back, so beat b's section lands where beat 1's is.
            float px = dx, py = dy;
            for (int beat = 0; beat < 4; beat++) {
                // The edge normals turn with the point, so they are taken in its turned frame.
                float cover = band * edge_cover(px * start_nx + py * start_ny, start_nx, start_ny)
                    * edge_cover(px * end_nx + py * end_ny, end_nx, end_ny);
                dfw_pixel *p = &frame[y * DFW_SIZE + x];
                touched[y * DFW_SIZE + x] = 1;
                *p = blend(*p, beat == 0 && !all_dark ? DOWNBEAT_OFF : BEAT_OFF, cover);
                float t = px;
                px = py;
                py = -t;
            }
        }
    }
}

/// Beat `beat`'s (1-4) section in the live green. Swift fills the lit section once over the ground, so it is drawn
/// from the ground here too, not over the unlit section ring() left: that would leave the unlit color in its edges.
/// The sections and the ground are all there is in the band, so the result is Swift's.
static inline void lit_geometry(dfw_pixel *frame, int beat, uint8_t *touched) {
    float s, c;
    small_sin_cos(RING_GAP / ((RING_OUTER + RING_INNER) / 2.0f) / 2.0f, &s, &c);
    // Beat 1's edges, as normals pointing into the section (see draw.c's ring()).
    const float start_nx = c, start_ny = s, end_nx = -s, end_ny = -c;
    for (int y = 0; y < DFW_SIZE; y++) {
        float dy = (float)y + 0.5f - CENTER;
        for (int x = 0; x < DFW_SIZE; x++) {
            float dx = (float)x + 0.5f - CENTER;
            float d2 = dx * dx + dy * dy;
            if (d2 > (RING_OUTER + 1.0f) * (RING_OUTER + 1.0f) || d2 < (RING_INNER - 1.0f) * (RING_INNER - 1.0f)) continue;
            float r = root(d2);
            float nx = r > 0.0f ? dx / r : 1.0f, ny = r > 0.0f ? dy / r : 0.0f;
            float band = edge_cover(RING_OUTER - r, nx, ny) + edge_cover(r - RING_INNER, nx, ny) - 1.0f;
            if (band <= 0.0f) continue;
            // A quarter turn back per beat after the first lands the point where beat 1's section is.
            float px = dx, py = dy;
            for (int step = 1; step < beat; step++) {
                float t = px;
                px = py;
                py = -t;
            }
            float cover = band * edge_cover(px * start_nx + py * start_ny, start_nx, start_ny)
                * edge_cover(px * end_nx + py * end_ny, end_nx, end_ny);
            if (cover > 0.0f) {
                frame[y * DFW_SIZE + x] = blend(GROUND, LIVE, cover);
                touched[y * DFW_SIZE + x] = 1;
            }
        }
    }
}

#endif
