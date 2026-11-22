#include "harness.h"
#include "draw.h"
#include <stdlib.h>
#include <string.h>

int harness_failures = 0;

static void present(void *ctx, const dfw_pixel *frame) {
    recording *rec = ctx;
    rec->presents++;
    memcpy(rec->last, frame, sizeof rec->last);
}

static void send(void *ctx, const uint8_t *bytes, size_t length) {
    recording *rec = ctx;
    rec->sends++;
    rec->sent_length = length < sizeof rec->sent ? length : sizeof rec->sent;
    memcpy(rec->sent, bytes, rec->sent_length);
}

/// The back buffer the tests hand in, as the hook hands in one in SDRAM.
static dfw_pixel frame[DFW_SIZE * DFW_SIZE];

static void start(dfw_unit *unit, recording *rec, const dfw_drawing *drawing) {
    memset(rec, 0, sizeof *rec);
    dfw_port port = { .present = present, .send = send, .ctx = rec };
    dfw_init(unit, &port, NULL, drawing);
}

void fresh_without_frame(dfw_unit *unit, recording *rec) { start(unit, rec, &dfw_drawn); }

void fresh_with_drawing(dfw_unit *unit, recording *rec, const dfw_drawing *drawing) {
    start(unit, rec, drawing);
    memset(frame, 0, sizeof frame);
    dfw_set_frame(unit, frame);
}

void fresh_without_drawing(dfw_unit *unit, recording *rec) {
    start(unit, rec, NULL);
    memset(frame, 0, sizeof frame);
    dfw_set_frame(unit, frame);
}

void fresh(dfw_unit *unit, recording *rec) {
    fresh_without_frame(unit, rec);
    memset(frame, 0, sizeof frame);
    dfw_set_frame(unit, frame);
}

size_t parse_hex(const char *hex, uint8_t *bytes, size_t capacity) {
    size_t n = 0;
    const char *p = hex;
    while (*p && n < capacity) {
        while (*p == ' ') p++;
        if (!*p) break;
        bytes[n++] = (uint8_t)strtoul(p, (char **)&p, 16);
    }
    return n;
}

void feed(dfw_unit *unit, const char *hex) {
    uint8_t bytes[1024];
    dfw_message(unit, bytes, parse_hex(hex, bytes, sizeof bytes));
}

// Each test file's own table, each ending in { 0, 0 }. A new file adds its table here.
extern const test_case all_tests[], draw_tests[], draw_live_tests[], text_tests[], layout_tests[], draw_band_tests[], ring_table_tests[], panel_tests[], present_tests[], panel_record_tests[], geometry_tests[];
static const test_case *const tables[] = { all_tests, draw_tests, draw_live_tests, text_tests, layout_tests, draw_band_tests, ring_table_tests, panel_tests, present_tests, panel_record_tests, geometry_tests };

int main(void) {
    int run = 0;
    for (size_t i = 0; i < sizeof tables / sizeof tables[0]; i++) {
        for (const test_case *t = tables[i]; t->name; t++, run++) {
            int before = harness_failures;
            t->fn();
            fprintf(stderr, "%s %s\n", harness_failures == before ? "ok  " : "FAIL", t->name);
        }
    }
    fprintf(stderr, "%d tests, %d failed checks\n", run, harness_failures);
    return harness_failures == 0 && run > 0 ? 0 : 1;
}
