// Checks a signed firmware release on the panel (#690, ADR 0012): the Ed25519 signature over the manifest's exact bytes.
#pragma once

#include <cstddef>
#include <cstdint>

namespace release_check {

/// Whether `signature` is `public_key`'s Ed25519 signature (RFC 8032) over exactly `message`.
bool signature_ok(const uint8_t public_key[32], const uint8_t* message, size_t length, const uint8_t signature[64]);

}  // namespace release_check
