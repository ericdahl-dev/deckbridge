// frame-dump [--panel] <message hex>... (#515): the frame the native build draws for these messages, as the emulated
// chip gets them (each copied in, then one draw tick at time 0), written to stdout as 198x198 little-endian 0x00RRGGBB
// words. With --panel (#524), the whole 320x240 RGB565 panel instead, little-endian: black, the frame turned 180° at
// (61, 21) as the adapter presents it, then the band's ring from dfw_draw_band. arm/test/test_block.py compares both
// with what blocks A and B draw under emulation.
#include "dfw.h"
#include "draw.h"
#include "draw_band.h"
#include "present.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void present(void *ctx, const dfw_pixel *frame) { (void)ctx; (void)frame; }
static void send(void *ctx, const uint8_t *bytes, size_t length) { (void)ctx; (void)bytes; (void)length; }

static dfw_pixel frame[DFW_SIZE * DFW_SIZE];
static dfw_unit unit;
static uint16_t panel[DFW_LAYER_W * DFW_LAYER_H];

/// frame-dump's adapter of the layer seam (#568): the panel above.
static uint16_t dump_read(void *ctx, int index) { (void)ctx; return panel[index]; }
static void dump_write(void *ctx, int index, uint16_t value) { (void)ctx; panel[index] = value; }
static const dfw_layer dump_layer = { dump_read, dump_write, 0 };

int main(int argc, char **argv) {
    dfw_port port = { present, send, 0 };
    dfw_init(&unit, &port, frame, &dfw_drawn);
    int as_panel = argc > 1 && strcmp(argv[1], "--panel") == 0;
    for (int i = 1 + as_panel; i < argc; i++) {
        uint8_t bytes[DFW_MESSAGE_MAX];
        size_t length = 0;
        for (const char *h = argv[i]; h[0] && h[1] && length < sizeof bytes; h += 2) {
            char pair[3] = { h[0], h[1], 0 };
            bytes[length++] = (uint8_t)strtoul(pair, 0, 16);
        }
        dfw_message(&unit, bytes, length);
    }
    dfw_tick(&unit, 0);
    if (as_panel) {
        // A's present, composed through the seam (test/present.c; on the unit it is A's own copy), then B's band.
        present_through_layer(&dump_layer, frame);
        dfw_band_layer(&unit, &dump_layer);
        for (size_t i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) {
            uint8_t le[2] = { (uint8_t)panel[i], (uint8_t)(panel[i] >> 8) };
            fwrite(le, 1, 2, stdout);
        }
        return 0;
    }
    for (size_t i = 0; i < DFW_SIZE * DFW_SIZE; i++) {
        uint8_t le[4] = { (uint8_t)frame[i], (uint8_t)(frame[i] >> 8), (uint8_t)(frame[i] >> 16), (uint8_t)(frame[i] >> 24) };
        fwrite(le, 1, 4, stdout);
    }
    return 0;
}
