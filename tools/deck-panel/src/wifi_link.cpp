#include "wifi_link.h"

#include <Arduino.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>
#include <bootloader_random.h>
#include <esp_mac.h>
#include <esp_random.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "wifi_ap.h"
#include "wifi_form.h"
#include "wifi_page.h"
#include "wifi_store.h"
#include "wipe.h"

namespace wifi_link {

namespace {

using deck_core::Network;

/// The core retries most disconnects itself, but not an AP that refused the password after the first try, which a
/// router coming back can do: then a kick this long after the last one.
constexpr uint32_t kKickAfterMs = 30000;
constexpr uint32_t kAddressEveryMs = 500;
/// A page asked for this long after the last scan finished starts another.
constexpr uint32_t kRescanAfterMs = 10000;
/// After a good form: time for the "saved" page to reach the phone before the restart.
constexpr uint32_t kRestartAfterMs = 1000;
/// The setup form urlencoded is under 600 bytes; anything past this is refused, not truncated.
constexpr size_t kMaxBody = 1024;
constexpr size_t kMaxSeen = 24;

constexpr char kSetupIp[] = "192.168.4.1";

// --- The saved network, in NVS ---------------------------------------------------------------------------------

/// wifi_store's key-value store over Preferences, namespace "deckpanel". Each call opens and closes the namespace, so
/// nothing stays open between the boot's load and a save or forget.
class PrefsStore : public wifi_setup::KeyValue {
  public:
    bool get(const char* key, uint8_t* out, size_t room, size_t& length) override {
        Preferences prefs;
        if (!prefs.begin(kNamespace, true)) return false;  // read-only fails when the namespace was never written
        bool ok = false;
        if (prefs.isKey(key)) {
            const size_t n = prefs.getBytesLength(key);
            if (n > 0 && n <= room && prefs.getBytes(key, out, n) == n) {
                length = n;
                ok = true;
            }
        }
        prefs.end();
        return ok;
    }

    bool put(const char* key, const uint8_t* bytes, size_t length) override {
        Preferences prefs;
        if (!prefs.begin(kNamespace, false)) return false;
        const bool ok = prefs.putBytes(key, bytes, length) == length;
        prefs.end();
        return ok;
    }

    bool erase(const char* key) override {
        Preferences prefs;
        if (!prefs.begin(kNamespace, false)) return false;
        const bool ok = !prefs.isKey(key) || prefs.remove(key);
        prefs.end();
        return ok;
    }

