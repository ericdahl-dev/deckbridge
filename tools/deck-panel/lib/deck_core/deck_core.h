// The deck panel's portable core (#490, #619): it reads DeckBridge's display feed (ADR 0011), holds the deck in front
// and decides what the screen shows. No board, LVGL, Wi-Fi or UDP here: bytes and the time come in, decisions go out
// through `Screen`, so it builds and is tested on the Mac.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "deck_face.h"
#include "deck_types.h"

namespace deck_core {

/// The board layer draws what the core decides.
struct Screen {
    virtual ~Screen() = default;
    /// The waiting page shows `view`, the core's own until the next call; only `changes` differ from what it holds.
    virtual void show_waiting(const WaitingView& view, const WaitingChanges& changes) = 0;
    /// The deck page shows `face`; only the parts in `changes` differ from what its objects hold. `face` is the core's
    /// own and stays as it is until the next call, so the board may point its objects' texts at it.
    virtual void show_deck(const Face& face, const Changes& changes) = 0;
};

/// Not thread-safe: feed() and render() must run on one task. On the board, the UDP task copies each payload into a
/// fixed-size queue item (dropped if the queue is full) and the loop task drains the queue into feed(), then calls
/// render() every frame. No heap, no exceptions, no RTTI.
/// Where a datagram came from: Wi-Fi's UDP, or the USB cable (#667), which needs no Wi-Fi.
enum class Source { wifi, cable };

class DeckCore {
public:
    DeckCore() = default;
    /// Not copied: the screen's labels point at this core's held face and waiting view.
    DeckCore(const DeckCore&) = delete;
    DeckCore& operator=(const DeckCore&) = delete;

    /// No feed for this long and the panel shows the waiting screen (#490).
    static constexpr uint32_t kWaitAfterMs = 3000;
    /// The UDP port the panel listens on for the feed: DeckBridge's default (#616).
    static constexpr uint16_t kFeedPort = 9100;

    /// One UDP payload, a message or a bundle of them (#636), received at `now_ms` (any millisecond clock; it may wrap).
    void feed(const uint8_t* bytes, size_t length, uint32_t now_ms, Source source = Source::wifi);
    /// What the core holds now, for the perf env's capture (#636); the screen gets it through render().
    const DeckView& view() const { return view_; }
    /// The network's state and the panel's IPv4 address ("" if none), from the board layer.
    /// Until told, the core takes the network as up: on the Mac, and for any board without Wi-Fi of its own.
    void set_network(Network state, const char* ip);
    /// The setup network's name and password, for the waiting screen while Network::setup (#622).
    void set_setup(const char* name, const char* password);
    /// Whether the last render() showed the waiting screen (joining and setup included), not the deck: true before the
    /// first render. Hold-to-reset counts only then (#622).
    bool waiting() const { return shown_waiting_; }
    /// Whether hold-to-reset counts (#622): on the waiting screen, and off Wi-Fi even with the cable's deck up (#667).
    bool hold_resets_wifi() const { return shown_waiting_ || network_ != Network::connected; }
    /// Tells `screen` what to show at `now_ms`, only when that changed since the last call.
    void render(Screen& screen, uint32_t now_ms);

private:
    WaitingView waiting_view() const;
    /// One message: applied if it's one the panel takes; true if it keeps the feed alive.
    bool apply(const uint8_t* bytes, size_t length);

    DeckView view_;
    bool heard_ = false;
    bool goodbye_ = false;  ///< the datagram being read had DeckBridge's goodbye
    uint32_t last_heard_ms_ = 0;
    /// The USB cable's feed (#667), apart from Wi-Fi's: heard on it, and when last. Within kWaitAfterMs it needs no Wi-Fi.
    bool cable_heard_ = false;
    uint32_t last_cable_ms_ = 0;
    Network network_ = Network::connected;
    char ip_[16] = "";
    char setup_name_[24] = "";
    char setup_password_[16] = "";
    // What the screen was last told.
    bool shown_ = false;
    bool shown_waiting_ = true;
    DeckView shown_view_;
    /// What the deck page was last told, the face its objects hold; drawn_ once it has been told once.
    Face shown_face_;
    bool drawn_ = false;
    WaitingView shown_waiting_view_;
    bool drawn_waiting_ = false;
};

}  // namespace deck_core
