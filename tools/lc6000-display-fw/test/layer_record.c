#include "layer_record.h"
#include <string.h>

void recorder_next_present(layer_recorder *r) {
    memset(r->writes, 0, sizeof r->writes);
    memset(r->blacked, 0, sizeof r->blacked);
    r->total = r->dark_then_lit = r->in_square = r->unchanged = 0;
}

void recorder_fill(layer_recorder *r, uint16_t value) {
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) r->pixels[i] = value;
    recorder_next_present(r);
}

static uint16_t recorder_read(void *ctx, int index) { return ((layer_recorder *)ctx)->pixels[index]; }

static void recorder_write(void *ctx, int index, uint16_t value) {
    layer_recorder *r = ctx;
    int x, y;
    dfw_panel_to_frame(index, &x, &y);
    if (dfw_in_frame(x, y)) r->in_square++;
    if (r->blacked[index] && value != 0) r->dark_then_lit++;
    if (value == 0) r->blacked[index] = 1;
    if (r->pixels[index] == value) r->unchanged++;
    if (r->writes[index] < 255) r->writes[index]++;
    r->total++;
    r->pixels[index] = value;
}

dfw_layer recorder_layer(layer_recorder *r) {
    dfw_layer layer = { recorder_read, recorder_write, r };
    return layer;
}

int recorder_most_writes(const layer_recorder *r) {
    int most = 0;
    for (int i = 0; i < DFW_LAYER_W * DFW_LAYER_H; i++) if (r->writes[i] > most) most = r->writes[i];
    return most;
}
