// The saved Wi-Fi (#622): one record, key "wifi", in a key-value store (Preferences/NVS on the panel, a fake on the
// Mac): version 1, the name's length and bytes, the password's length and bytes. A record this firmware didn't write
// loads as nothing, so the panel opens setup rather than join with garbage.
#pragma once

#include <cstddef>
#include <cstdint>

#include "wifi_form.h"

namespace wifi_setup {

struct KeyValue {
    virtual ~KeyValue() = default;
    // False if the key is missing or its value is longer than room.
    virtual bool get(const char* key, uint8_t* out, size_t room, size_t& length) = 0;
    virtual bool put(const char* key, const uint8_t* bytes, size_t length) = 0;
    virtual bool erase(const char* key) = 0;
};

bool save(KeyValue& store, const Credentials& credentials);
bool load(KeyValue& store, Credentials& credentials);
bool clear(KeyValue& store);

}  // namespace wifi_setup
