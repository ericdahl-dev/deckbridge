// The release keys the panel trusts (#690, ADR 0012): the maintainer's primary key and the offline backup key, the
// same pairs as the updater app's ReleaseKeys.swift (test_release_keys.py checks they match).
//
// EMPTY until the owner makes the keys (docs/FIRMWARE-RELEASE-SIGNING.md): until then the panel refuses every update
// over Wi-Fi as signed by an unknown key, and the cable stays the way to change its firmware.
#pragma once

#include <cstddef>

#include "update_session.h"

namespace release_keys {

struct Listed {
    const char* id;
    const char* hex;  ///< the public key as 64 hex characters, as `firmware-release public-key` prints it
};

// Each entry: {"primary", "<64 hex>"}, then {"backup", "<64 hex>"}. Ends with the {nullptr, nullptr} marker.
constexpr Listed kListed[] = {
    {nullptr, nullptr},
};

/// The keys in `list` (ending with the {nullptr, nullptr} marker) as the update session takes them: up to `max` into
/// `out`, leaving out any that isn't 64 lowercase hex characters. Returns how many.
size_t trusted(const Listed* list, update_session::TrustedKey* out, size_t max);

}  // namespace release_keys
