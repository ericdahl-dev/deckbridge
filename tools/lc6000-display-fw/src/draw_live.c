// The live elements (#459) as JogDisplayRenderer's simulator image draws them over design B, in its pixels: y down,
// (0, 0) the top-left corner, a pixel's center at +0.5. Anti-aliased by coverage as draw.c is; its helpers are static
// there, so the few this needs are repeated here.
#include "draw_live.h"
#include "layout_generated.h"
#include "geometry.h"
#include "draw_band.h"
#include "ring_table.h"

#define GROUND DFW_GROUND
#define LIVE DFW_LIVE
#define KEYLINE 0x000000u
#define MARKER 0xFFFFFFu

#define CENTER DFW_CENTER

/// Beat `beat`'s (1-4) section in the live green, from the ring's table (#558). Swift fills the lit section once over
/// the ground, so each pixel's color was worked out from the ground (src/ring_geometry.h), not over the unlit section
/// ring() left: that would leave the unlit color in its edges.
static void lit_section(dfw_pixel *frame, int beat) {
    for (int i = 0; i < dfw_ring_entries; i++) {
        const dfw_ring_entry *e = &dfw_ring_table[i];
        if (e->beat == beat) frame[e->index] = (dfw_pixel)e->lit_r << 16 | (dfw_pixel)e->lit_g << 8 | e->lit_b;
    }
}

/// sin and cos by their series to the ninth power: within float precision up to an eighth of a turn (π/4).
static void series_sin_cos(float a, float *s, float *c) {
    float a2 = a * a;
    *s = a * (1.0f - a2 / 6.0f * (1.0f - a2 / 20.0f * (1.0f - a2 / 42.0f * (1.0f - a2 / 72.0f))));
    *c = 1.0f - a2 / 2.0f * (1.0f - a2 / 12.0f * (1.0f - a2 / 30.0f * (1.0f - a2 / 56.0f)));
}

/// sin and cos of the needle's angle, `needle` sixteen-thousandths (16384ths) of a turn clockwise from 12 o'clock.
/// Folded to the nearest quarter turn, so the series only sees up to an eighth of a turn (π/4), where its terms to
/// the ninth power are within float precision.
static void needle_sin_cos(uint16_t needle, float *sin_out, float *cos_out) {
    int quarter = ((int)(needle & 0x3FFF) + 2048) / 4096;
    float a = (float)((int)(needle & 0x3FFF) - quarter * 4096) * 3.8349519697e-4f;   // 2π / 16384
    float s, c;
    series_sin_cos(a, &s, &c);
    switch (quarter & 3) {
    case 0: *sin_out = s; *cos_out = c; break;
    case 1: *sin_out = c; *cos_out = -s; break;
    case 2: *sin_out = -s; *cos_out = -c; break;
    default: *sin_out = -c; *cos_out = s; break;
    }
}

/// The marker's corners in its own frame: u out from the center along the needle, v clockwise across it. The tip is
/// 6 px inside the ring (85 − 6), and the base corners 4.2° either side at radius 98.5, as Swift's drawMarker.
static const float tip_u = 79.0f, base_u = 98.235476f, base_v = 7.2139624f;
/// Swift strokes the triangle with a 2 px keyline (round joins) and then fills it.
#define KEYLINE_WIDTH 2.0f

/// The distance from (u, v) to the segment from (au, av) to (bu, bv), and the direction from its nearest point.
static float segment_distance(float u, float v, float au, float av, float bu, float bv, float *wu, float *wv) {
    float eu = bu - au, ev = bv - av;
    float t = ((u - au) * eu + (v - av) * ev) / (eu * eu + ev * ev);
    t = clamp01(t);
    *wu = u - (au + t * eu);
    *wv = v - (av + t * ev);
    return root(*wu * *wu + *wv * *wv);
}

