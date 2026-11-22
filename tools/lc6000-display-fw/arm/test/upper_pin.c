// The pin tool (#572): block A's C header code, for arm/test/test_upper_header.py to hold Python's against.
//   upper-pin consts                       MARKER VERSION HEADER LIMIT BASE
//   upper-pin check LAYOUT FILE            "ok DRAW BAND" if upper_check takes FILE's B (in erased flash), else "refused"
//   upper-pin build LAYOUT DRAW BAND       B to stdout: upper_build's header, then stdin as its body
#include "upper.h"
#include "upper_build.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t flash[UPPER_LIMIT];

static uint32_t number(const char *s) { return (uint32_t)strtoul(s, NULL, 0); }

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "consts") == 0) {
        printf("%u %u %u %u %u\n", UPPER_MARKER, UPPER_VERSION, UPPER_HEADER, UPPER_LIMIT, UPPER_BASE);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "check") == 0) {
        memset(flash, 0xFF, sizeof flash);
        FILE *f = fopen(argv[3], "rb");
        if (!f) return 2;
        size_t got = fread(flash, 1, sizeof flash, f);
        int bad = got == 0 && ferror(f);
        fclose(f);
        if (bad) return 2;
        upper_entries entries;
        if (upper_check(flash, number(argv[2]), &entries)) printf("ok %u %u\n", entries.draw, entries.band);
        else printf("refused\n");
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "build") == 0) {
        size_t body = fread(flash + UPPER_HEADER, 1, sizeof flash - UPPER_HEADER, stdin);
        uint32_t length = (uint32_t)(UPPER_HEADER + body);
        upper_build(flash, length, number(argv[2]), number(argv[3]), number(argv[4]));
        fwrite(flash, 1, length, stdout);
        return 0;
    }
    fprintf(stderr, "usage: upper-pin consts | check LAYOUT FILE | build LAYOUT DRAW BAND\n");
    return 2;
}
