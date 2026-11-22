#include "text.h"
#include "layout_generated.h"

#include <string.h>

#include "font_text.h"

const dfw_text_face *const dfw_title26 = &title26_face, *const dfw_title20 = &title20_face,
                    *const dfw_caption16 = &caption16_face, *const dfw_mono18 = &mono18_face;

enum { LIG_FF, LIG_FI, LIG_FL, LIG_TT };

/// The glyph at codes[*i], taking a ligature's pair as one (greedy, as CoreText: "ffi" is ff then i), and moving *i
/// past what it took. DFW_NO_GLYPH for a code that draws nothing.
static uint8_t next_glyph(const dfw_text_face *face, const uint8_t *codes, size_t count, size_t *i) {
    uint8_t code = codes[*i];
    (*i)++;
    if (*i < count) {
        uint8_t after = codes[*i];
        int lig = -1;
        if (code == 'f') lig = after == 'f' ? LIG_FF : after == 'i' ? LIG_FI : after == 'l' ? LIG_FL : -1;
        if (code == 't' && after == 't') lig = LIG_TT;
        if (lig >= 0 && face->ligature[lig] != DFW_NO_GLYPH) {
            (*i)++;
            return face->ligature[lig];
        }
    }
    return face->glyph_of[code];
}

/// The kern between two glyphs, in font units: a binary search of the sorted pairs.
static int kern(const dfw_text_face *face, uint8_t left, uint8_t right) {
    uint16_t pair = (uint16_t)(left << 8 | right);
    size_t low = 0, high = face->kern_count;
    while (low < high) {
        size_t mid = (low + high) / 2;
        if (face->kerns[mid].pair == pair) return face->kerns[mid].units;
        if (face->kerns[mid].pair < pair) low = mid + 1; else high = mid;
    }
    return 0;
}

float dfw_text_size(const dfw_text_face *face) { return face->size; }
uint16_t dfw_text_units_per_em(const dfw_text_face *face) { return face->units_per_em; }

float dfw_text_width(const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked) {
    return (float)dfw_text_units(face, codes, count, tracked) * face->size / (float)face->units_per_em;
}

int32_t dfw_text_units(const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked) {
    // Font units, summed exactly, then scaled once by the caller: a fit decided by <= can't turn on rounding.
    int32_t units = 0;
    int previous = -1;
    for (size_t i = 0; i < count;) {
        uint8_t glyph = next_glyph(face, codes, count, &i);
        if (glyph == DFW_NO_GLYPH) continue;
        units += face->glyphs[glyph].advance;
        if (tracked) {
            units += face->tracking;
            if (previous >= 0) units += kern(face, (uint8_t)previous, glyph);
        }
        previous = glyph;
    }
    return units;
}

/// One channel's blend of the ground toward the ink by a 4-bit coverage.
static dfw_pixel blend_level(dfw_pixel ground, uint32_t ink, int level) {
    dfw_pixel out = 0;
    for (int shift = 0; shift <= 16; shift += 8) {
        int g = (int)(ground >> shift & 0xFF), i = (int)(ink >> shift & 0xFF);
        int c = (g * (15 - level) + i * level + 7) / 15;
        out |= (dfw_pixel)c << shift;
    }
    return out;
}

static int floor_int(float v) {
    int i = (int)v;
    return (float)i > v ? i - 1 : i;
}

