#include "update_session.h"

#include <cstring>

namespace update_session {

Reply Session::refuse(Refusal why) {
    Reply reply;
    reply.kind = Reply::refused;
    reply.refusal = why;
    return reply;
}

Reply Session::manifest(const uint8_t* bytes, size_t length) {
    manifest_.assign(reinterpret_cast<const char*>(bytes), length);
    return {};
}

Reply Session::signature(const uint8_t* bytes, size_t length) {
    // Only the key's name is read before the signature checks out; the rest of the manifest is acted on after.
    if (!update_manifest::parse(manifest_.data(), manifest_.size(), parsed_)) return refuse(Refusal::unreadable);
    const TrustedKey* key = nullptr;
    for (size_t i = 0; i < config_.key_count; ++i)
        if (parsed_.key == config_.keys[i].id) key = &config_.keys[i];
    if (!key) return refuse(Refusal::unknown_key);
    if (length != 64 || !config_.verify(key->public_key, reinterpret_cast<const uint8_t*>(manifest_.data()),
                                        manifest_.size(), bytes))
        return refuse(Refusal::bad_signature);
    Reply reply;
    reply.kind = Reply::ok_manifest;
    return reply;
}

}  // namespace update_session