/// The area of a triangle inside the pixel square [x, x + 1] × [y, y + 1]: the triangle clipped to each of the square's
/// four sides in turn (Sutherland–Hodgman), then the shoelace formula. Exact, where a product of edge covers is not:
/// at the marker's 41° tip that product is twice the true area.
static float triangle_in_pixel(const float *tx, const float *ty, float x, float y) {
    float px[2][8], py[2][8];
    int n = 3, from = 0;
    for (int i = 0; i < 3; i++) { px[0][i] = tx[i]; py[0][i] = ty[i]; }
    for (int side = 0; side < 4 && n > 0; side++) {
        int to = 1 - from, m = 0;
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            float ax = px[from][i], ay = py[from][i], bx = px[from][j], by = py[from][j];
            // How far inside this side each end is: x ≥ left, x ≤ right, y ≥ top, y ≤ bottom.
            float da = side == 0 ? ax - x : side == 1 ? x + 1.0f - ax : side == 2 ? ay - y : y + 1.0f - ay;
            float db = side == 0 ? bx - x : side == 1 ? x + 1.0f - bx : side == 2 ? by - y : y + 1.0f - by;
            if (da >= 0.0f && m < 8) { px[to][m] = ax; py[to][m] = ay; m++; }
            if ((da >= 0.0f) != (db >= 0.0f) && m < 8) {
                float t = da / (da - db);
                px[to][m] = ax + t * (bx - ax);
                py[to][m] = ay + t * (by - ay);
                m++;
            }
        }
        n = m;
        from = to;
    }
    float area = 0.0f;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        area += px[from][i] * py[from][j] - px[from][j] * py[from][i];
    }
    return clamp01((area < 0.0f ? -area : area) / 2.0f);
}

/// The marker as Swift draws it: a white wedge riding the ring's edge, pointing in, with a black 2 px keyline. Each
/// pixel's signed distance to the triangle (positive outside) gives the keyline's band (within 1 px of the edge,
/// rounded at the corners as the round joins are); the fill is the triangle's exact area in the pixel. Keyline, then
/// fill.
static void marker(dfw_pixel *frame, uint16_t needle) {
    float sn, cs;
    needle_sin_cos(needle, &sn, &cs);
    // On screen (y down), u runs along (sin, −cos) and v along (cos, sin).
    const float corner_u[3] = { tip_u, base_u, base_u }, corner_v[3] = { 0.0f, -base_v, base_v };
    float left = (float)DFW_SIZE, right = 0.0f, top = (float)DFW_SIZE, bottom = 0.0f, corner_x[3], corner_y[3];
    for (int i = 0; i < 3; i++) {
        float x = CENTER + corner_u[i] * sn + corner_v[i] * cs, y = CENTER - corner_u[i] * cs + corner_v[i] * sn;
        corner_x[i] = x;
        corner_y[i] = y;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
    }
    const float reach = KEYLINE_WIDTH / 2.0f + 1.0f;
    int x0 = (int)(left - reach), x1 = (int)(right + reach) + 1, y0 = (int)(top - reach), y1 = (int)(bottom + reach) + 1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > DFW_SIZE) x1 = DFW_SIZE;
    if (y1 > DFW_SIZE) y1 = DFW_SIZE;
    for (int y = y0; y < y1; y++) {
        float dy = (float)y + 0.5f - CENTER;
        for (int x = x0; x < x1; x++) {
            float dx = (float)x + 0.5f - CENTER;
            float u = dx * sn - dy * cs, v = dx * cs + dy * sn;
            float distance = 1e9f, wu = 1.0f, wv = 0.0f, fill = 1.0f;
            int inside = 1;
            for (int i = 0; i < 3; i++) {
                int j = (i + 1) % 3;
                float eu, ev;
                float d = segment_distance(u, v, corner_u[i], corner_v[i], corner_u[j], corner_v[j], &eu, &ev);
                if (d < distance) { distance = d; wu = eu; wv = ev; }
                // The corners run counterclockwise in (u, v): inside is to the left of every edge.
                float lu = corner_u[j] - corner_u[i], lv = corner_v[j] - corner_v[i], l = root(lu * lu + lv * lv);
                float cross = (lu * (v - corner_v[i]) - lv * (u - corner_u[i])) / l;
                if (cross < 0.0f) inside = 0;
                // Whether the pixel is wholly inside or outside the fill: each edge's cover, by its inward normal.
                float mu = -lv / l, mv = lu / l;
                fill *= edge_cover(cross, mu * sn + mv * cs, -mu * cs + mv * sn);
            }
            // On an edge, the exact area: a distance field would round the corners that CoreGraphics fills sharp.
            if (fill > 0.0f && fill < 1.0f) fill = triangle_in_pixel(corner_x, corner_y, (float)x, (float)y);
            float signed_distance = inside ? -distance : distance;
            // The direction the distance is measured in, on screen; on the edge itself any will do.
            float length = root(wu * wu + wv * wv);
            float nx = 1.0f, ny = 0.0f;
            if (length > 1e-4f) {
                wu /= length;
                wv /= length;
                nx = wu * sn + wv * cs;
                ny = -wu * cs + wv * sn;
            }
            float half = KEYLINE_WIDTH / 2.0f;
            float keyline = edge_cover(half - signed_distance, nx, ny) + edge_cover(half + signed_distance, nx, ny) - 1.0f;
            dfw_pixel *p = &frame[y * DFW_SIZE + x];
            *p = blend(*p, KEYLINE, keyline);
            *p = blend(*p, MARKER, fill);
        }
    }
}

