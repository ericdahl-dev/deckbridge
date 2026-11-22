// Block B's header built in C (#572), for the Mac's tests and the pin against arm/upper_header.py: never in either
// block. B's own header on the chip is upper_header.c's, sealed after the link.
#ifndef UPPER_BUILD_H
#define UPPER_BUILD_H
#include <stdint.h>

/// Writes a sealed header at `b` for a B of `length` bytes whose body (from UPPER_HEADER) is already there.
void upper_build(uint8_t *b, uint32_t length, uint32_t layout, uint32_t draw, uint32_t band);

#endif
