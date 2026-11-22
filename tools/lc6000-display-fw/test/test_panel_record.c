// Every present through the recording adapter (#568): A's copy of the frame (composed natively, test/present.c) and
// B's band, as the hook runs them, over scenarios that exercise all the drawing. On the whole panel, per present: no
// pixel written twice, and none written black and then lit. For what B writes (the band): only pixels that change.
// And an unchanged scene presents nothing, and its band writes nothing.
// Known gap, stated, not tested away: A's copy rewrites the whole 198 square, 39,204 writes, on every present, changed
// or not. The changed-rows copy (and presenting at vertical blanking) belongs to #570's two-block batch.
#include "harness.h"
#include "draw.h"
#include "draw_band.h"
#include "layer_record.h"
#include "present.h"
#include <stdlib.h>
#include <string.h>

static layer_recorder record;
static dfw_unit unit;
static int presents, failures_twice, failures_dark_lit, band_unchanged, band_writes, copy_writes;

/// The port's present: A's copy, then B's band, as the hook's present wrapper calls them.
static void present(void *ctx, const dfw_pixel *frame) {
    (void)ctx;
    const dfw_layer layer = recorder_layer(&record);
    recorder_next_present(&record);
    present_through_layer(&layer, frame);
    int copy_total = record.total, copy_unchanged = record.unchanged;
    dfw_band_layer(&unit, &layer);
    presents++;
    copy_writes += copy_total;
    band_writes += record.total - copy_total;
    band_unchanged += record.unchanged - copy_unchanged;
    failures_twice += recorder_most_writes(&record) > 1;
    failures_dark_lit += record.dark_then_lit != 0;
}

static void send(void *ctx, const uint8_t *bytes, size_t length) { (void)ctx; (void)bytes; (void)length; }

static dfw_pixel frame[DFW_SIZE * DFW_SIZE];

static void start(void) {
    dfw_port port = { present, send, 0 };
    dfw_init(&unit, &port, frame, &dfw_drawn);
    recorder_fill(&record, 0);
    presents = failures_twice = failures_dark_lit = band_unchanged = band_writes = copy_writes = 0;
}

static void message(uint8_t op, const uint8_t *args, size_t count) {
    uint8_t bytes[DFW_MESSAGE_MAX] = { 0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x20 };
    size_t n = 7;
    bytes[n++] = (uint8_t)((count + 1) >> 7);
    bytes[n++] = (uint8_t)((count + 1) & 0x7F);
    bytes[n++] = op;
    for (size_t i = 0; i < count; i++) bytes[n++] = args[i];
    bytes[n++] = 0xF7;
    dfw_message(&unit, bytes, n);
}

#define SEND(op, ...) do { const uint8_t args_[] = { __VA_ARGS__ }; message(op, args_, sizeof args_); } while (0)

static void deck(uint8_t number, int r, int g, int b, uint8_t player) {
    SEND(0x03, number, (uint8_t)(r >> 7), (uint8_t)(r & 0x7F), (uint8_t)(g >> 7), (uint8_t)(g & 0x7F), (uint8_t)(b >> 7),
         (uint8_t)(b & 0x7F), player);
}

static void time_of(int elapsed, int length) {
    SEND(0x06, (uint8_t)(elapsed >> 7), (uint8_t)(elapsed & 0x7F), (uint8_t)(length >> 7), (uint8_t)(length & 0x7F));
}

static void text(uint8_t field, const char *chars) {
    uint8_t args[DFW_TEXT_MAX + 1];
    args[0] = field;
    size_t n = strlen(chars);
    memcpy(args + 1, chars, n);
    message(0x04, args, n + 1);
}

