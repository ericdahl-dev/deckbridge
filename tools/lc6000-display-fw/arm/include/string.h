// The Arm build has no C library (#467): this declares the four functions libc_min.c provides, the only ones the
// firmware sources may use (#455). The native build uses the host's own string.h.
#ifndef HOOK_STRING_H
#define HOOK_STRING_H
#include <stddef.h>

void *memcpy(void *to, const void *from, size_t n);
void *memmove(void *to, const void *from, size_t n);
void *memset(void *to, int value, size_t n);
int memcmp(const void *a, const void *b, size_t n);

#endif
