// Design B (#165) as JogDisplayRenderer draws it, measured in its pixels: y down, (0, 0) the top-left corner, a pixel's
// center at +0.5. Edges are anti-aliased by coverage: a pixel is blended toward a shape by how much of it the shape
// covers, estimated from the signed distance between the pixel's center and the shape's edge.
#include "draw.h"
#include "layout_generated.h"
#include "geometry.h"
#include "text.h"
#include "draw_live.h"
#include "font_header.h"
#include "ring_table.h"

#define GROUND DFW_GROUND
/// The time left (#460, #524): centered on x 99, its line box's middle at y 160 (drawn mode's layout).
#define TIME_CENTER_X DFW_CENTER
#define TIME_MIDDLE DFW_TIME_CENTER_Y

#define CENTER DFW_CENTER

/// The four beat sections, clockwise from 12 o'clock, beat 1 a step brighter; or all dark, the waiting look. From the
/// ring's table (#558): each pixel's gray, worked out once by the same geometry (src/ring_geometry.h) over the ground,
/// which is all there is under the ring when it is drawn.
static void ring(dfw_pixel *frame, int all_dark) {
    for (int i = 0; i < dfw_ring_entries; i++) {
        const dfw_ring_entry *e = &dfw_ring_table[i];
        dfw_pixel level = all_dark ? e->dark : e->normal;
        frame[e->index] = level << 16 | level << 8 | level;
    }
}

/// Rounds down; the coordinates drawn are within the frame, well inside int range.
static int floor_int(float x) {
    if (x < -1000.0f) x = -1000.0f;
    if (x > 1000.0f) x = 1000.0f;
    int i = (int)x;
    return (float)i > x ? i - 1 : i;
}

static const dfw_glyph *glyph(const dfw_face *face, char code) {
    for (uint8_t i = 0; i < face->count; i++)
        if (face->glyphs[i].code == code) return &face->glyphs[i];
    return 0;
}

/// A glyph's coverage blended in the face's ink, with its origin at x on the face's baseline row. CoreText snaps the
/// origin down to 1/phases of a pixel; the bitmaps are kept at each of those phases.
static void draw_glyph(dfw_pixel *frame, const dfw_face *face, const dfw_glyph *g, float x, int baseline_row) {
    int whole = floor_int(x);
    int phase = floor_int((x - (float)whole) * (float)face->phases);
    if (phase < 0) phase = 0;
    if (phase >= face->phases || phase >= DFW_PHASES_MAX) phase = face->phases - 1;
    const dfw_glyph_bitmap *b = &g->phase[phase];
    if (!b->coverage) return;
    int left = whole + b->left, top = baseline_row + b->top;
    for (int row = 0; row < b->height; row++) {
        int y = top + row;
        if (y < 0 || y >= DFW_SIZE) continue;
        for (int col = 0; col < b->width; col++) {
            int px = left + col;
            if (px < 0 || px >= DFW_SIZE) continue;
            dfw_pixel *p = &frame[y * DFW_SIZE + px];
            *p = blend(*p, face->ink, (float)b->coverage[row * b->width + col] / 255.0f);
        }
    }
}

/// The face's baseline row for a line whose box is centered on `middle`, as the renderer centers it. The bitmaps were
/// rasterized at the fraction the header's middles give.
static int baseline_row(const dfw_face *face, float middle) {
    return floor_int(middle + (face->ascent - face->descent) / 2.0f);
}

/// A filled circle, anti-aliased.
static void disc(dfw_pixel *frame, float cx, float cy, float radius, dfw_pixel color) {
    for (int y = floor_int(cy - radius - 1.0f); y <= floor_int(cy + radius + 1.0f); y++) {
        if (y < 0 || y >= DFW_SIZE) continue;
        float dy = (float)y + 0.5f - cy;
        for (int x = floor_int(cx - radius - 1.0f); x <= floor_int(cx + radius + 1.0f); x++) {
            if (x < 0 || x >= DFW_SIZE) continue;
            float dx = (float)x + 0.5f - cx;
            dfw_pixel *p = &frame[y * DFW_SIZE + x];
            float r = root(dx * dx + dy * dy);
            float cover = r > 0.0f ? edge_cover(radius - r, dx / r, dy / r) : 1.0f;
            *p = blend(*p, color, cover);
        }
    }
}