/// One evening on a deck: begin, the full state, the needle stepping, the beat, the meter, the phase, the time running
/// into the warning (steady red, then the blink, with its 500 ms flips), a loop held and released, a deck change, an
/// unknown length, feedback stale and back, three silent seconds and back, and end.
static uint32_t evening(uint32_t now, uint8_t number, int r, int g, int b) {
    SEND(0x01, 1);
    deck(number, r, g, b, 1);
    SEND(0x07, 0x03);
    text(0, "Night Drive");
    text(1, "Caf\x7F\x69 del Mar");
    text(2, "11B");
    SEND(0x05, 0x0A, 0x00);
    SEND(0x0B, 0x40, 0x00);
    time_of(83, 165);
    dfw_tick(&unit, now += 10);
    for (int step = 0; step < 40; step++) {
        int needle = (step * 410) & 0x3FFF;
        SEND(0x09, (uint8_t)(needle >> 7), (uint8_t)(needle & 0x7F));
        if (step % 4 == 0) SEND(0x08, (uint8_t)(1 + step / 4 % 4));
        if (step % 3 == 0) SEND(0x0A, (uint8_t)(step * 3 % 128), 120);
        if (step % 5 == 0) SEND(0x0B, (uint8_t)(step % 2 ? 0x01 : 0x7E), (uint8_t)(step * 7 % 128));
        dfw_tick(&unit, now += 33);
    }
    for (int second = 100; second <= 170; second += 5) {
        time_of(second, 165);
        dfw_tick(&unit, now += 10);
        dfw_tick(&unit, now += 500);   // the blink's white half, from 30 s left
    }
    SEND(0x07, 0x13);   // loop on: the warning held
    dfw_tick(&unit, now += 10);
    SEND(0x07, 0x03);   // and released
    dfw_tick(&unit, now += 10);
    deck((uint8_t)(number % 4 + 1), 0, 0, 128, 0);
    SEND(0x07, 0x01);
    time_of(42, 0);
    dfw_tick(&unit, now += 10);
    time_of(1, 3600);
    dfw_tick(&unit, now += 10);
    SEND(0x07, 0x21);   // feedback stale
    dfw_tick(&unit, now += 10);
    SEND(0x07, 0x01);
    dfw_tick(&unit, now += 10);
    dfw_tick(&unit, now += 3000);   // silent: the waiting look
    SEND(0x07, 0x01);
    dfw_tick(&unit, now += 10);
    SEND(0x02, 1);
    dfw_tick(&unit, now += 10);
    return now;
}

static void every_present_writes_each_pixel_once_and_never_black_then_lit(void) {
    start();
    static const int colors[][3] = { { 255, 0, 0 }, { 0, 128, 255 }, { 180, 0, 255 }, { 255, 255, 255 } };
    uint32_t now = 0;
    for (int c = 0; c < 4; c++) now = evening(now, (uint8_t)(c + 1), colors[c][0], colors[c][1], colors[c][2]);
    fprintf(stderr, "    %d presents: A's copy %d writes (%d each), the band %d\n", presents, copy_writes,
            presents ? copy_writes / presents : 0, band_writes);
    CHECK(presents > 250);
    CHECK(failures_twice == 0 && failures_dark_lit == 0);
    // The band writes only pixels that change.
    CHECK(band_writes > 0 && band_unchanged == 0);
    // The known gap: A's copy is the whole square, every present.
    CHECK(copy_writes == presents * DFW_SIZE * DFW_SIZE);
}

/// An unchanged scene presents nothing, and the band, called anyway, writes nothing.
static void an_unchanged_scene_writes_nothing(void) {
    start();
    SEND(0x01, 1);
    deck(2, 255, 0, 0, 1);
    SEND(0x07, 0x01);
    time_of(83, 165);
    SEND(0x09, 0x20, 0x00);
    dfw_tick(&unit, 10);
    CHECK(presents == 1);
    // The heartbeat: the same deck, state and time again.
    deck(2, 255, 0, 0, 1);
    SEND(0x07, 0x01);
    time_of(83, 165);
    dfw_tick(&unit, 1010);
    dfw_tick(&unit, 1500);
    CHECK(presents == 1);
    recorder_next_present(&record);
    const dfw_layer layer = recorder_layer(&record);
    dfw_band_layer(&unit, &layer);
    CHECK(record.total == 0);
}

const test_case panel_record_tests[] = {
    { "every present writes each pixel once and never black then lit",
      every_present_writes_each_pixel_once_and_never_black_then_lit },
    { "an unchanged scene writes nothing", an_unchanged_scene_writes_nothing },
    { 0, 0 },
};
