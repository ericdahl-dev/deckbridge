#include "update_session.h"

#include <cstring>
#include <vector>

namespace update_session {
namespace {

// A dotted version such as "1.10.0" as its numbers; false if it isn't one.
bool numbers(const std::string& text, std::vector<unsigned long>& out) {
    out.clear();
    unsigned long part = 0;
    bool digit = false;
    for (char c : text) {
        if (c >= '0' && c <= '9') {
            if (part > 100000000UL) return false;
            part = part * 10 + static_cast<unsigned long>(c - '0');
            digit = true;
        } else if (c == '.' && digit) {
            out.push_back(part);
            part = 0;
            digit = false;
        } else {
            return false;
        }
    }
    if (!digit) return false;
    out.push_back(part);
    return true;
}

}  // namespace

bool is_version(const std::string& text) {
    std::vector<unsigned long> parts;
    return numbers(text, parts);
}

bool below(const std::string& version, const std::string& floor) {
    if (floor.empty()) return false;
    std::vector<unsigned long> v, f;
    if (!numbers(version, v) || !numbers(floor, f)) return true;
    for (size_t i = 0; i < v.size() || i < f.size(); ++i) {
        const unsigned long a = i < v.size() ? v[i] : 0, b = i < f.size() ? f[i] : 0;
        if (a != b) return a < b;
    }
    return false;
}

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
    if (parsed_.format != 1) return refuse(Refusal::unknown_format);
    if (!parsed_.has_image) return refuse(Refusal::no_image);
    if (below(parsed_.image.version, config_.floor) || below(parsed_.image.version, parsed_.lowest_allowed))
        return refuse(Refusal::too_old);
    if (parsed_.image.size > config_.slot->capacity()) return refuse(Refusal::too_big);
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
    reply.floor = below(parsed_.lowest_allowed, config_.floor) || parsed_.lowest_allowed.empty() ? config_.floor
                                                                                                  : parsed_.lowest_allowed;
    return reply;
}

}  // namespace update_session
