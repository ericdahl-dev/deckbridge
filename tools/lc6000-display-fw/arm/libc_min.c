// The four functions GCC may call in freestanding code (#455): plain loops, built with -fno-builtin and
// -fno-tree-loop-distribute-patterns so they don't turn back into calls to themselves.
#include <stddef.h>

void *memcpy(void *to, const void *from, size_t n);
void *memmove(void *to, const void *from, size_t n);
void *memset(void *to, int value, size_t n);
int memcmp(const void *a, const void *b, size_t n);

void *memcpy(void *to, const void *from, size_t n) {
    unsigned char *t = to;
    const unsigned char *f = from;
    while (n--) *t++ = *f++;
    return to;
}

void *memmove(void *to, const void *from, size_t n) {
    unsigned char *t = to;
    const unsigned char *f = from;
    if (t < f) {
        while (n--) *t++ = *f++;
    } else {
        while (n--) t[n] = f[n];
    }
    return to;
}

void *memset(void *to, int value, size_t n) {
    unsigned char *t = to;
    while (n--) *t++ = (unsigned char)value;
    return to;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
    return 0;
}