  private:
    static constexpr const char* kNamespace = "deckpanel";
};

PrefsStore g_store;
wifi_setup::Credentials g_saved;  // the station's network; never printed but its name
bool g_prepared = false;

// --- State -----------------------------------------------------------------------------------------------------

Network g_state = Network::setup;
char g_ip[16] = "";
uint32_t g_address = 0;
uint32_t g_joins = 0;
uint32_t g_down_since_ms = 0;
uint32_t g_address_read_ms = 0;
bool g_started = false;

// Setup only.
char g_setup_name[24] = "";
char g_setup_password[16] = "";  // on the panel's screen only
bool g_setup_up = false;         // the AP, DNS and web server are running
DNSServer g_dns;
WebServer g_server(80);
char g_body[kMaxBody];
size_t g_body_length = 0;
bool g_body_overflow = false;
bool g_body_seen = false;  // this request's body came in raw chunks (RAW_START)
const char* g_error = "";

struct SeenCopy {
    char ssid[33];
    int rssi;
};
SeenCopy g_seen[kMaxSeen];
size_t g_seen_count = 0;
bool g_scanning = false;
bool g_scan_wanted = false;
uint32_t g_scanned_ms = 0;
bool g_scanned_once = false;

bool g_restart_pending = false;
uint32_t g_restart_at_ms = 0;

void set_address(uint32_t address) {
    g_address = address;
    if (address == 0) {
        g_ip[0] = 0;
        return;
    }
    // IPAddress keeps the first octet in the low byte.
    std::snprintf(g_ip, sizeof g_ip, "%u.%u.%u.%u", unsigned(address & 0xFF), unsigned(address >> 8 & 0xFF),
                  unsigned(address >> 16 & 0xFF), unsigned(address >> 24));
}

/// Loads the saved network, once; with none, picks the setup network's name and password, so the first frame (before
/// begin) can show them.
void prepare() {
    if (g_prepared) return;
    g_prepared = true;
    if (wifi_setup::load(g_store, g_saved)) {
        g_state = Network::joining;
        return;
    }
    g_state = Network::setup;
    std::snprintf(g_ip, sizeof g_ip, "%s", kSetupIp);
    // The softAP's MAC: what a phone sees as the network's BSSID. Readable from eFuse before Wi-Fi starts.
    uint8_t mac[6] = {};
    if (esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP) != ESP_OK) Serial.println("deck panel: no softAP MAC; name from zeros");
    wifi_setup::network_name(mac, g_setup_name, sizeof g_setup_name);
    // esp_random is only true-random with the radio on, and the radio isn't on yet: the bootloader's entropy source
    // (the SAR ADC) stands in until then. Nothing else uses the ADC this early.
    bootloader_random_enable();
    wifi_setup::setup_password([] { return esp_random(); }, g_setup_password, sizeof g_setup_password);
    bootloader_random_disable();
}

// --- Station ---------------------------------------------------------------------------------------------------

/// Starts the station; false if the driver didn't start, and poll() tries again.
bool start_station() {
    WiFi.persistent(false);  // the credentials stay in our own NVS record, not copied into the driver's too
    if (!WiFi.mode(WIFI_STA)) {
        Serial.println("deck panel: Wi-Fi didn't start; retrying");
        return false;
    }
    WiFi.setAutoReconnect(true);
    // Modem sleep holds received packets up to a beacon interval (~100 ms); the panel is on mains power.
    if (!WiFi.setSleep(false)) Serial.println("deck panel: Wi-Fi sleep stays on");
    if (WiFi.begin(g_saved.ssid, g_saved.password) == WL_CONNECT_FAILED) {
        Serial.println("deck panel: Wi-Fi join didn't start; retrying");
    }
    Serial.printf("deck panel: joining Wi-Fi \"%s\"\n", g_saved.ssid);
    return true;
}

void poll_station(uint32_t now_ms) {
    if (!g_started) {
        if (now_ms - g_down_since_ms < kKickAfterMs) return;
        g_down_since_ms = now_ms;
        g_started = start_station();
        return;
    }
    const bool up = WiFi.status() == WL_CONNECTED;
    if (up) {
        if (g_state != Network::connected || now_ms - g_address_read_ms >= kAddressEveryMs) {
            g_address_read_ms = now_ms;
            const uint32_t address = static_cast<uint32_t>(WiFi.localIP());
            if (address == 0) return;  // connected but no address yet: still joining
            if (g_state != Network::connected) {
                ++g_joins;
                g_state = Network::connected;
                set_address(address);
                Serial.printf("deck panel: on Wi-Fi at %s, feed port %u\n", g_ip,
                              unsigned(deck_core::DeckCore::kFeedPort));
            } else if (address != g_address) {
                set_address(address);
                Serial.printf("deck panel: address now %s\n", g_ip);
            }
        }
        return;
    }
    if (g_state == Network::connected) {
        g_state = Network::joining;
        set_address(0);
        g_down_since_ms = now_ms;
        Serial.println("deck panel: Wi-Fi lost, rejoining");
    }
    if (now_ms - g_down_since_ms >= kKickAfterMs) {
        g_down_since_ms = now_ms;
        if (!WiFi.reconnect()) Serial.println("deck panel: Wi-Fi rejoin didn't start");
    }
}

// --- Setup -----------------------------------------------------------------------------------------------------

void start_scan() {
    // Async: returns at once, WIFI_SCAN_RUNNING; poll_scan() collects. Needs the STA half of WIFI_AP_STA.
    if (WiFi.scanNetworks(true) == WIFI_SCAN_FAILED) {
        Serial.println("deck panel: Wi-Fi scan didn't start");
        // Counts as a scan, so the next try waits for a page load past kRescanAfterMs, not the next loop pass.
        g_scanning = false;
        g_scan_wanted = false;
        g_scanned_ms = millis();
        g_scanned_once = true;
        return;
    }
    g_scanning = true;
    g_scan_wanted = false;
}

/// Copies a finished scan into g_seen (the driver's list is freed after) and starts one a page asked for.
void poll_scan(uint32_t now_ms) {
    if (g_scanning) {
        const int16_t n = WiFi.scanComplete();
        if (n == WIFI_SCAN_RUNNING) return;
        g_scanning = false;
        g_scanned_ms = now_ms;
        g_scanned_once = true;
        if (n >= 0) {
            g_seen_count = 0;
            for (int16_t i = 0; i < n && g_seen_count < kMaxSeen; ++i) {
                SeenCopy& s = g_seen[g_seen_count];
                std::snprintf(s.ssid, sizeof s.ssid, "%s", WiFi.SSID(i).c_str());
                s.rssi = WiFi.RSSI(i);
                if (s.ssid[0]) ++g_seen_count;  // hidden networks have no name to pick
            }
            Serial.printf("deck panel: scan saw %d networks\n", int(n));
        } else {
            Serial.println("deck panel: Wi-Fi scan failed; keeping the last list");
        }
        WiFi.scanDelete();
    }
    if (g_scan_wanted) start_scan();
}

void send_page(const char* error) {
    wifi_setup::Seen seen[kMaxSeen];
    for (size_t i = 0; i < g_seen_count; ++i) seen[i] = {g_seen[i].ssid, g_seen[i].rssi};
    const std::string page = wifi_setup::setup_page(seen, g_seen_count, error, g_setup_name);
    g_server.sendHeader("Cache-Control", "no-store");
    g_server.send(200, "text/html; charset=utf-8", page.c_str());
}

/// GET / and every path nobody else claims: the captive-portal probes (/generate_204, /hotspot-detect.html, ...)
/// asked for another host get sent to the panel's page, which makes the phone open it.
void handle_page() {
    const String host = g_server.hostHeader();
    if (host.length() && host != kSetupIp) {
        g_server.sendHeader("Location", String("http://") + kSetupIp + "/");
        g_server.send(302, "text/plain", "");
        return;
    }
    if (!g_scanning && (!g_scanned_once || millis() - g_scanned_ms >= kRescanAfterMs)) g_scan_wanted = true;
    send_page(g_error);
}

void wipe_body() {
    std::memset(g_body, 0, sizeof g_body);
    g_body_length = 0;
}

/// The body, as posted, in raw chunks instead of decoded args, so parse_form sees the real bytes. Called only for a
/// non-multipart POST (SaveHandler takes no uploads), with the core's HTTPRaw passed in, never fetched.
void handle_save_body(HTTPRaw& raw) {
    switch (raw.status) {
        case RAW_START:
            g_body_length = 0;
            g_body_overflow = false;
            g_body_seen = true;
            break;
        case RAW_WRITE:
            if (g_body_overflow || raw.currentSize > sizeof g_body - g_body_length) {
                // Too big for any form: close the socket, so the core's next read gets 0 and aborts the request,
                // instead of reading on to Content-Length in 5 s waits while the loop (screen, touch) stands still.
                if (!g_body_overflow) g_server.client().stop();
                g_body_overflow = true;
                break;
            }
            std::memcpy(g_body + g_body_length, raw.buf, raw.currentSize);
            g_body_length += raw.currentSize;
            break;
        case RAW_END:
            break;
        case RAW_ABORTED:
            // An incomplete body is no form, and handle_save never runs for it: wipe what came, it may hold the password.
            wipe_body();
            g_body_overflow = false;
            g_body_seen = false;
            break;
    }
    std::memset(raw.buf, 0, sizeof raw.buf);  // the chunk may hold the password
}


void handle_save() {
    if (g_restart_pending) {
        g_server.send(200, "text/html; charset=utf-8", wifi_setup::saved_page(g_saved.ssid).c_str());
        return;
    }
    if (g_body_overflow || !g_body_seen) {  // not seen: a multipart post, which the form never sends
        g_body_seen = false;
        wipe_body();
        g_body_overflow = false;
        g_error = "That form didn't arrive whole. Try again.";
        send_page(g_error);
        return;
    }
    g_body_seen = false;
    wifi_setup::FormResult form = wifi_setup::parse_form(g_body, g_body_length);
    wipe_body();
    if (!form.ok) {
        g_error = form.error;
        send_page(g_error);
        return;
    }
    const bool saved = wifi_setup::save(g_store, form.credentials);
    if (!saved) {
        wifi_setup::wipe(&form.credentials, sizeof form.credentials);
        g_error = "The panel couldn't save that. Try again.";
        Serial.println("deck panel: Wi-Fi save failed");
        send_page(g_error);
        return;
    }
    std::snprintf(g_saved.ssid, sizeof g_saved.ssid, "%s", form.credentials.ssid);  // the name only, for the page
    wifi_setup::wipe(&form.credentials, sizeof form.credentials);
    g_server.send(200, "text/html; charset=utf-8", wifi_setup::saved_page(g_saved.ssid).c_str());
    Serial.printf("deck panel: Wi-Fi \"%s\" saved, restarting\n", g_saved.ssid);
    g_restart_pending = true;
    g_restart_at_ms = millis() + kRestartAfterMs;
}

/// POST /save. WebServer's on(uri, method, fn, ufn) hands multipart file parts to the same ufn as raw bodies, where
/// raw() would dereference an empty pointer and panic. This handler says no to uploads, so only raw bodies reach it.
class SaveHandler : public RequestHandler {
  public:
    bool canHandle(WebServer&, HTTPMethod method, const String& uri) override {
        return method == HTTP_POST && uri == "/save";
    }
    bool canUpload(WebServer&, const String&) override { return false; }
    bool canRaw(WebServer&, const String& uri) override { return uri == "/save"; }
    bool handle(WebServer&, HTTPMethod, const String&) override {
        handle_save();
        return true;
    }
    void raw(WebServer&, const String&, HTTPRaw& raw) override { handle_save_body(raw); }
};
SaveHandler g_save_handler;

/// The setup network: false if the driver didn't start, and poll() tries again.
bool start_setup() {
    WiFi.persistent(false);
    if (!WiFi.mode(WIFI_AP_STA)) {  // the STA half scans
        Serial.println("deck panel: Wi-Fi didn't start; retrying");
        return false;
    }
    if (!WiFi.setSleep(false)) Serial.println("deck panel: Wi-Fi sleep stays on");
    const IPAddress ap(192, 168, 4, 1), mask(255, 255, 255, 0);
    if (!WiFi.softAPConfig(ap, ap, mask)) Serial.println("deck panel: setup network address not set");
    if (!WiFi.softAP(g_setup_name, g_setup_password)) {  // WPA2-PSK, the core's default with a password
        Serial.println("deck panel: setup network didn't start; retrying");
        return false;
    }
    // Every name answers with the panel, so the phone's captive-portal check lands on the page. Setup only.
    if (!g_dns.start(53, "*", ap)) Serial.println("deck panel: setup DNS didn't start");
    g_server.on("/", HTTP_GET, handle_page);
    g_server.addHandler(&g_save_handler);
    g_server.onNotFound(handle_page);
    // No 1 ms sleep in handleClient() with no client: the loop's only pause is the frame clock's wait (#663).
    g_server.enableDelay(false);
    g_server.begin();
    Serial.printf("deck panel: setup network %s up, page at http://%s/\n", g_setup_name, kSetupIp);
    start_scan();
    return true;
}

void poll_setup(uint32_t now_ms) {
    if (!g_setup_up) {
        if (now_ms - g_down_since_ms < kKickAfterMs) return;
        g_down_since_ms = now_ms;
        g_setup_up = start_setup();
        return;
    }
    g_dns.processNextRequest();  // a no-op in this core (its DNSServer answers on AsyncUDP); kept for older cores
    g_server.handleClient();
    poll_scan(now_ms);
    if (g_restart_pending && static_cast<int32_t>(now_ms - g_restart_at_ms) >= 0) {
        Serial.flush();
        esp_restart();
    }
}

}  // namespace

void begin() {
    prepare();
    g_down_since_ms = millis();
    if (g_state == Network::setup) {
        g_setup_up = start_setup();
        return;
    }
    g_started = start_station();
}

void poll(uint32_t now_ms) {
    if (g_state == Network::setup) {
        poll_setup(now_ms);
    } else {
        poll_station(now_ms);
    }
}

Network state() {
    prepare();
    return g_state;
}

const char* ip() { return g_ip; }

const char* setup_name() {
    prepare();
    return g_setup_name;
}

const char* setup_password() {
    prepare();
    return g_setup_password;
}

uint32_t joins() { return g_joins; }

void forget_and_restart() {
    if (!wifi_setup::clear(g_store)) Serial.println("deck panel: Wi-Fi forget failed");
    Serial.println("deck panel: Wi-Fi forgotten, restarting into setup");
    Serial.flush();
    esp_restart();
}

}  // namespace wifi_link