/// Draws a glyph with its origin at x: CoreText snaps that down to 1/phases of a pixel, and the glyph is drawn with
/// that phase's bitmap.
static void draw_glyph(dfw_pixel *frame, const dfw_text_face *face, uint8_t glyph, float x, int baseline, uint32_t ink) {
    int steps = floor_int(x * (float)face->phases);
    int phase = ((steps % face->phases) + face->phases) % face->phases;
    const dfw_text_bitmap *b = &face->glyphs[glyph].phase[phase];
    const uint8_t *coverage = face->coverage + b->offset;
    int row_bytes = (b->width + 1) / 2;
    int left = (steps - phase) / face->phases + b->left, top = baseline - b->top;
    for (int r = 0; r < b->height; r++) {
        int y = top + r;
        if (y < 0 || y >= DFW_SIZE) continue;
        for (int c = 0; c < b->width; c++) {
            int px = left + c;
            if (px < 0 || px >= DFW_SIZE) continue;
            uint8_t pair = coverage[r * row_bytes + c / 2];
            int level = c % 2 ? pair & 0x0F : pair >> 4;
            if (level) frame[y * DFW_SIZE + px] = blend_level(frame[y * DFW_SIZE + px], ink, level);
        }
    }
}

/// Draws a line from `left` at `baseline` (its y, unsnapped): glyphs at their pen positions, x snapped down to a
/// fraction of a pixel (the face's phases), y to the baseline's pixel. Codes before `split` are
/// drawn in `first`, the rest in the face's own ink.
static void draw_codes(dfw_pixel *frame, const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked,
                       float left, float baseline, size_t split, uint32_t first) {
    float scale = face->size / (float)face->units_per_em;
    int32_t pen = 0;
    int previous = -1, row = floor_int(baseline);
    for (size_t i = 0; i < count;) {
        size_t at = i;
        uint8_t glyph = next_glyph(face, codes, count, &i);
        if (glyph == DFW_NO_GLYPH) continue;
        if (tracked && previous >= 0) pen += kern(face, (uint8_t)previous, glyph);
        draw_glyph(frame, face, glyph, left + (float)pen * scale, row, at < split ? first : face->ink);
        pen += face->glyphs[glyph].advance + (tracked ? face->tracking : 0);
        previous = glyph;
    }
}

/// The screen's center, where every line is centered.
#define TEXT_CENTER DFW_CENTER

void dfw_text_draw_line(dfw_pixel *frame, const dfw_text_line *line) {
    const dfw_text_face *face = line->face;
    float width = dfw_text_width(face, line->codes, line->count, line->tracked);
    float baseline = line->top + line->height / 2 + (face->ascent - face->descent) / 2;
    draw_codes(frame, face, line->codes, line->count, line->tracked, TEXT_CENTER - width / 2, baseline, 0, 0);
}

/// The key's blue (JogDisplayRenderer's keyColor); the BPM is in the face's own ink.
#define KEY_INK DFW_KEY_INK
#define EM_DASH 0x97
/// Key and BPM's line box middle in drawn mode (#524, the renderer's Layout.drawn): 18 px, centered on y 140.5.
#define FOOT_MIDDLE DFW_KEY_CENTER_Y

void dfw_text_draw_foot(dfw_pixel *frame, const dfw_unit *unit) {
    const dfw_text_face *face = dfw_mono18;
    uint8_t codes[DFW_TEXT_MAX + 16];
    size_t count = 0;
    if (unit->text_length[2]) {
        memcpy(codes, unit->text[2], unit->text_length[2]);
        count = unit->text_length[2];
    } else {
        codes[count++] = EM_DASH;
    }
    size_t split = count;
    codes[count++] = ' ';
    if (unit->tempo) {
        // Tenths to "%.1f": the host rounded once, so this is exact.
        char digits[8];
        int n = 0;
        for (unsigned whole = unit->tempo / 10u; ; whole /= 10u) {
            digits[n++] = (char)('0' + whole % 10u);
            if (whole < 10u) break;
        }
        while (n) codes[count++] = (uint8_t)digits[--n];
        codes[count++] = '.';
        codes[count++] = (uint8_t)('0' + unit->tempo % 10u);
    } else {
        codes[count++] = EM_DASH;
    }
    float width = dfw_text_width(face, codes, count, 0);
    float baseline = FOOT_MIDDLE + (face->ascent - face->descent) / 2;
    draw_codes(frame, face, codes, count, 0, TEXT_CENTER - width / 2, baseline, split, KEY_INK);
}
