#include "release_check.h"

#include <sodium.h>

namespace release_check {

bool signature_ok(const uint8_t public_key[32], const uint8_t* message, size_t length, const uint8_t signature[64]) {
    // sodium_init is safe to call again and returns 1 once it has run; -1 means libsodium can't be used.
    if (sodium_init() < 0) return false;
    static const uint8_t empty = 0;
    return crypto_sign_verify_detached(signature, message ? message : &empty, length, public_key) == 0;
}

}  // namespace release_check
