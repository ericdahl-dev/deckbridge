// OSC bytes for the tests: what DeckBridge's display feed puts in one UDP packet (ADR 0011).
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace osc_bytes {

using Bytes = std::vector<uint8_t>;

// A string, NUL-terminated and padded to 4 bytes.
inline void put_string(Bytes& out, const std::string& s) {
    out.insert(out.end(), s.begin(), s.end());
    out.push_back(0);
    while (out.size() % 4) out.push_back(0);
}

inline void put_int(Bytes& out, int32_t v) {
    uint32_t u = static_cast<uint32_t>(v);
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<uint8_t>(u >> shift));
}

inline void put_float(Bytes& out, float f) {
    uint32_t u;
    std::memcpy(&u, &f, 4);
    put_int(out, static_cast<int32_t>(u));
}

inline Bytes int_message(const std::string& address, int32_t v) {
    Bytes out;
    put_string(out, address);
    put_string(out, ",i");
    put_int(out, v);
    return out;
}

inline Bytes string_message(const std::string& address, const std::string& v) {
    Bytes out;
    put_string(out, address);
    put_string(out, ",s");
    put_string(out, v);
    return out;
}

inline Bytes float_message(const std::string& address, float v) {
    Bytes out;
    put_string(out, address);
    put_string(out, ",f");
    put_float(out, v);
    return out;
}

/// An OSC bundle: "#bundle", a timetag (1, "immediately"), then each element as its size and its bytes.
inline Bytes bundle(const std::vector<Bytes>& elements) {
    Bytes out;
    put_string(out, "#bundle");
    put_int(out, 0);
    put_int(out, 1);
    for (const Bytes& e : elements) {
        put_int(out, static_cast<int32_t>(e.size()));
        out.insert(out.end(), e.begin(), e.end());
    }
    return out;
}

inline const std::string prefix = "/DeckBridge/Display/";

}  // namespace osc_bytes
