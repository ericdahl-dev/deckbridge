#include "update_wifi.h"

#include <Arduino.h>
#include <Preferences.h>
#include <errno.h>
#include <esp_ota_ops.h>
#include <esp_partition.h>
#include <lvgl.h>
#include <lwip/sockets.h>

#include <atomic>
#include <cstring>
#include <optional>
#include <string>

#include "release_check.h"
#include "release_keys.h"
#include "update_boot.h"
#include "update_floor.h"
#include "update_link.h"
#include "update_session.h"
#include "wifi_link.h"

LV_FONT_DECLARE(geist_semibold_36)
LV_FONT_DECLARE(geist_regular_24)

// Arduino's initArduino() marks a PENDING_VERIFY image valid at once unless this returns true
// (cores/esp32/esp32-hal-misc.c, a weak C symbol under CONFIG_APP_ROLLBACK_ENABLE, which the shipped sdkconfig sets).
// C linkage, or it wouldn't replace the weak one and every new image would confirm itself unseen. The trial below
// decides instead.
extern "C" bool verifyRollbackLater() { return true; }

namespace update_wifi {
namespace {

constexpr uint16_t kPort = 3310;
// The task's stack. Its deepest path is Link::received -> Session::signature -> crypto_sign_verify_detached
// (libsodium's ref10 double scalar mult: 8 cached points of 160 B, two 256-byte slide arrays, a SHA-512 state; about
// 2.5-3 KB) beside update_manifest::parse (depth-limited, a few hundred bytes) and the frame's std::string copies,
// which are on the heap. esp_ota_write and lwIP's send/recv add about 1 KB. 8 KB leaves over half spare; the high-water
// mark is printed after each connection, so a run on the board shows the real figure.
constexpr uint32_t kStackBytes = 8192;
// Above idle (0) and Arduino's timer task (1), below everything the update needs to run under it on core 0: lwIP's
// tcpip task (18), esp_timer (22, it times the loop's draw hold), Wi-Fi (23). #664's feed task should sit above this.
constexpr UBaseType_t kPriority = 2;
constexpr BaseType_t kCore = 0;
constexpr uint32_t kSelectMs = 100;        // tick() resolution: the link's timeouts are 3 s and 10 s
constexpr uint32_t kSendTimeoutMs = 2000;  // a peer that stops reading can't hold the task
constexpr uint32_t kStillWaitMs = 500;     // longest the first flash write waits for the still screen
constexpr uint32_t kCloseGraceMs = 300;    // "ok switched" reaches the Mac before the restart
constexpr size_t kMaxKeys = 4;

// The floor and the pending record, in their own NVS namespace: wifi_link's is "deckpanel" (key "wifi"), and forgetting
// the Wi-Fi only ever removes that key, so a hold-reset can never lower the floor.
constexpr const char* kNamespace = "deckupdate";
constexpr const char* kFloorKey = "floor";
constexpr const char* kPendFloorKey = "pend_floor";  // the floor Out.floor asked for, set at the switch
constexpr const char* kPendSlotKey = "pend_slot";    // the slot it belongs to (partition label)

// --- Shared between the loop (core 1) and the task (core 0) -------------------------------------------------------
std::atomic<bool> g_network_up{false};
std::atomic<bool> g_listening{false};
std::atomic<bool> g_still_wanted{false};
std::atomic<bool> g_still_on_glass{false};
std::atomic<bool> g_floor_changed{false};

// --- NVS ----------------------------------------------------------------------------------------------------------

std::string nvs_get(const char* key) {
    Preferences prefs;
    if (!prefs.begin(kNamespace, true)) return "";  // read-only fails when the namespace was never written
    char value[32] = "";
    if (prefs.isKey(key)) prefs.getString(key, value, sizeof value);
    prefs.end();
    return value;
}

bool nvs_put(const char* key, const std::string& value) {
    Preferences prefs;
    if (!prefs.begin(kNamespace, false)) return false;
    const bool ok = prefs.putString(key, value.c_str()) == value.size();
    prefs.end();
    return ok;
}

void nvs_drop_pending() {
    Preferences prefs;
    if (!prefs.begin(kNamespace, false)) return;
    if (prefs.isKey(kPendFloorKey)) prefs.remove(kPendFloorKey);
    if (prefs.isKey(kPendSlotKey)) prefs.remove(kPendSlotKey);
    prefs.end();
}

/// Raises the floor to the pending one (never lowers it: lib/update_floor) and drops the record.
void apply_pending() {
    const std::string floor = nvs_get(kFloorKey);
    const std::string next = update_floor::raised(floor, nvs_get(kPendFloorKey));
    if (next != floor) {
        if (nvs_put(kFloorKey, next)) {
            Serial.printf("deck panel: update floor now %s\n", next.c_str());
            g_floor_changed = true;
        } else {
            Serial.println("deck panel: update floor not saved; kept for the next boot");
            return;  // the record stays, and the next boot tries again
        }
    }
    nvs_drop_pending();
}

// --- The still screen ---------------------------------------------------------------------------------------------
// The task asks for it (g_still_wanted) and waits until the loop has it on glass (g_still_on_glass) before the first
// flash erase. The task never calls LVGL.

lv_obj_t* g_still = nullptr;
bool g_shown = false;  // loop task only
bool g_drawn = false;  // the refresh that puts it up has run

void build_still() {
    g_still = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(g_still);
    lv_obj_set_size(g_still, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(g_still, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(g_still, LV_OPA_COVER, 0);
    lv_obj_t* headline = lv_label_create(g_still);
    lv_obj_set_style_text_font(headline, &geist_semibold_36, 0);
    lv_obj_set_style_text_color(headline, lv_color_white(), 0);
    lv_label_set_text(headline, "Updating\xE2\x80\xA6");  // U+2026, in the font
    lv_obj_align(headline, LV_ALIGN_CENTER, 0, -24);
    lv_obj_t* detail = lv_label_create(g_still);
    lv_obj_set_style_text_font(detail, &geist_regular_24, 0);
    lv_obj_set_style_text_color(detail, lv_color_hex(0x9A9A9A), 0);
    lv_label_set_text(detail, "Keep the panel powered. It restarts when done.");
    lv_obj_align(detail, LV_ALIGN_CENTER, 0, 28);
    lv_obj_add_flag(g_still, LV_OBJ_FLAG_HIDDEN);
}

/// Task side: asks for the still screen and waits, bounded, until it is on glass. On a timeout (a stopped panel) the
/// update goes on: the screen is for the eye, not for the flash.
void want_still() {
    g_still_on_glass = false;
    g_still_wanted = true;
    for (uint32_t waited = 0; !g_still_on_glass && waited < kStillWaitMs; waited += 10) vTaskDelay(pdMS_TO_TICKS(10));
}

void release_still() { g_still_wanted = false; }

// --- The spare slot over esp_ota ----------------------------------------------------------------------------------

class OtaSlot : public update_session::Slot {
  public:
    uint32_t capacity() const override {
        const esp_partition_t* next = esp_ota_get_next_update_partition(nullptr);
        return next ? next->size : 0;  // no spare slot: every image is too big
    }

    bool begin(uint32_t size) override {
        part_ = esp_ota_get_next_update_partition(nullptr);
        if (part_ == nullptr) return false;
        // The erase below is the longest stretch with the caches off: the screen goes still first.
        want_still();
        // The real size: only that much is erased (rounded up to sectors), not the whole 6.25 MB slot.
        const esp_err_t err = esp_ota_begin(part_, size, &handle_);
        if (err != ESP_OK) {
            // ESP_ERR_OTA_ROLLBACK_INVALID_STATE: this image is still on trial (it confirms within seconds of Wi-Fi).
            Serial.printf("deck panel: update slot not opened (%s)\n", esp_err_to_name(err));
            release_still();
            return false;
        }
        open_ = true;
        return true;
    }

    bool write(const uint8_t* data, size_t length) override {
        const esp_err_t err = esp_ota_write(handle_, data, length);
        if (err != ESP_OK) Serial.printf("deck panel: update write failed (%s)\n", esp_err_to_name(err));
        return err == ESP_OK;
    }

    bool end() override {
        open_ = false;  // esp_ota_end frees the handle whatever it returns
        const esp_err_t err = esp_ota_end(handle_);  // also checks the image's own header and checksum
        if (err != ESP_OK) Serial.printf("deck panel: update image not accepted (%s)\n", esp_err_to_name(err));
        return err == ESP_OK;
    }

    bool set_boot() override {
        const esp_err_t err = esp_ota_set_boot_partition(part_);
        if (err != ESP_OK) Serial.printf("deck panel: update not set to boot (%s)\n", esp_err_to_name(err));
        return err == ESP_OK;
    }

    void abort() override {
        if (open_) esp_ota_abort(handle_);
        open_ = false;
        release_still();
    }

    const char* label() const { return part_ ? part_->label : ""; }

  private:
    const esp_partition_t* part_ = nullptr;
    esp_ota_handle_t handle_ = 0;
    bool open_ = false;
};

// --- The task -----------------------------------------------------------------------------------------------------
// Everything below is the task's alone once begin() has started it.

OtaSlot g_slot;
release_check::Sha256 g_hasher;
update_session::TrustedKey g_keys[kMaxKeys];
size_t g_key_count = 0;
std::optional<update_link::Link> g_link;
uint8_t g_rx[1460];  // one TCP segment; static, off the task's stack

/// The link over the floor now in NVS. Link copies its Config, so a raised floor needs a new link (idle only).
void make_link() {
    update_session::Config config{g_keys, g_key_count, release_check::signature_ok, &g_hasher, &g_slot,
                                  nvs_get(kFloorKey)};
    g_link.emplace(config);
}

int open_listener() {
    const int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (fd < 0) return -1;
    const int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);  // the station's address and the setup network's alike
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0 || listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

void set_client_options(int fd) {
    timeval timeout = {static_cast<time_t>(kSendTimeoutMs / 1000), static_cast<suseconds_t>(kSendTimeoutMs % 1000 * 1000)};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    const int yes = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
}

void send_lines(int fd, const update_link::Out& out) {
    for (const std::string& text : out.lines) {
        const std::string line = text + "\n";
        size_t sent = 0;
        while (sent < line.size()) {
            const int n = send(fd, line.data() + sent, line.size() - sent, 0);
            if (n <= 0) return;  // the send timeout or a dead peer: the close follows
            sent += static_cast<size_t>(n);
        }
    }
}

void log_stack() {
    Serial.printf("deck panel: update task stack free %u B\n",
                  unsigned(uxTaskGetStackHighWaterMark(nullptr) * sizeof(StackType_t)));
}

/// Acts on what the link said; returns true when `client` is closed.
bool act(int client, const update_link::Out& out) {
    send_lines(client, out);
    if (out.reboot) {
        // The floor is only raised once the new image confirms itself; until then it waits here, tied to its slot.
        if (!out.floor.empty() && !(nvs_put(kPendSlotKey, g_slot.label()) && nvs_put(kPendFloorKey, out.floor)))
            Serial.println("deck panel: update floor not kept for the new image");
        shutdown(client, SHUT_WR);
        vTaskDelay(pdMS_TO_TICKS(kCloseGraceMs));
        close(client);
        Serial.println("deck panel: update switched, restarting");
        Serial.flush();
        esp_restart();
    }
    if (!out.close) return false;
    close(client);
    log_stack();
    return true;
}

void run(void*) {
    int listener = -1;
    int client = -1;
    for (;;) {
        if (listener < 0) {
            // lwIP isn't up until wifi_link starts Wi-Fi; wait for the network, then listen on any address.
            if (!g_network_up) {
                vTaskDelay(pdMS_TO_TICKS(250));
                continue;
            }
            listener = open_listener();
            if (listener < 0) {
                Serial.printf("deck panel: update server not listening (errno %d); retrying\n", errno);
                vTaskDelay(pdMS_TO_TICKS(1000));
                continue;
            }
            g_listening = true;
            Serial.printf("deck panel: update server on port %u\n", unsigned(kPort));
        }
        if (client < 0 && g_floor_changed.exchange(false)) make_link();

        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(listener, &readable);
        if (client >= 0) FD_SET(client, &readable);
        timeval wait = {0, static_cast<suseconds_t>(kSelectMs * 1000)};
        const int ready = select((client > listener ? client : listener) + 1, &readable, nullptr, nullptr, &wait);
        const uint32_t now = millis();
        if (ready < 0) {
            vTaskDelay(pdMS_TO_TICKS(kSelectMs));
            continue;
        }
        if (ready == 0) {
            if (client >= 0 && act(client, g_link->tick(now))) client = -1;
            continue;
        }
        if (FD_ISSET(listener, &readable)) {
            const int fd = accept(listener, nullptr, nullptr);
            if (fd >= 0) {
                set_client_options(fd);
                update_link::Out out;
                if (g_link->accept(fd, now, out)) {
                    client = fd;
                } else {
                    send_lines(fd, out);  // "refused busy"; the running one carries on
                    close(fd);
                }
            }
        }
        if (client >= 0 && FD_ISSET(client, &readable)) {
            const int got = recv(client, g_rx, sizeof g_rx, MSG_DONTWAIT);
            if (got > 0) {
                const update_link::Out out = g_link->received(client, g_rx, static_cast<size_t>(got), now);
                // The erase inside a signature frame takes seconds: the sender's idle time starts now, not before it.
                g_link->received(client, g_rx, 0, millis());
                if (act(client, out)) client = -1;
            } else if (got == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
                g_link->closed(client);  // mid-image: the slot is dropped, the old firmware stays
                close(client);
                client = -1;
                log_stack();
            }
        }
    }
}

// --- The trial (loop task) ----------------------------------------------------------------------------------------

bool g_trial = false;  // read once at boot: this image is PENDING_VERIFY

void trial_chores(uint32_t now_ms) {
    if (!g_trial) return;
    update_boot::State state;
    state.trial = true;
    state.saved_wifi = wifi_link::state() != deck_core::Network::setup;
    state.wifi_joined = wifi_link::state() == deck_core::Network::connected;
    state.setup_network_up = wifi_link::setup_up();
    state.update_listening = g_listening;
    state.since_boot_ms = now_ms;
    switch (update_boot::decide(state)) {
        case update_boot::Decision::confirm: {
            g_trial = false;
            const esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
            if (err != ESP_OK) {
                Serial.printf("deck panel: update not confirmed (%s)\n", esp_err_to_name(err));
                return;  // stays a trial in otadata: the next reset rolls back
            }
            Serial.println("deck panel: update confirmed");
            apply_pending();
            return;
        }
        case update_boot::Decision::roll_back: {
            g_trial = false;  // once: a failed rollback isn't retried every frame
            Serial.println("deck panel: update didn't bring Wi-Fi and the update server up; rolling back");
            Serial.flush();
            nvs_drop_pending();
            const esp_err_t err = esp_ota_mark_app_invalid_rollback_and_reboot();  // returns only on failure
            Serial.printf("deck panel: rollback failed (%s); running on\n", esp_err_to_name(err));
            return;
        }
        default: return;
    }
}

}  // namespace

void begin() {
    const esp_partition_t* running = esp_ota_get_running_partition();
    esp_ota_img_states_t ota_state;
    g_trial = running != nullptr && esp_ota_get_state_partition(running, &ota_state) == ESP_OK &&
              ota_state == ESP_OTA_IMG_PENDING_VERIFY;
    // A pending floor belongs to the slot it was sent for. Running another slot: a rollback, or a cable flash, so drop
    // it. Running that slot but not on trial: it confirmed and lost power before the floor was saved, so save it now.
    const std::string pending_slot = nvs_get(kPendSlotKey);
    if (!pending_slot.empty() || !nvs_get(kPendFloorKey).empty()) {
        if (running == nullptr || pending_slot != running->label) {
            nvs_drop_pending();
        } else if (!g_trial) {
            apply_pending();
        }
    }
    if (g_trial) Serial.printf("deck panel: new image on trial, %u s to bring Wi-Fi up\n", unsigned(update_boot::kTrialMs / 1000));

    g_key_count = release_keys::trusted(release_keys::kListed, g_keys, kMaxKeys);
    if (g_key_count == 0) Serial.println("deck panel: no release keys built in; Wi-Fi updates are refused");
    g_floor_changed = false;
    make_link();
    build_still();
    if (xTaskCreatePinnedToCore(run, "update", kStackBytes, nullptr, kPriority, nullptr, kCore) != pdPASS) {
        // No server: a trial can't confirm and rolls back, which is right; a confirmed image runs on without updates.
        Serial.println("deck panel: no update task; Wi-Fi updates are off");
    }
}

void chores(uint32_t now_ms) {
    g_network_up = wifi_link::state() == deck_core::Network::connected || wifi_link::setup_up();
    trial_chores(now_ms);
}

bool hold_render() {
    const bool want = g_still_wanted;
    if (want && !g_shown) {
        lv_obj_remove_flag(g_still, LV_OBJ_FLAG_HIDDEN);
        g_shown = true;
        g_drawn = false;
        return true;
    }
    if (!want && g_shown) {
        // The update ended without a switch: the deck underneath redraws where the still screen was.
        lv_obj_add_flag(g_still, LV_OBJ_FLAG_HIDDEN);
        g_shown = false;
        g_still_on_glass = false;
        return false;
    }
    // render() runs after the frame's latch wait: a refresh handed over last frame is on glass by now.
    if (g_shown && g_drawn) g_still_on_glass = true;
    return g_shown;
}

bool hold_refresh() {
    if (!g_shown) return false;
    if (g_drawn) return true;
    g_drawn = true;
    return false;
}

}  // namespace update_wifi
