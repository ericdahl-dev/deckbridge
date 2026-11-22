// The text block's layout (#458), as JogDisplayRenderer.textBlock lays it out: the title at 26 px when it fits whole,
// else wrapped at words at 20 px; the artist; an untitled deck's words and caption; every line cut with an ellipsis
// to the round screen. Only the drawing calls this: it stays out of the hook block (#501).
#include "text.h"
#include "layout_generated.h"

#include <string.h>

/// The screen's center and the safe circle's radius (JogDisplayRenderer's center and safe).
#define CENTER ((double)DFW_CENTER)
#define SAFE 79.0
#define ELLIPSIS 0x85
#define EM_DASH 0x97

/// A square root by Newton's method: there's no libm on the chip, and these are line-box chords, done once a change.
static double root_double(double x) {
    if (x <= 0) return 0;
    double r = x > 1 ? x : 1;
    for (int i = 0; i < 60; i++) r = (r + x / r) / 2;
    return r;
}

/// The safe circle's width at a line box's farther edge from the center.
static double chord(double top, double height) {
    double a = top - CENTER, b = top + height - CENTER;
    if (a < 0) a = -a;
    if (b < 0) b = -b;
    double dy = a > b ? a : b;
    return 2 * root_double(SAFE * SAFE - dy * dy);
}

/// A line's width in pixels, as CoreText measures it (to double precision, as the renderer compares).
static double width(const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked) {
    return (double)dfw_text_units(face, codes, count, tracked) * dfw_text_size(face) / dfw_text_units_per_em(face);
}

static int space(uint8_t code) { return code == ' ' || code == 0xA0; }

static void set_line(dfw_text_line *line, const dfw_text_face *face, int tracked, double top, double height,
                     const uint8_t *codes, size_t count) {
    line->face = face;
    line->tracked = (uint8_t)tracked;
    line->top = (float)top;
    line->height = (float)height;
    if (count > DFW_TEXT_MAX + 1) count = DFW_TEXT_MAX + 1;
    memcpy(line->codes, codes, count);
    line->count = (uint8_t)count;
}

/// Where a cut may fall: not inside a ligature's pair (CoreText keeps a cluster whole).
static int splits_ligature(const uint8_t *codes, size_t count, size_t at) {
    // Walk the shaping from the start, greedily, as the measure does.
    size_t i = 0;
    while (i < count) {
        uint8_t code = codes[i];
        int pair = i + 1 < count && ((code == 'f' && (codes[i + 1] == 'f' || codes[i + 1] == 'i' || codes[i + 1] == 'l')) ||
                                     (code == 't' && codes[i + 1] == 't'));
        if (pair && at == i + 1) return 1;
        i += pair ? 2 : 1;
    }
    return 0;
}

/// A line cut as CTLineCreateTruncatedLine cuts it, when it's wider than `room`: the longest start that ends between
/// glyphs, its trailing spaces dropped, with the ellipsis, that fits the room plus the whole line's trailing spaces
/// (which CoreText doesn't count against a line).
static void fit(dfw_text_line *line, const dfw_text_face *face, int tracked, double top, double height,
                const uint8_t *codes, size_t count) {
    double room = chord(top, height);
    if (width(face, codes, count, tracked) <= room) {
        set_line(line, face, tracked, top, height, codes, count);
        return;
    }
    size_t end = count;
    while (end > 0 && space(codes[end - 1])) end--;
    double budget = room + width(face, codes + end, count - end, tracked);
    uint8_t shown[DFW_TEXT_MAX + 1];
    const uint8_t ellipsis = ELLIPSIS;
    double ellipsis_width = width(face, &ellipsis, 1, tracked);
    for (size_t n = count; ; n--) {
        if (n == 0 || !splits_ligature(codes, count, n)) {
            size_t kept = n;
            while (kept > 0 && space(codes[kept - 1])) kept--;
            if (n == 0 || width(face, codes, kept, tracked) + ellipsis_width <= budget) {
                memcpy(shown, codes, kept);
                shown[kept] = ELLIPSIS;
                set_line(line, face, tracked, top, height, shown, kept + 1);
                return;
            }
        }
    }
}

