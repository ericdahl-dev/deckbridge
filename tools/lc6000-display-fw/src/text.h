// The drawn display's text (#458): measuring and drawing lines of Windows-1252 codes in the Geist faces the renderer
// uses, laid out as CoreText lays out the renderer's lines (see gen/text_font_gen.swift for what was measured).
#ifndef DFW_TEXT_H
#define DFW_TEXT_H
#include <stddef.h>
#include <stdint.h>

#include "dfw.h"

typedef struct dfw_text_face dfw_text_face;

/// Geist-Bold 26 (the one-line title; an untitled deck's words), Geist-Bold 20 (the title on two lines), Geist-Medium
/// 16 (the artist; an untitled deck's caption), GeistMono-SemiBold 22 (key and BPM).
extern const dfw_text_face *const dfw_title26, *const dfw_title20, *const dfw_caption16, *const dfw_mono18;

/// A line's width in pixels. `tracked`: the one-line title's tracking and kerning (the face's own; no other line has
/// either, as the renderer's lines have neither).
float dfw_text_width(const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked);

/// The width in font units, summed exactly (no scaling): what the layout compares.
int32_t dfw_text_units(const dfw_text_face *face, const uint8_t *codes, size_t count, int tracked);
float dfw_text_size(const dfw_text_face *face);
uint16_t dfw_text_units_per_em(const dfw_text_face *face);

/// One line of the text block as drawn: its face, its CSS line box, and its codes after any ellipsis (0x85).
typedef struct {
    const dfw_text_face *face;
    uint8_t tracked;
    float top, height;
    uint8_t count;
    uint8_t codes[DFW_TEXT_MAX + 1];
} dfw_text_line;

/// The text between the header and the rule (the title or an untitled deck's words, then the artist or its caption),
/// and whether key and BPM show below the rule: JogDisplayRenderer.textBlock, line for line.
typedef struct {
    uint8_t count, foot;
    dfw_text_line lines[3];
} dfw_text_block;

void dfw_text_block_for(const dfw_unit *unit, dfw_text_block *block);

/// Draws one line of the block centered on the screen, as the renderer does: the baseline at the box's middle plus
/// (ascent - descent) / 2, in the face's own ink.
void dfw_text_draw_line(dfw_pixel *frame, const dfw_text_line *line);

/// Draws key and BPM below the rule (the foot): the key in blue, a space, the BPM to one decimal, each "—" when the
/// host sent none; monospaced, centered, never cut.
void dfw_text_draw_foot(dfw_pixel *frame, const dfw_unit *unit);

#endif
