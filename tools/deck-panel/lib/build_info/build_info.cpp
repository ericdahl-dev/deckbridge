#include "build_info.h"

#include <cstdio>
#include <cstring>

namespace build_info {

namespace {
const char* local_mark(const Build& b) { return b.release ? "" : " local"; }
}  // namespace

void boot_line(const Build& b, char* out, size_t n) {
    snprintf(out, n, "deck panel: boot, build %s, version %s%s", b.sha, b.version, local_mark(b));
}

void answer_line(const Build& b, char* out, size_t n) {
    snprintf(out, n, "deck panel: build %s, version %s%s", b.sha, b.version, local_mark(b));
}

void label(const Build& b, char* out, size_t n) { snprintf(out, n, "v%s%s  %s", b.version, local_mark(b), b.sha); }

bool Question::feed(char c) {
    if (c == '\r' || c == '\n') {  // CR LF ends one line; the LF then ends an empty one, which asks nothing
        const bool asked = len_ == 7 && std::memcmp(line_, "version", 7) == 0;
        len_ = 0;
        return asked;
    }
    if (len_ < kMax) line_[len_++] = c;
    return false;
}

}  // namespace build_info
