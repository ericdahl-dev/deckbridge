// The saved Wi-Fi (#622): one record in the panel's key-value store (NVS on the board), so it survives a power cycle
// and a reset forgets it.
#include <unity.h>

#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "wifi_store.h"

void setUp() {}
void tearDown() {}

struct FakeStore : wifi_setup::KeyValue {
    std::map<std::string, std::vector<uint8_t>> values;
    bool fail_put = false;
    bool get(const char* key, uint8_t* out, size_t room, size_t& length) override {
        auto it = values.find(key);
        if (it == values.end() || it->second.size() > room) return false;
        std::memcpy(out, it->second.data(), it->second.size());
        length = it->second.size();
        return true;
    }
    bool put(const char* key, const uint8_t* bytes, size_t length) override {
        if (fail_put) return false;
        values[key] = std::vector<uint8_t>(bytes, bytes + length);
        return true;
    }
    bool erase(const char* key) override {
        values.erase(key);
        return true;
    }
};

static wifi_setup::Credentials home() {
    wifi_setup::Credentials c;
    std::strcpy(c.ssid, "Home Net");
    std::strcpy(c.password, "secret123");
    return c;
}

void test_a_saved_network_loads_back() {
    FakeStore store;
    TEST_ASSERT_TRUE(wifi_setup::save(store, home()));
    wifi_setup::Credentials got;
    TEST_ASSERT_TRUE(wifi_setup::load(store, got));
    TEST_ASSERT_EQUAL_STRING("Home Net", got.ssid);
    TEST_ASSERT_EQUAL_STRING("secret123", got.password);
}

void test_nothing_saved_or_cleared_loads_nothing() {
    FakeStore store;
    wifi_setup::Credentials got;
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
    wifi_setup::save(store, home());
    TEST_ASSERT_TRUE(wifi_setup::clear(store));
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
}

void test_a_record_this_firmware_did_not_write_loads_nothing() {
    FakeStore store;
    wifi_setup::Credentials got;
    store.values["wifi"] = {2, 1, 'a', 0};  // another version
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
    store.values["wifi"] = {1, 5, 'a', 'b'};  // cut short
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
    store.values["wifi"] = {1, 0, 0};  // no name
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
    store.values["wifi"] = {1, 1, 'a', 0, 9};  // a byte left over
    TEST_ASSERT_FALSE(wifi_setup::load(store, got));
}

void test_a_store_that_refuses_the_write_reports_it() {
    FakeStore store;
    store.fail_put = true;
    TEST_ASSERT_FALSE(wifi_setup::save(store, home()));
}

int main() {
    UNITY_BEGIN();
    RUN_TEST(test_a_saved_network_loads_back);
    RUN_TEST(test_nothing_saved_or_cleared_loads_nothing);
    RUN_TEST(test_a_record_this_firmware_did_not_write_loads_nothing);
    RUN_TEST(test_a_store_that_refuses_the_write_reports_it);
    return UNITY_END();
}