/// A rounded rectangle's outline, `width` wide, centered on the path through (x, y, w, h) with corner radius `radius`.
/// Coverage comes from the signed distance to the path and the direction it is measured in.
static void rounded_outline(dfw_pixel *frame, float x, float y, float w, float h, float radius, float width,
                            dfw_pixel color) {
    float cx = x + w / 2.0f, cy = y + h / 2.0f, hx = w / 2.0f - radius, hy = h / 2.0f - radius;
    for (int py = floor_int(y - width - 1.0f); py <= floor_int(y + h + width + 1.0f); py++) {
        if (py < 0 || py >= DFW_SIZE) continue;
        for (int px = floor_int(x - width - 1.0f); px <= floor_int(x + w + width + 1.0f); px++) {
            if (px < 0 || px >= DFW_SIZE) continue;
            float dx = (float)px + 0.5f - cx, dy = (float)py + 0.5f - cy;
            float qx = (dx < 0.0f ? -dx : dx) - hx, qy = (dy < 0.0f ? -dy : dy) - hy;
            float d, nx, ny;
            if (qx > 0.0f && qy > 0.0f) {
                // Beside a corner: the distance to its arc, along the line from the arc's center.
                float r = root(qx * qx + qy * qy);
                d = r - radius;
                nx = qx / r;
                ny = qy / r;
            } else if (qx > qy) {
                d = qx - radius;
                nx = 1.0f;
                ny = 0.0f;
            } else {
                d = qy - radius;
                nx = 0.0f;
                ny = 1.0f;
            }
            float cover = edge_cover(width / 2.0f - d, nx, ny) + edge_cover(width / 2.0f + d, nx, ny) - 1.0f;
            dfw_pixel *p = &frame[py * DFW_SIZE + px];
            *p = blend(*p, color, cover);
        }
    }
}

/// A line's width as CoreText lays it out: each glyph's advance plus the tracking, the last one's too.
static float line_width(const dfw_face *face, const char *text) {
    float width = 0.0f;
    for (int i = 0; text[i] && i < 8; i++) {
        const dfw_glyph *g = glyph(face, text[i]);
        if (g) width += g->advance + face->tracking;
    }
    return width;
}

static void draw_line(dfw_pixel *frame, const dfw_face *face, const char *text, float x, float middle) {
    int row = baseline_row(face, middle);
    for (int i = 0; text[i] && i < 8; i++) {
        const dfw_glyph *g = glyph(face, text[i]);
        if (!g) continue;
        draw_glyph(frame, face, g, x, row);
        x += g->advance + face->tracking;
    }
}

void dfw_draw_time_text(dfw_pixel *frame, const char *text, int warning_red) {
    const dfw_face *face = warning_red ? &time_red_face : &time_face;
    draw_line(frame, face, text, TIME_CENTER_X - line_width(face, text) / 2.0f, TIME_MIDDLE);
}

#define CHIP 26.0f
#define BADGE_GAP 6.0f
#define BADGE_HEIGHT 22.0f
#define BADGE_PADDING 15.0f
#define BADGE_STROKE 1.5f
#define BADGE_CORNER 4.25f
#define BADGE_OUTLINE 0xBDBDBDu
#define HEADER_MIDDLE 37.0f