/// The level meter (#461), Swift's drawMeter: the band 80-83 from 240° (the bottom, fraction 0) to 300° (the top,
/// fraction 1) clockwise from 12 o'clock.
#define METER_INNER DFW_METER_INNER
#define METER_OUTER DFW_METER_OUTER
#define METER_TRACK DFW_BEAT_OFF
#define METER_YELLOW DFW_METER_YELLOW
#define METER_PEAK DFW_METER_PEAK
/// Clip (127): the whole fill, and a tick held there.
#define METER_CLIP DFW_WARNING_RED
/// Where the fill turns from green to yellow, as a fraction of the arc.
#define METER_YELLOW_FROM 0.75f
/// The peak tick's half width, as a fraction of the arc: 1° of the 60°.
#define METER_TICK_HALF (1.0f / 60.0f)
/// cos 30°: the arc's ends are 30° either side of 9 o'clock.
#define COS_30 0.8660254f

/// A stretch of the arc, from fraction `from` to `to`, in one color: its two radial edges as normals pointing into it.
typedef struct { float start_nx, start_ny, end_nx, end_ny; dfw_pixel color; } meter_sector;

static meter_sector sector(float from, float to, dfw_pixel color) {
    // Measured from 9 o'clock (270°), so the series sees at most 30°: a point at φ is (−cos φ, −sin φ) from the
    // center, and clockwise from it is (sin φ, −cos φ).
    const float third_pi = 1.0471976f;
    float s0, c0, s1, c1;
    series_sin_cos((from - 0.5f) * third_pi, &s0, &c0);
    series_sin_cos((to - 0.5f) * third_pi, &s1, &c1);
    return (meter_sector){ s0, -c0, -s1, c1, color };
}

/// Fills each sector over the ones before it, as CoreGraphics fills each path over the last: in a pixel on an edge,
/// the later color is blended over the earlier. Only the arc's bounding box is visited, about 15 × 85 pixels.
static void meter(dfw_pixel *frame, const meter_sector *sectors, int count) {
    int x0 = (int)(CENTER - METER_OUTER - 1.0f), x1 = (int)(CENTER - METER_INNER * COS_30) + 2;
    int y0 = (int)(CENTER - METER_OUTER / 2.0f - 1.0f), y1 = (int)(CENTER + METER_OUTER / 2.0f + 1.0f) + 1;
    for (int y = y0; y < y1; y++) {
        float dy = (float)y + 0.5f - CENTER;
        for (int x = x0; x < x1; x++) {
            float dx = (float)x + 0.5f - CENTER;
            float d2 = dx * dx + dy * dy;
            if (d2 > (METER_OUTER + 1.0f) * (METER_OUTER + 1.0f) || d2 < (METER_INNER - 1.0f) * (METER_INNER - 1.0f))
                continue;
            float r = root(d2), nx = dx / r, ny = dy / r;
            float band = edge_cover(METER_OUTER - r, nx, ny) + edge_cover(r - METER_INNER, nx, ny) - 1.0f;
            if (band <= 0.0f) continue;
            dfw_pixel *p = &frame[y * DFW_SIZE + x];
            for (int i = 0; i < count; i++) {
                const meter_sector *m = &sectors[i];
                // Inside both edges: the sum less one, not the product, so a sliver under a pixel wide isn't
                // over-covered.
                float cover = edge_cover(dx * m->start_nx + dy * m->start_ny, m->start_nx, m->start_ny)
                    + edge_cover(dx * m->end_nx + dy * m->end_ny, m->end_nx, m->end_ny) - 1.0f;
                if (cover > 0.0f) *p = blend(*p, m->color, band * cover);
            }
        }
    }
}

