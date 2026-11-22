#include "upper_build.h"
#include "upper.h"
#include "upper_crc.h"

static void put(uint8_t *at, uint32_t word) {
    for (int i = 0; i < 4; i++) at[i] = (uint8_t)(word >> (8 * i));
}

void upper_build(uint8_t *b, uint32_t length, uint32_t layout, uint32_t draw, uint32_t band) {
    put(b + 0, UPPER_MARKER);
    put(b + 4, UPPER_VERSION);
    put(b + 8, length);
    put(b + 16, layout);
    put(b + 20, draw);
    put(b + 24, band);
    put(b + 12, ~upper_crc_register(b, 16, length));
}