/// The renderer's title wrap at 20 px (titleLines): line 1 takes the whole words that fit its chord (a first word too
/// long is broken there); line 2 the rest, ending in an ellipsis when it doesn't fit. Words are split at spaces, empty
/// ones dropped, and joined again with one space. Returns how many lines.
static int wrap(const uint8_t *title, size_t count, uint8_t *line1, size_t *count1, uint8_t *line2, size_t *count2) {
    const dfw_text_face *face = dfw_title20;
    double first = chord(54, 22), second = chord(78, 22);
    // The words, as (start, length).
    size_t starts[DFW_TEXT_MAX], lengths[DFW_TEXT_MAX], words = 0;
    for (size_t i = 0; i < count;) {
        if (title[i] == ' ') { i++; continue; }
        size_t start = i;
        while (i < count && title[i] != ' ') i++;
        starts[words] = start;
        lengths[words++] = i - start;
    }
    if (words == 0) return 0;
    uint8_t joined[DFW_TEXT_MAX * 2];
    size_t taken = 0, joined_count = 0;
    // Whole words on line 1 while they fit.
    while (taken < words) {
        size_t n = joined_count + (taken ? 1 : 0) + lengths[taken];
        uint8_t trial[DFW_TEXT_MAX * 2];
        memcpy(trial, joined, joined_count);
        size_t at = joined_count;
        if (taken) trial[at++] = ' ';
        memcpy(trial + at, title + starts[taken], lengths[taken]);
        if (width(face, trial, n, 0) > first) break;
        memcpy(joined, trial, n);
        joined_count = n;
        taken++;
    }
    uint8_t rest[DFW_TEXT_MAX * 2];
    size_t rest_count = 0;
    if (taken == 0) {
        // One word wider than line 1: as many of its characters as fit, the rest carries on.
        size_t cut = lengths[0];
        while (cut > 1 && width(face, title + starts[0], cut, 0) > first) cut--;
        memcpy(joined, title + starts[0], cut);
        joined_count = cut;
        memcpy(rest, title + starts[0] + cut, lengths[0] - cut);
        rest_count = lengths[0] - cut;
        taken = 1;
    }
    for (size_t w = taken; w < words; w++) {
        if (rest_count) rest[rest_count++] = ' ';
        memcpy(rest + rest_count, title + starts[w], lengths[w]);
        rest_count += lengths[w];
    }
    memcpy(line1, joined, joined_count);
    *count1 = joined_count;
    if (rest_count == 0) return 1;
    if (width(face, rest, rest_count, 0) <= second) {
        memcpy(line2, rest, rest_count);
        *count2 = rest_count;
        return 2;
    }
    // Characters off the end until what's left, trimmed, fits with the ellipsis.
    size_t shown = rest_count;
    for (;;) {
        size_t from = 0, to = shown;
        while (from < to && space(rest[from])) from++;
        while (to > from && space(rest[to - 1])) to--;
        uint8_t trial[DFW_TEXT_MAX * 2 + 1];
        memcpy(trial, rest + from, to - from);
        trial[to - from] = ELLIPSIS;
        if (shown == 0 || width(face, trial, to - from + 1, 0) <= second) {
            memcpy(line2, trial, to - from + 1);
            *count2 = to - from + 1;
            return 2;
        }
        shown--;
    }
}

void dfw_text_block_for(const dfw_unit *unit, dfw_text_block *block) {
    memset(block, 0, sizeof *block);
    const uint8_t *title = unit->text[0];
    size_t title_count = unit->text_length[0];
    uint8_t player = unit->deck.player;
    if (title_count == 0) {
        // No title: the deck's words (the host sends them, as JogDisplayWords), and the caption for its kind.
        static const uint8_t load[] = "Load a track", none[] = "no title";
        int empty = player <= 1;
        fit(&block->lines[0], dfw_title26, 0, 66, 26 * 1.1, unit->text[3], unit->text_length[3]);
        fit(&block->lines[1], dfw_caption16, 0, 100, 16 * 1.1, empty ? load : none, empty ? sizeof load - 1 : sizeof none - 1);
        block->count = 2;
        block->foot = !empty;
        return;
    }
    double artist_top;
    if (width(dfw_title26, title, title_count, 1) <= chord(60, 26 * 1.15)) {
        fit(&block->lines[0], dfw_title26, 1, 60, 26 * 1.15, title, title_count);
        block->count = 1;
        artist_top = 94;
    } else {
        uint8_t line1[DFW_TEXT_MAX * 2], line2[DFW_TEXT_MAX * 2 + 1];
        size_t count1 = 0, count2 = 0;
        int lines = wrap(title, title_count, line1, &count1, line2, &count2);
        if (lines == 2) {
            fit(&block->lines[0], dfw_title20, 0, 54, 20 * 1.1, line1, count1);
            fit(&block->lines[1], dfw_title20, 0, 78, 20 * 1.1, line2, count2);
            block->count = 2;
            artist_top = 103;
        } else {
            fit(&block->lines[0], dfw_title20, 0, 75 - 20 * 1.1 / 2, 20 * 1.1, line1, count1);
            block->count = 1;
            artist_top = 94;
        }
    }
    static const uint8_t dash = EM_DASH;
    int artist = unit->text_length[1] > 0;
    fit(&block->lines[block->count], dfw_caption16, 0, artist_top, 16 * 1.15, artist ? unit->text[1] : &dash,
        artist ? unit->text_length[1] : 1);
    block->count++;
    block->foot = 1;
}