/// Each sRGB channel value linearized, c/255 as WCAG has it: c/12.92 up to 0.04045, else ((c + 0.055)/1.055)^2.4.
/// Worked out off the chip (no libm here), each to float precision; test_draw.c checks every entry against the formula.
const float dfw_linear_channel[256] = {
    0.000000000e+00f, 3.035269835e-04f, 6.070539671e-04f, 9.105809506e-04f, 1.214107934e-03f, 1.517634918e-03f, 1.821161901e-03f, 2.124688885e-03f,
    2.428215868e-03f, 2.731742852e-03f, 3.035269835e-03f, 3.346535764e-03f, 3.676507324e-03f, 4.024717018e-03f, 4.391442037e-03f, 4.776953481e-03f,
    5.181516702e-03f, 5.605391624e-03f, 6.048833023e-03f, 6.512090793e-03f, 6.995410187e-03f, 7.499032043e-03f, 8.023192985e-03f, 8.568125618e-03f,
    9.134058702e-03f, 9.721217320e-03f, 1.032982303e-02f, 1.096009401e-02f, 1.161224518e-02f, 1.228648836e-02f, 1.298303234e-02f, 1.370208305e-02f,
    1.444384360e-02f, 1.520851442e-02f, 1.599629337e-02f, 1.680737575e-02f, 1.764195449e-02f, 1.850022013e-02f, 1.938236096e-02f, 2.028856306e-02f,
    2.121901038e-02f, 2.217388479e-02f, 2.315336618e-02f, 2.415763245e-02f, 2.518685963e-02f, 2.624122189e-02f, 2.732089164e-02f, 2.842603950e-02f,
    2.955683444e-02f, 3.071344373e-02f, 3.189603307e-02f, 3.310476657e-02f, 3.433980681e-02f, 3.560131488e-02f, 3.688945040e-02f, 3.820437160e-02f,
    3.954623528e-02f, 4.091519691e-02f, 4.231141062e-02f, 4.373502926e-02f, 4.518620439e-02f, 4.666508634e-02f, 4.817182423e-02f, 4.970656598e-02f,
    5.126945837e-02f, 5.286064702e-02f, 5.448027644e-02f, 5.612849005e-02f, 5.780543019e-02f, 5.951123816e-02f, 6.124605423e-02f, 6.301001765e-02f,
    6.480326669e-02f, 6.662593864e-02f, 6.847816984e-02f, 7.036009570e-02f, 7.227185068e-02f, 7.421356838e-02f, 7.618538148e-02f, 7.818742181e-02f,
    8.021982031e-02f, 8.228270713e-02f, 8.437621154e-02f, 8.650046204e-02f, 8.865558629e-02f, 9.084171118e-02f, 9.305896285e-02f, 9.530746663e-02f,
    9.758734714e-02f, 9.989872825e-02f, 1.022417331e-01f, 1.046164841e-01f, 1.070231030e-01f, 1.094617108e-01f, 1.119324278e-01f, 1.144353738e-01f,
    1.169706678e-01f, 1.195384280e-01f, 1.221387722e-01f, 1.247718176e-01f, 1.274376804e-01f, 1.301364767e-01f, 1.328683216e-01f, 1.356333297e-01f,
    1.384316150e-01f, 1.412632911e-01f, 1.441284709e-01f, 1.470272665e-01f, 1.499597898e-01f, 1.529261520e-01f, 1.559264637e-01f, 1.589608351e-01f,
    1.620293756e-01f, 1.651321945e-01f, 1.682694002e-01f, 1.714411007e-01f, 1.746474037e-01f, 1.778884160e-01f, 1.811642442e-01f, 1.844749945e-01f,
    1.878207723e-01f, 1.912016827e-01f, 1.946178304e-01f, 1.980693196e-01f, 2.015562538e-01f, 2.050787364e-01f, 2.086368701e-01f, 2.122307574e-01f,
    2.158605001e-01f, 2.195261997e-01f, 2.232279573e-01f, 2.269658735e-01f, 2.307400485e-01f, 2.345505822e-01f, 2.383975738e-01f, 2.422811225e-01f,
    2.462013267e-01f, 2.501582847e-01f, 2.541520943e-01f, 2.581828529e-01f, 2.622506575e-01f, 2.663556048e-01f, 2.704977910e-01f, 2.746773121e-01f,
    2.788942635e-01f, 2.831487404e-01f, 2.874408377e-01f, 2.917706498e-01f, 2.961382708e-01f, 3.005437944e-01f, 3.049873141e-01f, 3.094689228e-01f,
    3.139887134e-01f, 3.185467781e-01f, 3.231432091e-01f, 3.277780981e-01f, 3.324515363e-01f, 3.371636150e-01f, 3.419144249e-01f, 3.467040564e-01f,
    3.515325995e-01f, 3.564001441e-01f, 3.613067798e-01f, 3.662525956e-01f, 3.712376805e-01f, 3.762621230e-01f, 3.813260114e-01f, 3.864294338e-01f,
    3.915724777e-01f, 3.967552307e-01f, 4.019777798e-01f, 4.072402119e-01f, 4.125426135e-01f, 4.178850708e-01f, 4.232676700e-01f, 4.286904966e-01f,
    4.341536362e-01f, 4.396571738e-01f, 4.452011945e-01f, 4.507857828e-01f, 4.564110232e-01f, 4.620769997e-01f, 4.677837961e-01f, 4.735314961e-01f,
    4.793201831e-01f, 4.851499401e-01f, 4.910208498e-01f, 4.969329951e-01f, 5.028864580e-01f, 5.088813209e-01f, 5.149176654e-01f, 5.209955732e-01f,
    5.271151257e-01f, 5.332764040e-01f, 5.394794890e-01f, 5.457244614e-01f, 5.520114015e-01f, 5.583403896e-01f, 5.647115057e-01f, 5.711248295e-01f,
    5.775804404e-01f, 5.840784179e-01f, 5.906188409e-01f, 5.972017884e-01f, 6.038273389e-01f, 6.104955708e-01f, 6.172065624e-01f, 6.239603917e-01f,
    6.307571363e-01f, 6.375968740e-01f, 6.444796820e-01f, 6.514056374e-01f, 6.583748173e-01f, 6.653872983e-01f, 6.724431570e-01f, 6.795424696e-01f,
    6.866853124e-01f, 6.938717613e-01f, 7.011018919e-01f, 7.083757799e-01f, 7.156935005e-01f, 7.230551289e-01f, 7.304607401e-01f, 7.379104088e-01f,
    7.454042095e-01f, 7.529422168e-01f, 7.605245047e-01f, 7.681511472e-01f, 7.758222183e-01f, 7.835377915e-01f, 7.912979403e-01f, 7.991027380e-01f,
    8.069522577e-01f, 8.148465722e-01f, 8.227857544e-01f, 8.307698768e-01f, 8.387990117e-01f, 8.468732315e-01f, 8.549926081e-01f, 8.631572135e-01f,
    8.713671192e-01f, 8.796223969e-01f, 8.879231179e-01f, 8.962693534e-01f, 9.046611744e-01f, 9.130986518e-01f, 9.215818563e-01f, 9.301108584e-01f,
    9.386857285e-01f, 9.473065367e-01f, 9.559733532e-01f, 9.646862479e-01f, 9.734452904e-01f, 9.822505503e-01f, 9.911020971e-01f, 1.000000000e+00f,
};

