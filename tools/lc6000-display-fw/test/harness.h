// A tiny test runner and the recording stub for the display port: what the code presents and sends is recorded here.
#ifndef HARNESS_H
#define HARNESS_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include "dfw.h"

extern int harness_failures;

#define CHECK(cond) do { if (!(cond)) { harness_failures++; \
    fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); } } while (0)

typedef void (*test_fn)(void);
typedef struct { const char *name; test_fn fn; } test_case;

/// What the stub saw: how many frames were presented, and the last one.
typedef struct {
    int presents;
    int sends;
    size_t sent_length;
    uint8_t sent[64];
    dfw_pixel last[DFW_SIZE * DFW_SIZE];
} recording;

/// A unit freshly started with the recording stub as its port.
void fresh(dfw_unit *unit, recording *rec);
/// The same, with no back buffer yet.
void fresh_without_frame(dfw_unit *unit, recording *rec);
/// The same with a frame but no drawing (the hook block before the drawing block checks out, #501).
void fresh_without_drawing(dfw_unit *unit, recording *rec);
/// The same with a frame and the given drawing.
void fresh_with_drawing(dfw_unit *unit, recording *rec, const dfw_drawing *drawing);
/// Hex ("F0 00 ... F7") to bytes; returns how many.
size_t parse_hex(const char *hex, uint8_t *bytes, size_t capacity);
/// Feeds one message, given as hex ("F0 00 ... F7").
void feed(dfw_unit *unit, const char *hex);

#endif
