#include "update_session.h"

#include <cstring>

namespace update_session {

Reply Session::refuse(Refusal why) {
    // Anything written so far is dropped: the running firmware stays the one that boots.
    if (state_ == State::image) config_.slot->abort();
    state_ = State::over;
    Reply reply;
    reply.kind = Reply::refused;
    reply.refusal = why;
    return reply;
}

Reply Session::manifest(const uint8_t* bytes, size_t length) {
    if (state_ != State::manifest) return refuse(Refusal::no_manifest);
    state_ = State::signature;
    manifest_.assign(reinterpret_cast<const char*>(bytes), length);
    return {};
}

Reply Session::signature(const uint8_t* bytes, size_t length) {
    if (state_ != State::signature) return refuse(Refusal::no_manifest);
    // Only the key's name is read before the signature checks out; the rest of the manifest is acted on after.
    if (!update_manifest::parse(manifest_.data(), manifest_.size(), parsed_)) return refuse(Refusal::unreadable);
    const TrustedKey* key = nullptr;
    for (size_t i = 0; i < config_.key_count; ++i)
        if (parsed_.key == config_.keys[i].id) key = &config_.keys[i];
    if (!key) return refuse(Refusal::unknown_key);
    if (length != 64 || !config_.verify(key->public_key, reinterpret_cast<const uint8_t*>(manifest_.data()),
                                        manifest_.size(), bytes))
        return refuse(Refusal::bad_signature);
    if (!config_.slot->begin(parsed_.image.size)) return refuse(Refusal::slot_error);
    config_.hasher->start();
    state_ = State::image;
    Reply reply;
    reply.kind = Reply::ok_manifest;
    return reply;
}

Reply Session::chunk(const uint8_t* bytes, size_t length) {
    if (state_ != State::image) return refuse(Refusal::no_manifest);
    if (length > parsed_.image.size - received_) return refuse(Refusal::mismatch);
    if (!config_.slot->write(bytes, length)) return refuse(Refusal::slot_error);
    config_.hasher->update(bytes, length);
    received_ += static_cast<uint32_t>(length);
    Reply reply;
    reply.kind = Reply::progress;
    reply.bytes = received_;
    return reply;
}

Reply Session::done() {
    if (state_ != State::image) return refuse(Refusal::no_manifest);
    uint8_t hash[32];
    config_.hasher->finish(hash);
    if (received_ != parsed_.image.size || std::memcmp(hash, parsed_.image.sha256, 32) != 0) return refuse(Refusal::mismatch);
    if (!config_.slot->end() || !config_.slot->set_boot()) return refuse(Refusal::slot_error);
    state_ = State::over;
    Reply reply;
    reply.kind = Reply::switched;
    reply.version = parsed_.image.version;
    return reply;
}

}  // namespace update_session