/// The deck number's face on its deck color (#542 follow-up, DeckNumberInk): the text white (its own glyphs: light text
/// is drawn heavier) when the color's relative luminance is under 0.1791, where white contrasts more than black; the
/// ground's black otherwise.
#define NUMBER_WHITE_BELOW DFW_NUMBER_WHITE_BELOW

static const dfw_face *number_ink(const dfw_deck_state *deck) {
    float luminance = 0.2126f * dfw_linear_channel[deck->r] + 0.7152f * dfw_linear_channel[deck->g] +
                      0.0722f * dfw_linear_channel[deck->b];
    return luminance < NUMBER_WHITE_BELOW ? &number_white_face : &number_face;
}

/// The player badge for each player (#209): none for empty (0) and other (5), whose name the deck message doesn't carry.
static const char *const badges[] = { 0, "TRK", "OSC", "MIDI", "SEQ", 0 };

/// The deck chip (a 26 px circle in the deck color, the number in the ground color) and the player badge, centered
/// together at y 37. The badge is its label in a 1.5 px outline, 22 px tall, 6 px after the chip.
static void header(dfw_pixel *frame, const dfw_deck_state *deck) {
    const char *label = deck->player < sizeof badges / sizeof badges[0] ? badges[deck->player] : 0;
    float text = label ? line_width(&badge_face, label) : 0.0f, badge = text + BADGE_PADDING;
    float left = CENTER - (CHIP + (label ? BADGE_GAP + badge : 0.0f)) / 2.0f;
    dfw_pixel color = (dfw_pixel)deck->r << 16 | (dfw_pixel)deck->g << 8 | deck->b;
    disc(frame, left + CHIP / 2.0f, HEADER_MIDDLE, CHIP / 2.0f, color);
    // A number outside 1-4 has no glyph: the chip alone.
    const dfw_face *ink = number_ink(deck);
    const dfw_glyph *number = glyph(ink, (char)('0' + (deck->number <= 9 ? deck->number : 0)));
    if (number && deck->number >= 1 && deck->number <= 4)
        draw_glyph(frame, ink, number, left + CHIP / 2.0f - number->advance / 2.0f,
                   baseline_row(&number_face, HEADER_MIDDLE));
    if (!label) return;
    float inset = BADGE_STROKE / 2.0f, x = left + CHIP + BADGE_GAP;
    rounded_outline(frame, x + inset, HEADER_MIDDLE - BADGE_HEIGHT / 2.0f + inset, badge - 2.0f * inset,
                    BADGE_HEIGHT - 2.0f * inset, BADGE_CORNER, BADGE_STROKE, BADGE_OUTLINE);
    draw_line(frame, &badge_face, label, x + badge / 2.0f - text / 2.0f, HEADER_MIDDLE + 0.5f);
}

