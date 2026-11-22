// The deck panel's portable core (#490, #619): it reads DeckBridge's display feed (ADR 0011), holds the deck in front
// and decides what the screen shows. No board, LVGL, Wi-Fi or UDP here: bytes and the time come in, decisions go out
// through `Screen`, so it builds and is tested on the Mac.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "beat_clock.h"
#include "deck_face.h"
#include "deck_types.h"
#include "feed_seq.h"

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

/// Where a datagram came from: Wi-Fi's UDP, or the USB cable (#667), which needs no Wi-Fi.
enum class Source { wifi, cable };

/// Not thread-safe: feed() and render() must run on one task, the loop's. The receive side stamps each datagram as it
/// arrives into feed_intake's fixed queue (dropped and counted when it's full); each frame, the loop drains it into
/// feed(), each datagram at its arrival time, then calls render(). No heap, no exceptions, no RTTI.
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
    /// The firmware's version and SHA as one short line, for every waiting screen (#695); the board sets it once.
    void set_build(const char* label);
    /// Whether the last render() showed the waiting screen (joining and setup included), not the deck: true before the
    /// first render. Hold-to-reset counts only then (#622), never while a deck shows, cable or Wi-Fi (#667).
    bool waiting() const { return shown_waiting_; }
    /// Tells `screen` what to show at `now_ms`, only when that changed since the last call.
    void render(Screen& screen, uint32_t now_ms);
    /// Feed datagrams that never came since boot, from DeckBridge's bundle numbers (#750): Wi-Fi's and the cable's.
    uint32_t lost() const { return seq_[0].lost() + seq_[1].lost(); }
    /// A numbered bundle came on either source: without one (a DeckBridge from before #750) lost() can't tell.
    bool seq_seen() const { return seq_[0].seen() || seq_[1].seen(); }

private:
    WaitingView waiting_view() const;
    /// One message: applied if it's one the panel takes; true if it keeps the feed alive.
    bool apply(const uint8_t* bytes, size_t length, uint32_t now_ms, Source source);

    DeckView view_;
    bool heard_ = false;
    bool goodbye_ = false;  ///< the datagram being read had DeckBridge's goodbye
    /// The deck in front when the datagram being read began (#718): a `playing` 1 to 0 after the front switched in it
    /// is the new deck's, not the master stopping.
    int datagram_deck_ = 0;
    uint32_t last_heard_ms_ = 0;
    /// The USB cable's feed (#667), apart from Wi-Fi's: heard on it, and when last. Within kWaitAfterMs it needs no Wi-Fi.
    bool cable_heard_ = false;
    /// Each source's bundle numbers (#750): [0] Wi-Fi, [1] the cable.
    feed_seq::Counter seq_[2];
    uint32_t last_cable_ms_ = 0;
    Network network_ = Network::connected;
    char ip_[16] = "";
    char setup_name_[24] = "";
    char setup_password_[16] = "";
    char build_[48] = "";
    // What the screen was last told.
    bool shown_ = false;
    bool shown_waiting_ = true;
    DeckView shown_view_;
    int shown_beat_ = 0;  ///< the clock's beat the screen was last told
    BeatClock clock_{BeatClock::kLeadMs};
    /// What the deck page was last told, the face its objects hold; drawn_ once it has been told once.
    Face shown_face_;
    bool drawn_ = false;
    WaitingView shown_waiting_view_;
    bool drawn_waiting_ = false;
};

}  // namespace deck_core
