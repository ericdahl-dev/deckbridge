#include "font_fallback.h"

#include <cstdint>
#include <cstring>

namespace font_fallback {

namespace {

/// The next character of valid UTF-8 at `p`: its code point, and how many bytes it took.
uint32_t next(const char* p, size_t& bytes) {
    const auto lead = static_cast<uint8_t>(p[0]);
    if (lead < 0x80) {
        bytes = 1;
        return lead;
    }
    bytes = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2;
    uint32_t code = lead & (0x3F >> (bytes - 1));
    for (size_t i = 1; i < bytes; ++i) code = code << 6 | (static_cast<uint8_t>(p[i]) & 0x3F);
    return code;
}

/// In the fonts: printable ASCII, U+00A0-U+017F, and "…".
bool drawn(uint32_t code) { return (code >= 0x20 && code < 0x7F) || (code >= 0xA0 && code <= 0x17F) || code == 0x2026; }

}  // namespace

void fit(const char* text, char* out, size_t size) {
    if (size == 0) return;
    size_t n = 0;
    for (const char* p = text; *p;) {
        size_t bytes;
        const uint32_t code = next(p, bytes);
        const char* shown = drawn(code) ? p : "?";
        const size_t length = drawn(code) ? bytes : 1;
        p += bytes;
        if (n + length > size - 1) break;  // whole or not at all
        std::memcpy(out + n, shown, length);
        n += length;
    }
    out[n] = 0;
}

}  // namespace font_fallback
