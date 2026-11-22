// Block B, our drawing block in the wd's upper flash (#501). It starts at 0x08080000 (sector 8, outside Denon's
// image) with a header block A checks before it calls anything in B. All fields are little-endian 32-bit words:
//
//   +0  marker   "DFWB"
//   +4  version  UPPER_VERSION; changes whenever this header or the entry table changes
//   +8  length   all of B in bytes, header included
//   +12 crc      CRC-32 (zlib's) of B from +16 (the layout on) up to length
//   +16 layout   DFW_LAYOUT as B was built (#516): the dfw_unit B reads, which must be block A's own
//   +20 draw     the entry table: B's draw function, a Thumb address inside B
//   +24 band     and its band function (#524), which draws the ring outside the frame straight into layer 2
//
// Portable C: it reads bytes only, so it runs and is tested on the Mac.
#ifndef UPPER_H
#define UPPER_H
#include <stdint.h>

#define UPPER_BASE 0x08080000u
/// Sectors 8-11 (128 KB each), 0x08080000-0x080FFFFF: all of the upper flash, once the owner's read proves it.
#define UPPER_LIMIT 0x80000u
#define UPPER_MARKER 0x42574644u /* "DFWB" */
#define UPPER_VERSION 4u
#define UPPER_HEADER 28u

/// B's entry table, as Thumb addresses on the chip.
typedef struct {
    uint32_t draw;
    uint32_t band;
} upper_entries;

/// Whether the B at `b`, which the chip sees at UPPER_BASE, checks out: marker, version, length, CRC, `layout` (block
/// A's DFW_LAYOUT) and both entries Thumb code inside B. If so, fills `entries`. Reads nothing past the marker of an
/// erased B.
int upper_check(const uint8_t *b, uint32_t layout, upper_entries *entries);

#endif