/* Our logo, the waiting look (#464): the app icon's deck ring (design/icon/icon-1-deck-ring.svg, without its tile),
 * from the SVG's own numbers in its 1024-unit space, centered at 0.24 scale as JogLogo draws it. A Kit test checks
 * JogLogo's numbers against the SVG; the reference image checks these against JogLogo. */
#define LOGO_SCALE 0.24f
#define LOGO_MIDDLE 512.0f

/// One of the logo's arcs: a band from radius 224 to 300 (262 ± 38) between two radial butt ends, swept clockwise
/// from `from` to `to` (SVG points, under half a turn apart).
static void logo_arc(dfw_pixel *frame, float fx, float fy, float tx, float ty, dfw_pixel color) {
    const float inner = (262.0f - 38.0f) * LOGO_SCALE, outer = (262.0f + 38.0f) * LOGO_SCALE;
    float ux = fx - LOGO_MIDDLE, uy = fy - LOGO_MIDDLE, vx = tx - LOGO_MIDDLE, vy = ty - LOGO_MIDDLE;
    float ul = root(ux * ux + uy * uy), vl = root(vx * vx + vy * vy);
    // Normals into the sweep: the start's direction turned a quarter clockwise (y down), the end's counterclockwise.
    const float n0x = -uy / ul, n0y = ux / ul, n1x = vy / vl, n1y = -vx / vl;
    for (int y = 0; y < DFW_SIZE; y++) {
        float dy = (float)y + 0.5f - CENTER;
        for (int x = 0; x < DFW_SIZE; x++) {
            float dx = (float)x + 0.5f - CENTER;
            float d2 = dx * dx + dy * dy;
            if (d2 > (outer + 1.0f) * (outer + 1.0f) || d2 < (inner - 1.0f) * (inner - 1.0f)) continue;
            float r = root(d2);
            float nx = dx / r, ny = dy / r;
            float band = edge_cover(outer - r, nx, ny) + edge_cover(r - inner, nx, ny) - 1.0f;
            if (band <= 0.0f) continue;
            float cover = band * edge_cover(dx * n0x + dy * n0y, n0x, n0y) * edge_cover(dx * n1x + dy * n1y, n1x, n1y);
            dfw_pixel *p = &frame[y * DFW_SIZE + x];
            *p = blend(*p, color, cover);
        }
    }
}