/// The meter's sectors for a level and a held peak, 0-127 each, in the order Swift fills them.
static void draw_meter(dfw_pixel *frame, uint8_t level, uint8_t peak) {
    meter_sector sectors[4];
    int count = 0;
    sectors[count++] = sector(0.0f, 1.0f, METER_TRACK);
    if (level > 127) level = 127;
    if (peak > 127) peak = 127;
    float fill = (float)level / 127.0f;
    if (level == 127) {
        sectors[count++] = sector(0.0f, 1.0f, METER_CLIP);
    } else if (level > 0) {
        sectors[count++] = sector(0.0f, fill < METER_YELLOW_FROM ? fill : METER_YELLOW_FROM, LIVE);
        if (fill > METER_YELLOW_FROM) sectors[count++] = sector(METER_YELLOW_FROM, fill, METER_YELLOW);
    }
    if (peak > 0) {
        // The tick kept inside the arc.
        float place = (float)peak / 127.0f;
        if (place < METER_TICK_HALF) place = METER_TICK_HALF;
        if (place > 1.0f - METER_TICK_HALF) place = 1.0f - METER_TICK_HALF;
        sectors[count++] = sector(place - METER_TICK_HALF, place + METER_TICK_HALF,
                                   peak == 127 ? METER_CLIP : METER_PEAK);
    }
    meter(frame, sectors, count);
}

/// The time's text, the renderer's text white.
#define TIME_TEXT DFW_TEXT

/// The ring's pixels that fall in the frame (#524): the band crosses the 198 square at its diagonals, and the layer's
/// band leaves the square to the frame.
static void frame_put(void *ctx, int x, int y, dfw_pixel color) {
    if (x >= 0 && x < DFW_SIZE && y >= 0 && y < DFW_SIZE) ((dfw_pixel *)ctx)[y * DFW_SIZE + x] = color;
}

/// The track time: nothing until a time message has come, or while the length is unknown (0).
static void draw_time(dfw_pixel *frame, const dfw_unit *unit) {
    if (!unit->time_heard || unit->track_length == 0) return;
    uint16_t elapsed = unit->elapsed < unit->track_length ? unit->elapsed : unit->track_length;
    // What's left as "-m:ss", minutes not wrapped to hours: up to "-273:03" from the wire's 16383 s.
    unsigned left = (unsigned)(unit->track_length - elapsed), minutes = left / 60u, seconds = left % 60u;
    char text[8], *p = text;
    *p++ = '-';
    if (minutes >= 100u) *p++ = (char)('0' + minutes / 100u);
    if (minutes >= 10u) *p++ = (char)('0' + minutes / 10u % 10u);
    *p++ = (char)('0' + minutes % 10u);
    *p++ = ':';
    *p++ = (char)('0' + seconds / 10u);
    *p++ = (char)('0' + seconds % 10u);
    *p = 0;
    dfw_draw_time_text(frame, text, unit->time_look == DFW_TIME_RED);
}

void dfw_draw_live(dfw_pixel *frame, const dfw_unit *unit) {
    if (dfw_stale(unit)) return;
    if (unit->beat >= 1 && unit->beat <= 4) lit_section(frame, unit->beat);
    if (unit->meter_heard) draw_meter(frame, unit->level, unit->peak);
    draw_time(frame, unit);
    if (unit->needle_heard) marker(frame, unit->needle);
    // The progress ring is in the band outside the frame now (#524), drawn after it as drawnImage does; only its
    // corners reach in here, where nothing else is drawn.
    dfw_band_pixels(unit, frame_put, frame);
}
