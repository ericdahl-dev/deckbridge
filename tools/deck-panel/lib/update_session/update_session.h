// One firmware update over Wi-Fi (#690, ADR 0012), as the panel runs it: a signed manifest, then the image, into the
// spare slot, switched to only when the image's size and SHA-256 match the manifest. Nothing touches the slot before
// the manifest's signature checks out. The wire protocol is in docs/DECK-PANEL-UPDATE-PROTOCOL.md.
//
// Portable: the signature check, the hash and the slot are seams, so the native tests drive it with fakes and the
// board plugs in the real ones (Ed25519, SHA-256, esp_ota).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#include "update_manifest.h"

namespace update_session {

struct TrustedKey {
    const char* id;
    uint8_t public_key[32];
};

/// Whether `signature` is `public_key`'s Ed25519 signature over exactly `message`.
using Verify = bool (*)(const uint8_t public_key[32], const uint8_t* message, size_t length, const uint8_t signature[64]);

class Hasher {
  public:
    virtual ~Hasher() = default;
    virtual void start() = 0;
    virtual void update(const uint8_t* data, size_t length) = 0;
    virtual void finish(uint8_t out[32]) = 0;
};

/// The spare app slot.
class Slot {
  public:
    virtual ~Slot() = default;
    virtual uint32_t capacity() const = 0;
    virtual bool begin(uint32_t size) = 0;  ///< erases only `size` bytes
    virtual bool write(const uint8_t* data, size_t length) = 0;
    virtual bool end() = 0;       ///< the image is complete; not yet the boot slot
    virtual bool set_boot() = 0;  ///< boot it next, as a trial until it confirms itself
    virtual void abort() = 0;     ///< drop what was written; the running firmware stays the boot slot
};

struct Config {
    const TrustedKey* keys;
    size_t key_count;
    Verify verify;
    Hasher* hasher;
    Slot* slot;
    std::string floor;  ///< the lowest version this panel takes (NVS, only ever raised)
};

enum class Refusal {
    none,
    busy,
    no_manifest,     ///< anything but a manifest and its signature first
    too_large,       ///< a manifest or chunk over its cap
    unreadable,      ///< not a manifest
    unknown_key,
    bad_signature,
    unknown_format,
    no_image,        ///< signed, but nothing in it for a deck panel
    too_old,         ///< below the floor or the manifest's lowest allowed version
    too_big,         ///< bigger than the spare slot
    mismatch,        ///< the image's size or SHA-256 differs from the manifest
    timeout,
    slot_error,
};

struct Reply {
    enum Kind { nothing, ok_manifest, progress, switched, refused } kind = nothing;
    Refusal refusal = Refusal::none;
    uint32_t bytes = 0;    ///< progress: received so far
    std::string version;   ///< switched: the version now set to boot
};

class Session {
  public:
    explicit Session(const Config& config) : config_(config) {}

    Reply manifest(const uint8_t* bytes, size_t length);
    Reply signature(const uint8_t* bytes, size_t length);
    Reply chunk(const uint8_t* bytes, size_t length);
    Reply done();

  private:
    Reply refuse(Refusal why);

    enum class State { manifest, signature, image, over };

    Config config_;
    State state_ = State::manifest;
    std::string manifest_;
    update_manifest::Manifest parsed_;
    uint32_t received_ = 0;
};

}  // namespace update_session
