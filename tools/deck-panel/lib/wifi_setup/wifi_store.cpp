#include "wifi_store.h"

#include <cstring>

#include "wipe.h"

namespace wifi_setup {
namespace {

constexpr const char* kKey = "wifi";
constexpr uint8_t kVersion = 1;
// Version, two lengths, 32 + 64 bytes.
constexpr size_t kMaxRecord = 3 + 32 + 64;

}  // namespace

bool save(KeyValue& store, const Credentials& credentials) {
    uint8_t record[kMaxRecord];
    const WipeOnExit wipe_record(record, sizeof record);
    const size_t ssid = std::strlen(credentials.ssid), password = std::strlen(credentials.password);
    if (ssid == 0 || ssid > 32 || password > 64) return false;
    size_t n = 0;
    record[n++] = kVersion;
    record[n++] = static_cast<uint8_t>(ssid);
    std::memcpy(record + n, credentials.ssid, ssid);
    n += ssid;
    record[n++] = static_cast<uint8_t>(password);
    std::memcpy(record + n, credentials.password, password);
    n += password;
    return store.put(kKey, record, n);
}

bool load(KeyValue& store, Credentials& credentials) {
    uint8_t record[kMaxRecord];
    const WipeOnExit wipe_record(record, sizeof record);
    size_t length = 0;
    if (!store.get(kKey, record, sizeof record, length)) return false;
    if (length < 3 || record[0] != kVersion) return false;
    const size_t ssid = record[1];
    if (ssid == 0 || ssid > 32 || 2 + ssid + 1 > length) return false;
    const size_t password = record[2 + ssid];
    if (password > 64 || 3 + ssid + password != length) return false;
    Credentials c;
    const WipeOnExit wipe_copy(&c, sizeof c);
    std::memcpy(c.ssid, record + 2, ssid);
    c.ssid[ssid] = 0;
    std::memcpy(c.password, record + 3 + ssid, password);
    c.password[password] = 0;
    credentials = c;
    return true;
}

bool clear(KeyValue& store) { return store.erase(kKey); }

}  // namespace wifi_setup
