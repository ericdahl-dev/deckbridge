// A signed firmware release's manifest, as the panel reads it (#690, ADR 0012). Only the fields the panel acts on:
// which key signed it, the format, the lowest panel version allowed, and the deck panel image's name, version, size
// and SHA-256. The signature covers the manifest's exact bytes, so nothing here is used before it checks out, except
// `key`, which names the key to check it with.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace update_manifest {

struct Image {
    std::string name;
    std::string version;
    uint32_t size = 0;
    uint8_t sha256[32] = {};
};

struct Manifest {
    int format = 0;
    std::string key;
    std::string lowest_allowed;  ///< for "deck-panel"; empty if the manifest sets none
    bool has_image = false;      ///< a file whose device is "deck-panel"
    Image image;
};

/// Reads `text` into `out`. False if it isn't a manifest: not JSON, or a field of the wrong shape.
bool parse(const char* text, size_t length, Manifest& out);

}  // namespace update_manifest
