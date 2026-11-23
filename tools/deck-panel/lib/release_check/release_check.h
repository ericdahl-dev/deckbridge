// Checks a signed firmware release on the panel (#690, ADR 0012): the Ed25519 signature over the manifest's exact bytes.
#pragma once

#include <cstddef>
#include <cstdint>

#include <sodium.h>

#include "update_session.h"

namespace release_check {

/// Whether `signature` is `public_key`'s Ed25519 signature (RFC 8032) over exactly `message`.
bool signature_ok(const uint8_t public_key[32], const uint8_t* message, size_t length, const uint8_t signature[64]);

/// SHA-256 (FIPS 180-4) of an image that arrives in chunks: the session's hasher on the panel and in native tests.
class Sha256 : public update_session::Hasher {
  public:
    Sha256();
    void start() override;
    void update(const uint8_t* data, size_t length) override;
    void finish(uint8_t out[32]) override;

  private:
    crypto_hash_sha256_state state_;
};

}  // namespace release_check
