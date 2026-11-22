// The text block's layout (#458): the title's size, its wrap, and every ellipsis cut, as JogDisplayRenderer lays them
// out, for every case in test/ref/text_layout.h (written from the renderer by a Kit test).
#include "harness.h"
#include "messages.h"
#include "text.h"
#include "ref/text_layout.h"
#include <math.h>
#include <string.h>

static const dfw_text_face *face_named(const char *name) {
    if (strcmp(name, "title26") == 0) return dfw_title26;
    if (strcmp(name, "title20") == 0) return dfw_title20;
    if (strcmp(name, "caption16") == 0) return dfw_caption16;
    return NULL;
}

static void send_codes(dfw_unit *unit, int field, const char *codes) {
    send_text(unit, (uint8_t)field, (const uint8_t *)codes, strlen(codes));
}

static void print_codes(const uint8_t *codes, size_t count) {
    for (size_t i = 0; i < count; i++) fprintf(stderr, "%02X", codes[i]);
}

static void every_case_lays_out_as_the_renderer(void) {
    size_t count = sizeof text_layout_cases / sizeof text_layout_cases[0];
    CHECK(count > 0);
    for (size_t i = 0; i < count; i++) {
        const text_layout_case *c = &text_layout_cases[i];
        static dfw_unit unit;
        static recording rec;
        fresh(&unit, &rec);
        send_begin(&unit);
        send_deck(&unit, 1, 255, 255, 255, (uint8_t)c->player);
        send_codes(&unit, 0, c->title);
        send_codes(&unit, 1, c->artist);
        send_codes(&unit, 3, c->words);
        dfw_tick(&unit, 0);
        dfw_text_block block;
        dfw_text_block_for(&unit, &block);
        int ok = block.count == c->count && block.foot == c->foot;
        for (int l = 0; ok && l < c->count; l++) {
            const dfw_text_line *got = &block.lines[l];
            const text_layout_line *want = &c->lines[l];
            size_t n = strlen(want->codes);
            ok = got->face == face_named(want->face) && got->tracked == want->tracked &&
                 fabs(got->top - want->top) < 1e-4 && fabs(got->height - want->height) < 1e-4 && got->count == n &&
                 memcmp(got->codes, want->codes, n) == 0;
        }
        if (!ok) {
            harness_failures++;
            fprintf(stderr, "  case %zu (title ", i);
            print_codes((const uint8_t *)c->title, strlen(c->title));
            fprintf(stderr, ", artist ");
            print_codes((const uint8_t *)c->artist, strlen(c->artist));
            fprintf(stderr, "): %d lines, foot %d; want %d, %d\n", block.count, block.foot, c->count, c->foot);
            for (int l = 0; l < block.count && l < 3; l++) {
                fprintf(stderr, "    got  ");
                print_codes(block.lines[l].codes, block.lines[l].count);
                fprintf(stderr, " top %.2f\n", block.lines[l].top);
            }
            for (int l = 0; l < c->count; l++) {
                fprintf(stderr, "    want ");
                print_codes((const uint8_t *)c->lines[l].codes, strlen(c->lines[l].codes));
                fprintf(stderr, " top %.2f\n", c->lines[l].top);
            }
        }
    }
}

const test_case layout_tests[] = {
    { "every case lays out as the renderer", every_case_lays_out_as_the_renderer },
    { 0, 0 },
};