/// A capsule: every point within `radius` of the segment from (ax, ay) to (bx, by), anti-aliased.
static void capsule(dfw_pixel *frame, float ax, float ay, float bx, float by, float radius, dfw_pixel color) {
    float ex = bx - ax, ey = by - ay, length2 = ex * ex + ey * ey;
    int left = floor_int((ax < bx ? ax : bx) - radius - 1.0f), right = floor_int((ax > bx ? ax : bx) + radius + 1.0f);
    int top = floor_int((ay < by ? ay : by) - radius - 1.0f), bottom = floor_int((ay > by ? ay : by) + radius + 1.0f);
    for (int y = top; y <= bottom; y++) {
        if (y < 0 || y >= DFW_SIZE) continue;
        for (int x = left; x <= right; x++) {
            if (x < 0 || x >= DFW_SIZE) continue;
            float px = (float)x + 0.5f - ax, py = (float)y + 0.5f - ay;
            float t = clamp01((px * ex + py * ey) / length2);
            float qx = px - t * ex, qy = py - t * ey, d = root(qx * qx + qy * qy);
            float cover = d > 0.0f ? edge_cover(radius - d, qx / d, qy / d) : 1.0f;
            dfw_pixel *p = &frame[y * DFW_SIZE + x];
            *p = blend(*p, color, cover);
        }
    }
}

/// The logo, its hub filled in the deck's color with no hole (#524: the stale look's deck, as JogLogo's hub fill).
static void logo(dfw_pixel *frame, dfw_pixel hub) {
    disc(frame, CENTER, CENTER, 206.0f * LOGO_SCALE, 0x1D1D1Eu);
    logo_arc(frame, 543.9f, 252.0f, 772.0f, 480.1f, 0x6C7277u);
    logo_arc(frame, 772.0f, 543.9f, 543.9f, 772.0f, 0xECCF65u);
    logo_arc(frame, 480.1f, 772.0f, 252.0f, 543.9f, 0xC5754Eu);
    logo_arc(frame, 252.0f, 480.1f, 480.1f, 252.0f, 0x62929Eu);
    // The needle: the rectangle x 497-527, y 202-368 with 15-unit corners is a capsule from y 217 to 353 on the
    // vertical through the middle, turned 40° clockwise about it (sin and cos of 40°, as constants: no libm).
    const float sin40 = 0.64278761f, cos40 = 0.76604444f, k = LOGO_SCALE;
    capsule(frame, CENTER + 295.0f * sin40 * k, CENTER - 295.0f * cos40 * k, CENTER + 159.0f * sin40 * k,
            CENTER - 159.0f * cos40 * k, 15.0f * k, 0xD5D5D5u);
    disc(frame, CENTER, CENTER, 74.0f * LOGO_SCALE, hub);
}

/// A whole-pixel rectangle in one color.
static void fill(dfw_pixel *frame, int x, int y, int width, int height, dfw_pixel color) {
    for (int row = y; row < y + height; row++)
        for (int column = x; column < x + width; column++) frame[row * DFW_SIZE + column] = color;
}

/// How much of the deck color the rule keeps while off phase, over the ground (#462).
#define PHASE_DIM DFW_PHASE_DIM
/// The ground's level in each channel (it is a gray).
#define GROUND_LEVEL ((int)(DFW_GROUND & 0xFFu))

/// One channel of the deck color dimmed over the ground, as the renderer works it: in double, rounded half away.
static uint8_t dimmed(uint8_t channel) {
    double level = (double)channel / 255 * 255 * PHASE_DIM + GROUND_LEVEL * (1 - PHASE_DIM);
    return (uint8_t)(level + 0.5);
}

