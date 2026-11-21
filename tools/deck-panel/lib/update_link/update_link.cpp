#include "update_link.h"

#include <algorithm>

namespace update_link {

using update_session::Refusal;
using update_session::Reply;

namespace {

const char* reason(Refusal refusal) {
    switch (refusal) {
        case Refusal::none: return "none";
        case Refusal::busy: return "busy";
        case Refusal::no_manifest: return "no-manifest";
        case Refusal::too_large: return "too-large";
        case Refusal::unreadable: return "unreadable";
        case Refusal::unknown_key: return "unknown-key";
        case Refusal::bad_signature: return "bad-signature";
        case Refusal::unknown_format: return "unknown-format";
        case Refusal::no_image: return "no-image";
        case Refusal::too_old: return "too-old";
        case Refusal::too_big: return "too-big";
        case Refusal::mismatch: return "mismatch";
        case Refusal::timeout: return "timeout";
        case Refusal::slot_error: return "slot-error";
    }
    return "unknown";
}

}  // namespace

std::string line(const Reply& reply) {
    switch (reply.kind) {
        case Reply::ok_manifest: return "ok manifest";
        case Reply::progress: return "progress " + std::to_string(reply.bytes);
        case Reply::switched: return "ok switched " + reply.version;
        case Reply::refused: return std::string("refused ") + reason(reply.refusal);
        case Reply::nothing: break;
    }
    return "";
}

bool Link::accept(int connection, uint32_t now_ms, Out& out) {
    if (session_) {
        out.lines.push_back("refused busy");
        out.close = true;
        return false;
    }
    connection_ = connection;
    last_ms_ = now_ms;
    session_.emplace(config_);
    header_have_ = 0;
    payload_.clear();
    return true;
}

void Link::finish(Out& out) {
    out.close = true;
    session_.reset();
    connection_ = -1;
}

void Link::handle(const Reply& reply, Out& out) {
    if (reply.kind == Reply::nothing) return;
    out.lines.push_back(line(reply));
    if (reply.kind == Reply::refused) finish(out);
    if (reply.kind == Reply::switched) {
        out.reboot = true;
        out.floor = reply.floor;
        finish(out);
    }
}

Out Link::received(int connection, const uint8_t* bytes, size_t length, uint32_t now_ms) {
    Out out;
    if (connection != connection_ || !session_) return out;
    last_ms_ = now_ms;
    for (size_t i = 0; i < length && session_;) {
        if (header_have_ < 5) {
            header_[header_have_++] = bytes[i++];
            if (header_have_ < 5) continue;
            payload_want_ = static_cast<uint32_t>(header_[1]) | static_cast<uint32_t>(header_[2]) << 8 |
                            static_cast<uint32_t>(header_[3]) << 16 | static_cast<uint32_t>(header_[4]) << 24;
            payload_.clear();
            // Caps from the header alone, before a byte of the payload is kept.
            const char type = static_cast<char>(header_[0]);
            const bool known = type == 'M' || type == 'S' || type == 'I' || type == 'D';
            if (!known) { handle(session_->stop(Refusal::no_manifest), out); break; }
            const bool fits = (type == 'M' && payload_want_ <= kMaxManifest) || (type == 'S' && payload_want_ == 64) ||
                              (type == 'I' && payload_want_ <= kMaxChunk) || (type == 'D' && payload_want_ == 0);
            if (!fits) { handle(session_->stop(Refusal::too_large), out); break; }
        }
        const size_t take = std::min(length - i, static_cast<size_t>(payload_want_) - payload_.size());
        payload_.insert(payload_.end(), bytes + i, bytes + i + take);
        i += take;
        if (payload_.size() < payload_want_) continue;
        header_have_ = 0;
        switch (static_cast<char>(header_[0])) {
            case 'M': handle(session_->manifest(payload_.data(), payload_.size()), out); break;
            case 'S': handle(session_->signature(payload_.data(), payload_.size()), out); break;
            case 'I': handle(session_->chunk(payload_.data(), payload_.size()), out); break;
            default: handle(session_->done(), out); break;
        }
    }
    return out;
}

Out Link::tick(uint32_t now_ms) {
    Out out;
    if (!session_) return out;
    const uint32_t limit = session_->receiving_image() ? kIdleMidImageMs : kIdleBeforeManifestMs;
    if (now_ms - last_ms_ >= limit) handle(session_->stop(Refusal::timeout), out);
    return out;
}

void Link::closed(int connection) {
    if (connection != connection_ || !session_) return;
    session_->stop(Refusal::timeout);
    session_.reset();
    connection_ = -1;
}

}  // namespace update_link
