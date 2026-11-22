#include "wifi_form.h"

#include <cstring>

#include "wipe.h"

namespace wifi_setup {
namespace {

int hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Decodes one value into `out` (room bytes, terminated). False on a broken escape; `too_long` when it didn't fit.
bool decode(const char* from, const char* to, char* out, size_t room, bool& too_long) {
    size_t n = 0;
    too_long = false;
    for (const char* p = from; p < to; ++p) {
        int byte = static_cast<unsigned char>(*p);
        if (*p == '+') {
            byte = ' ';
        } else if (*p == '%') {
            if (to - p < 3 || hex(p[1]) < 0 || hex(p[2]) < 0) return false;
            byte = hex(p[1]) * 16 + hex(p[2]);
            p += 2;
        }
        if (n + 1 >= room) {
            too_long = true;
            continue;  // keep reading, so a broken escape later is still caught
        }
        out[n++] = static_cast<char>(byte);
    }
    out[n] = 0;
    return true;
}

bool all_hex(const char* s) {
    for (; *s; ++s)
        if (hex(*s) < 0) return false;
    return true;
}

}  // namespace

FormResult parse_form(const char* body, size_t length) {
    FormResult r;
    const char* garbled = "The page sent something garbled; try again";
    // One byte more than each field takes, so "too long" can be told from "fits".
    char ssid[34] = "", other[34] = "", password[66] = "";
    const WipeOnExit wipe_password(password, sizeof password);
    bool ssid_long = false, other_long = false, password_long = false;
    const char* end = body + length;
    for (const char* field = body; field < end;) {
        const char* amp = static_cast<const char*>(std::memchr(field, '&', static_cast<size_t>(end - field)));
        const char* stop = amp ? amp : end;
        const char* eq = static_cast<const char*>(std::memchr(field, '=', static_cast<size_t>(stop - field)));
        if (eq) {
            const size_t name = static_cast<size_t>(eq - field);
            bool ok = true;
            if (name == 4 && std::memcmp(field, "ssid", 4) == 0) {
                ok = decode(eq + 1, stop, ssid, sizeof ssid, ssid_long);
            } else if (name == 10 && std::memcmp(field, "ssid_other", 10) == 0) {
                ok = decode(eq + 1, stop, other, sizeof other, other_long);
            } else if (name == 8 && std::memcmp(field, "password", 8) == 0) {
                ok = decode(eq + 1, stop, password, sizeof password, password_long);
            }
            if (!ok) {
                r.error = garbled;
                return r;
            }
        }
        field = stop + 1;
    }

    const bool typed = other[0] != 0 || other_long;
    const char* name = typed ? other : ssid;
    const bool name_long = typed ? other_long : ssid_long;
    if (name[0] == 0 && !name_long) {
        r.error = "Choose a network, or type its name";
        return r;
    }
    if (name_long || std::strlen(name) > 32) {
        r.error = "A network name is at most 32 bytes";
        return r;
    }
    const size_t pw = std::strlen(password);
    for (size_t i = 0; i < pw; ++i) {
        const unsigned char c = static_cast<unsigned char>(password[i]);
        if (c < 0x20 || c > 0x7E) {
            r.error = "A password takes plain letters, digits, spaces and symbols";
            return r;
        }
    }
    const bool fits = pw == 0 || (pw >= 8 && pw <= 63) || (pw == 64 && all_hex(password));
    if (password_long || !fits) {
        r.error = "A password is 8 to 63 characters, or 64 hex digits; leave it empty for an open network";
        return r;
    }
    std::strcpy(r.credentials.ssid, name);
    std::strcpy(r.credentials.password, password);
    r.ok = true;
    return r;
}

}  // namespace wifi_setup
