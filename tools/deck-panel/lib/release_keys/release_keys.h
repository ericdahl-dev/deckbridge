// The release keys the panel trusts (#690, ADR 0012): the maintainer's primary key and the offline backup key, the
// same pairs as the updater app's ReleaseKeys.swift (test_release_keys.py checks they match).
//
// The owner made them on 2026-11-23 (#689, docs/FIRMWARE-RELEASE-SIGNING.md). Public halves only.
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
    {"primary", "26739c2c075965fd9a99330f97c3b09a28d11f85c1fa4d81bd5495cb67c1a5f8"},
    {"backup", "2e972a79fd40b287a151166dcdc723d07e84afe9ffc933fb211c670873c07cbe"},
    {nullptr, nullptr},
};

/// The keys in `list` (ending with the {nullptr, nullptr} marker) as the update session takes them: up to `max` into
/// `out`, leaving out any that isn't 64 lowercase hex characters. Returns how many.
size_t trusted(const Listed* list, update_session::TrustedKey* out, size_t max);

}  // namespace release_keys
