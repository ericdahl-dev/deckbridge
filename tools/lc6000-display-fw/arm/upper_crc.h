// zlib's CRC-32 of B's bytes, the one C copy (#572): block A's check (upper.c) and C's header builder (upper_build.c)
// both include it. It returns the register before zlib's final inversion, so the CRC is ~upper_crc_register(...):
// written that way at the call, block A's bytes are the flashed ones. A nibble at a time: a 64-byte table, 11 instructions a byte on the M4 (a bit at a time is 54).
// Never the chip's CRC unit: stock and its startup stage use it.
#ifndef UPPER_CRC_H
#define UPPER_CRC_H
#include <stdint.h>

static const uint32_t nibbles[16] = {
    0x00000000u, 0x1DB71064u, 0x3B6E20C8u, 0x26D930ACu, 0x76DC4190u, 0x6B6B51F4u, 0x4DB26158u, 0x5005713Cu,
    0xEDB88320u, 0xF00F9344u, 0xD6D6A3E8u, 0xCB61B38Cu, 0x9B64C2B0u, 0x86D3D2D4u, 0xA00AE278u, 0xBDBDF21Cu,
};

static inline uint32_t upper_crc_register(const uint8_t *b, uint32_t from, uint32_t to) {
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = from; i < to; i++) {
        crc ^= b[i];
        crc = (crc >> 4) ^ nibbles[crc & 15u];
        crc = (crc >> 4) ^ nibbles[crc & 15u];
    }
    return crc;
}

#endif
