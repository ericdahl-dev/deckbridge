#include "update_manifest.h"

namespace update_manifest {
namespace {

// A small strict JSON reader for the manifest: objects, arrays, strings, numbers, true, false, null. It reads only
// what the panel needs and steps over the rest (the catalog), with a depth limit so no input can recurse deeply.
class Reader {
  public:
    Reader(const char* text, size_t length) : p_(text), end_(text + length) {}

    bool manifest(Manifest& out) {
        bool ok = object([&](const std::string& key) {
            if (key == "format") return integer(out.format);
            if (key == "key") return string(&out.key);
            if (key == "lowest_allowed") return object([&](const std::string& device) {
                return device == "deck-panel" ? string(&out.lowest_allowed) : skip();
            });
            if (key == "files") return array([&] { return file(out); });
            return skip();
        });
        space();
        return ok && p_ == end_;
    }

  private:
    static constexpr int kMaxDepth = 16;

    bool file(Manifest& out) {
        std::string device, name, version, sha;
        long long size = -1;
        if (!object([&](const std::string& key) {
                if (key == "device") return string(&device);
                if (key == "name") return string(&name);
                if (key == "version") return string(&version);
                if (key == "sha256") return string(&sha);
                if (key == "size") return integer(size);
                return skip();
            }))
            return false;
        if (device != "deck-panel") return true;
        if (out.has_image || size < 0 || size > 0xFFFFFFFFLL || !hex32(sha, out.image.sha256)) return false;
        out.has_image = true;
        out.image.name = name;
        out.image.version = version;
        out.image.size = static_cast<uint32_t>(size);
        return true;
    }

    static bool hex32(const std::string& text, uint8_t out[32]) {
        if (text.size() != 64) return false;
        for (size_t i = 0; i < 32; ++i) {
            int hi = digit(text[2 * i]), lo = digit(text[2 * i + 1]);
            if (hi < 0 || lo < 0) return false;
            out[i] = static_cast<uint8_t>(hi * 16 + lo);
        }
        return true;
    }

    static int digit(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    void space() {
        while (p_ < end_ && (*p_ == ' ' || *p_ == '\n' || *p_ == '\r' || *p_ == '\t')) ++p_;
    }

    bool take(char c) {
        space();
        if (p_ < end_ && *p_ == c) { ++p_; return true; }
        return false;
    }

    template <class Member>
    bool object(Member member) {
        if (!take('{') || ++depth_ > kMaxDepth) return false;
        if (!take('}')) {
            do {
                std::string key;
                if (!string(&key) || !take(':') || !member(key)) return false;
            } while (take(','));
            if (!take('}')) return false;
        }
        --depth_;
        return true;
    }

    template <class Element>
    bool array(Element element) {
        if (!take('[') || ++depth_ > kMaxDepth) return false;
        if (!take(']')) {
            do {
                if (!element()) return false;
            } while (take(','));
            if (!take(']')) return false;
        }
        --depth_;
        return true;
    }

    // A string, kept in `out` if given. Escapes are kept as-is but for \" and \\: no field the panel reads has others.
    bool string(std::string* out) {
        if (!take('"')) return false;
        std::string value;
        while (p_ < end_ && *p_ != '"') {
            char c = *p_++;
            if (static_cast<unsigned char>(c) < 0x20) return false;
            if (c == '\\') {
                if (p_ == end_) return false;
                c = *p_++;
                if (c == 'u') {
                    for (int i = 0; i < 4; ++i)
                        if (p_ == end_ || digit(*p_++) < 0) return false;
                    c = '?';
                } else if (c != '"' && c != '\\' && c != '/' && c != 'b' && c != 'f' && c != 'n' && c != 'r' && c != 't') {
                    return false;
                }
            }
            value.push_back(c);
        }
        if (p_ == end_) return false;
        ++p_;
        if (out) *out = value;
        return true;
    }

    template <class Int>
    bool integer(Int& out) {
        space();
        long long value = 0;
        const char* start = p_;
        while (p_ < end_ && *p_ >= '0' && *p_ <= '9') {
            if (value > 0xFFFFFFFFLL) return false;
            value = value * 10 + (*p_++ - '0');
        }
        if (p_ == start) return false;
        out = static_cast<Int>(value);
        return true;
    }

    bool literal(const char* word) {
        for (const char* w = word; *w; ++w)
            if (p_ == end_ || *p_++ != *w) return false;
        return true;
    }

    bool skip() {
        space();
        if (p_ == end_) return false;
        switch (*p_) {
            case '{': return object([&](const std::string&) { return skip(); });
            case '[': return array([&] { return skip(); });
            case '"': return string(nullptr);
            case 't': return literal("true");
            case 'f': return literal("false");
            case 'n': return literal("null");
            default: break;
        }
        if (*p_ == '-') ++p_;
        const char* start = p_;
        while (p_ < end_ && ((*p_ >= '0' && *p_ <= '9') || *p_ == '.' || *p_ == 'e' || *p_ == 'E' || *p_ == '+' || *p_ == '-')) ++p_;
        return p_ != start;
    }

    const char* p_;
    const char* end_;
    int depth_ = 0;
};

}  // namespace

bool parse(const char* text, size_t length, Manifest& out) {
    out = Manifest{};
    Reader reader(text, length);
    if (reader.manifest(out)) return true;
    out = Manifest{};
    return false;
}

}  // namespace update_manifest
