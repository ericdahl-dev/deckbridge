#include "release_keys.h"

#include <cstring>

namespace release_keys {
namespace {

int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

}  // namespace

size_t trusted(const Listed* list, update_session::TrustedKey* out, size_t max) {
    size_t n = 0;
    for (const Listed* entry = list; entry->id && n < max; ++entry) {
        if (std::strlen(entry->hex) != 64) continue;
        update_session::TrustedKey key{entry->id, {}};
        bool ok = true;
        for (size_t i = 0; i < 32 && ok; ++i) {
            const int hi = nibble(entry->hex[2 * i]), lo = nibble(entry->hex[2 * i + 1]);
            ok = hi >= 0 && lo >= 0;
            key.public_key[i] = static_cast<uint8_t>(hi * 16 + lo);
        }
        if (ok) out[n++] = key;
    }
    return n;
}

}  // namespace release_keys
