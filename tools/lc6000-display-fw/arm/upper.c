#include "upper.h"
#include "upper_crc.h"

static uint32_t word(const uint8_t *at) {
    return (uint32_t)at[0] | (uint32_t)at[1] << 8 | (uint32_t)at[2] << 16 | (uint32_t)at[3] << 24;
}

/// Thumb code (bit 0 set) past the header and before B's end.
static int inside(uint32_t entry, uint32_t length) {
    return (entry & 1u) && entry >= UPPER_BASE + UPPER_HEADER && entry < UPPER_BASE + length;
}

int upper_check(const uint8_t *b, uint32_t layout, upper_entries *entries) {
    if (word(b) != UPPER_MARKER || word(b + 4) != UPPER_VERSION) return 0;
    uint32_t length = word(b + 8);
    if (length < UPPER_HEADER || length > UPPER_LIMIT) return 0;
    if (~upper_crc_register(b, 16, length) != word(b + 12)) return 0;
    // B built against another dfw_unit would read A's state at the wrong offsets (#516).
    if (word(b + 16) != layout) return 0;
    uint32_t draw = word(b + 20), band = word(b + 24);
    if (!inside(draw, length) || !inside(band, length)) return 0;
    entries->draw = draw;
    entries->band = band;
    return 1;
}
