// The text measure (#458): a line's width as the renderer lays it out, from advances, ligatures, kerning and tracking
// in font units, checked against CoreText's own widths (test/ref/text_widths.h, made by gen/text_font_gen.swift).
#include "harness.h"
#include "text.h"
#include "ref/text_widths.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static const dfw_text_face *face_named(const char *name) {
    if (strcmp(name, "title26") == 0) return dfw_title26;
    if (strcmp(name, "title20") == 0) return dfw_title20;
    if (strcmp(name, "caption16") == 0) return dfw_caption16;
    if (strcmp(name, "mono18") == 0) return dfw_mono18;
    return NULL;
}

static void every_width_matches_coretext(void) {
    size_t count = sizeof text_width_cases / sizeof text_width_cases[0];
    CHECK(count > 0);
    for (size_t i = 0; i < count; i++) {
        const text_width_case *c = &text_width_cases[i];
        const dfw_text_face *face = face_named(c->face);
        CHECK(face != NULL);
        if (!face) continue;
        const uint8_t *codes = (const uint8_t *)c->codes;
        float width = dfw_text_width(face, codes, strlen(c->codes), c->tracked);
        if (fabs(width - c->width) > 0.01) {
            harness_failures++;
            fprintf(stderr, "  %s%s: %f, CoreText %f (", c->face, c->tracked ? " tracked" : "", width, c->width);
            for (const char *p = c->codes; *p; p++) fprintf(stderr, "%02X", (uint8_t)*p);
            fprintf(stderr, ")\n");
        }
    }
}

/// Every Camelot code (#590) the host may send as the key, "1A" to "12B", is drawn in the key face's own glyphs, none
/// as the box: GeistMono's glyphs are all 600 units wide, the box 500, so a line of n real glyphs is n * 600.
static void every_camelot_code_has_its_glyphs_in_the_key_face(void) {
    const uint8_t box[] = { 0x81 };
    CHECK(dfw_text_units(dfw_mono18, box, 1, 0) == 500);   // the box is told apart by its width
    for (int number = 1; number <= 12; number++) {
        for (int minor = 0; minor <= 1; minor++) {
            char code[4];
            int count = snprintf(code, sizeof code, "%d%c", number, minor ? 'A' : 'B');
            int32_t units = dfw_text_units(dfw_mono18, (const uint8_t *)code, (size_t)count, 0);
            if (units != 600 * count) {
                harness_failures++;
                fprintf(stderr, "  %s: %d units, not %d: a glyph is the box\n", code, units, 600 * count);
            }
        }
    }
}

const test_case text_tests[] = {
    { "every width matches CoreText", every_width_matches_coretext },
    { "every Camelot code has its glyphs in the key face", every_camelot_code_has_its_glyphs_in_the_key_face },
    { 0, 0 },
};
