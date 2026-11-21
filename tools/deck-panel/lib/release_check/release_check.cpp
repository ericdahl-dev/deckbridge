#include "release_check.h"

#include <sodium.h>

namespace release_check {

bool signature_ok(const uint8_t public_key[32], const uint8_t* message, size_t length, const uint8_t signature[64]) {
    // sodium_init is safe to call again and returns 1 once it has run; -1 means libsodium can't be used.
    if (sodium_init() < 0) return false;
    static const uint8_t empty = 0;
    return crypto_sign_verify_detached(signature, message ? message : &empty, length, public_key) == 0;
}

Sha256::Sha256() : state_() { start(); }

void Sha256::start() {
    // libsodium asks for sodium_init before any call; SHA-256 has no setup that can fail, so its result doesn't matter here.
    const int ready = sodium_init();
    (void)ready;
    crypto_hash_sha256_init(&state_);
}

void Sha256::update(const uint8_t* data, size_t length) { crypto_hash_sha256_update(&state_, data, length); }

void Sha256::finish(uint8_t out[32]) { crypto_hash_sha256_final(&state_, out); }

}  // namespace release_check