/// The renderer's phase curve, g(p) = p/(|p| + 0.02), for p ≥ 0 in beats.
static double phase_curve(double beats) { return beats / (beats + DFW_PHASE_CURVE); }

/// The phase bar's length in whole px, as JogDisplayRenderer.phaseBar: 49 × g(p)/g(½), rounded, 1 to 49.
static int phase_bar(int phase) {
    double beats = (double)(phase < 0 ? -phase : phase) / DFW_PHASE_UNITS_PER_BEAT;
    int length = (int)(DFW_BAR_MAX * phase_curve(beats) / phase_curve(DFW_PHASE_FULL) + 0.5);
    return length < 1 ? 1 : length > DFW_BAR_MAX ? DFW_BAR_MAX : length;
}

/// The rule under the artist (#458) in the deck color, showing the deck's phase against the master (#462). Unknown:
/// the plain rule. In phase: the rule with a 2×6 tick at its center. Off phase: the rule dimmed and a 4 px bar in the
/// deck color from the center, left for behind and right for ahead.
static void rule(dfw_pixel *frame, const dfw_unit *unit) {
    const dfw_deck_state *d = &unit->deck;
    dfw_pixel deck = (dfw_pixel)d->r << 16 | (dfw_pixel)d->g << 8 | d->b;
    int phase = unit->phase;
    if (phase == DFW_PHASE_UNKNOWN || phase == 0) {
        fill(frame, DFW_RULE_X, DFW_RULE_Y, DFW_RULE_WIDTH, DFW_RULE_HEIGHT, deck);
        if (phase == 0) fill(frame, DFW_TICK_X, DFW_TICK_Y, DFW_TICK_WIDTH, DFW_TICK_HEIGHT, deck);
        return;
    }
    fill(frame, DFW_RULE_X, DFW_RULE_Y, DFW_RULE_WIDTH, DFW_RULE_HEIGHT,
         (dfw_pixel)dimmed(d->r) << 16 | (dfw_pixel)dimmed(d->g) << 8 | dimmed(d->b));
    int length = phase_bar(phase), middle = (int)DFW_CENTER;
    fill(frame, phase < 0 ? middle - length : middle, DFW_BAR_Y, length, DFW_BAR_HEIGHT, deck);
}

void dfw_draw(dfw_pixel *frame, const dfw_unit *unit) {
    for (int i = 0; i < DFW_SIZE * DFW_SIZE; i++) frame[i] = GROUND;
    if (dfw_stale(unit)) {
        // The waiting look (#464): the beat ring dark, our logo in the middle, and (#524, the user's pick) the deck in
        // its hub: the hub in the deck's color, its number in the ground's (Geist-Bold 18, as the header's chip),
        // centered on the frame's center. The deck layer is the controller's own and can change while Syndicate is
        // silent, so the hub follows the deck messages. A number outside 1-4 has no glyph: the hub alone.
        ring(frame, 1);
        const dfw_deck_state *d = &unit->deck;
        logo(frame, (dfw_pixel)d->r << 16 | (dfw_pixel)d->g << 8 | d->b);
        const dfw_face *ink = number_ink(d);
        const dfw_glyph *number = glyph(ink, (char)('0' + (d->number <= 9 ? d->number : 0)));
        if (number && d->number >= 1 && d->number <= 4)
            draw_glyph(frame, ink, number, CENTER - number->advance / 2.0f,
                       baseline_row(&number_face, CENTER));
        return;
    }
    ring(frame, 0);
    header(frame, &unit->deck);
    rule(frame, unit);
    // The words wait for the deck's own text (#458), so a deck change never flashes another deck's.
    if (unit->text_heard) {
        dfw_text_block block;
        dfw_text_block_for(unit, &block);
        for (int i = 0; i < block.count; i++) dfw_text_draw_line(frame, &block.lines[i]);
        if (block.foot) dfw_text_draw_foot(frame, unit);
    }
    dfw_draw_live(frame, unit);
}

const dfw_drawing dfw_drawn = { dfw_draw };
