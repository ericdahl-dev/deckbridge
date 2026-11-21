#include "deck_core.h"

#include <cstdio>
#include <cstring>

#include "font_fallback.h"

namespace deck_core {

namespace {

const char kPrefix[] = "/DeckBridge/Display/";

/// `text` (valid UTF-8) into `out` at most `limit` characters: a longer one is cut between characters, spaces before
/// the cut dropped, and ends in "…". `out` holds `limit` characters of 4 bytes and a NUL.
/// A control character (a line break, a tab) as a space, so the board's one-line label stays one line.
char shown(char c) {
    auto byte = static_cast<uint8_t>(c);
    return byte < 0x20 || byte == 0x7F ? ' ' : c;
}

void shorten(const char* text, size_t limit, char* out) {
    size_t characters = 0, n = 0;
    for (const char* p = text; *p; ++p) {
        bool starts_character = (static_cast<uint8_t>(*p) & 0xC0) != 0x80;
        if (starts_character && ++characters == limit) {
            // The limit-th character: whole only if it is the last.
            size_t rest = 0;
            for (const char* q = p; *q; ++q) rest += (static_cast<uint8_t>(*q) & 0xC0) != 0x80;
            if (rest == 1) {
                while (*p) out[n++] = shown(*p++);
            } else {
                while (n > 0 && out[n - 1] == ' ') --n;
                std::memcpy(out + n, "\xE2\x80\xA6", 3);
                n += 3;
            }
            break;
        }
        out[n++] = shown(*p);
    }
    out[n] = 0;
}

/// One OSC message with one value, as the feed sends (ADR 0011).
struct Message {
    const char* name = nullptr;  ///< the address after the prefix
    char type = 0;  ///< i, f or s
    int32_t i = 0;
    float f = 0;  ///< for the float rows #617 adds (bpm, tempo, progress, phase, level); negatives too
    const char* s = nullptr;
};

/// Reads a padded OSC string at `at`; returns its length, or -1 if it doesn't fit.
long read_string(const uint8_t* bytes, size_t length, size_t at) {
    for (size_t i = at; i < length; ++i) {
        if (bytes[i] == 0) return static_cast<long>(i - at);
    }
    return -1;
}

size_t padded(size_t n) { return (n + 4) & ~size_t(3); }

/// Well-formed UTF-8: no stray, cut-short, overlong or surrogate sequences, nothing past U+10FFFF.
bool valid_utf8(const char* text) {
    const auto* p = reinterpret_cast<const uint8_t*>(text);
    while (*p) {
        uint8_t lead = *p++;
        int more;
        uint32_t code;
        if (lead < 0x80) continue;
        if (lead >= 0xC2 && lead <= 0xDF) { more = 1; code = lead & 0x1F; }
        else if (lead >= 0xE0 && lead <= 0xEF) { more = 2; code = lead & 0x0F; }
        else if (lead >= 0xF0 && lead <= 0xF4) { more = 3; code = lead & 0x07; }
        else return false;
        for (int i = 0; i < more; ++i, ++p) {
            if ((*p & 0xC0) != 0x80) return false;
            code = code << 6 | (*p & 0x3F);
        }
        if ((more == 2 && code < 0x800) || (more == 3 && code < 0x10000) || code > 0x10FFFF) return false;
        if (code >= 0xD800 && code <= 0xDFFF) return false;
    }
    return true;
}

bool parse(const uint8_t* bytes, size_t length, Message& out) {
    if (length % 4 != 0) return false;
    long address_length = read_string(bytes, length, 0);
    if (address_length < 0) return false;
    const char* address = reinterpret_cast<const char*>(bytes);
    if (std::strncmp(address, kPrefix, sizeof kPrefix - 1) != 0) return false;
    size_t at = padded(static_cast<size_t>(address_length));
    long tags_length = read_string(bytes, length, at);
    if (tags_length != 2 || bytes[at] != ',') return false;
    out.name = address + sizeof kPrefix - 1;
    out.type = static_cast<char>(bytes[at + 1]);
    at += padded(2);
    switch (out.type) {
        case 'i':
        case 'f':
            if (at + 4 > length) return false;
            out.i = static_cast<int32_t>(uint32_t(bytes[at]) << 24 | uint32_t(bytes[at + 1]) << 16 |
                                         uint32_t(bytes[at + 2]) << 8 | uint32_t(bytes[at + 3]));
            std::memcpy(&out.f, &out.i, sizeof out.f);  // an f's 32 bits are an IEEE 754 float, big-endian like an i
            return true;
        case 's':
            if (read_string(bytes, length, at) < 0) return false;
            out.s = reinterpret_cast<const char*>(bytes + at);
            return valid_utf8(out.s);
        default:
            return false;
    }
}

/// A row that takes any value: stores it.
template <typename T, typename V>
bool set(T& field, V value) {
    field = static_cast<T>(value);
    return true;
}

/// The feed's addresses: one row each, its OSC type and what it sets (ADR 0011).
struct Row {
    const char* name;
    char type;
    /// Sets the value; false if it's out of range, which leaves the view as it was.
    bool (*apply)(DeckView&, const Message&);
};

const Row kRows[] = {
    {"deck", 'i',
     [](DeckView& v, const Message& m) {
         if (m.i < 1 || m.i > 4) return false;
         v.deck = m.i;
         return true;
     }},
    {"color", 'i',
     [](DeckView& v, const Message& m) {
         v.color = static_cast<uint32_t>(m.i) & 0xFFFFFF;
         return true;
     }},
    {"title", 's',
     [](DeckView& v, const Message& m) {
         shorten(m.s, kTitleMax, v.title);
         return true;
     }},
    {"artist", 's',
     [](DeckView& v, const Message& m) {
         shorten(m.s, kArtistMax, v.artist);
         return true;
     }},
    // #617's fields.
    {"loaded", 'i', [](DeckView& v, const Message& m) { return set(v.loaded, m.i != 0); }},
    {"key", 's',
     [](DeckView& v, const Message& m) {
         shorten(m.s, kKeyMax, v.key);
         return true;
     }},
    {"bpm", 'f', [](DeckView& v, const Message& m) { return set(v.bpm, m.f); }},
    {"clockBpm", 'f', [](DeckView& v, const Message& m) { return set(v.clock_bpm, m.f); }},
    {"tempo", 'f', [](DeckView& v, const Message& m) { return set(v.tempo, m.f); }},
    {"playing", 'i', [](DeckView& v, const Message& m) { return set(v.playing, m.i != 0); }},
    {"cue", 'i', [](DeckView& v, const Message& m) { return set(v.cue, m.i != 0); }},
    {"sync", 'i', [](DeckView& v, const Message& m) { return set(v.sync, m.i != 0); }},
    {"master", 'i', [](DeckView& v, const Message& m) { return set(v.master, m.i != 0); }},
    {"loop", 'i', [](DeckView& v, const Message& m) { return set(v.loop, m.i != 0); }},
    {"loopLength", 'f', [](DeckView& v, const Message& m) { return set(v.loop_length, m.f); }},
    {"beat", 'i', [](DeckView& v, const Message& m) { return set(v.beat, static_cast<int>(m.i)); }},
    {"elapsed", 'i', [](DeckView& v, const Message& m) { return set(v.elapsed, m.i); }},
    {"remaining", 'i', [](DeckView& v, const Message& m) { return set(v.remaining, m.i); }},
    {"progress", 'f', [](DeckView& v, const Message& m) { return set(v.progress, m.f); }},
    {"phase", 'f', [](DeckView& v, const Message& m) { return set(v.phase, m.f); }},
    {"level", 'f', [](DeckView& v, const Message& m) { return set(v.level, m.f); }},
};

}  // namespace

void DeckCore::feed(const uint8_t* bytes, size_t length, uint32_t now_ms, Source source) {
    static const char kBundle[8] = {'#', 'b', 'u', 'n', 'd', 'l', 'e', 0};
    bool alive = false;
    if (length >= 16 && std::memcmp(bytes, kBundle, 8) == 0) {
        // A bundle (#636): "#bundle", a timetag (ignored: the feed's are "immediately"), then elements, each a size
        // and that many bytes. One arrival for the whole bundle.
        size_t at = 16;
        while (at + 4 <= length) {
            const uint32_t size = uint32_t(bytes[at]) << 24 | uint32_t(bytes[at + 1]) << 16 |
                                  uint32_t(bytes[at + 2]) << 8 | uint32_t(bytes[at + 3]);
            at += 4;
            if (size == 0 || size % 4 != 0 || size > length - at) break;  // the framing can't be trusted past here
            alive = apply(bytes + at, size, now_ms) || alive;
            at += size;
        }
    } else {
        alive = apply(bytes, length, now_ms);
    }
    if (goodbye_) {
        // The waiting screen at once; the deck is kept for the next snapshot.
        goodbye_ = false;
        heard_ = false;
        return;
    }
    if (!alive) return;
    heard_ = true;
    if (source == Source::cable) {
        cable_heard_ = true;
        last_cable_ms_ = now_ms;
    }
    last_heard_ms_ = now_ms;
}

bool DeckCore::apply(const uint8_t* bytes, size_t length, uint32_t now_ms) {
    Message message;
    if (!parse(bytes, length, message)) return false;
    // DeckBridge's goodbye (ADR 0011, #651): not the deck's state but the feed's end, so not a table row. 1 is the
    // only value; anything else is ignored like a bad value.
    if (std::strcmp(message.name, "goodbye") == 0) {
        if (message.type == 'i' && message.i == 1) goodbye_ = true;
        return false;
    }
    // An address this panel doesn't know is a newer DeckBridge's (ADR 0011): ignored, but the feed is alive.
    bool alive = true;
    for (const Row& row : kRows) {
        if (std::strcmp(row.name, message.name) != 0) continue;
        alive = row.type == message.type && row.apply(view_, message);
    }
    // The master clock's beat also sets the panel's beat clock (#660), at the time it arrived.
    if (alive && std::strcmp(message.name, "beat") == 0) clock_.edge(view_.beat, now_ms);
    if (alive && std::strcmp(message.name, "clockBpm") == 0) clock_.set_tempo(view_.clock_bpm);
    // The deck in front is the master and stopped: so did the master clock, at once (#660). Another deck's pause
    // says nothing about it.
    if (alive && std::strcmp(message.name, "playing") == 0 && view_.master && !view_.playing) clock_.stop();
    return alive;
}

void DeckCore::set_network(Network state, const char* ip) {
    network_ = state;
    std::snprintf(ip_, sizeof ip_, "%s", ip);
}

void DeckCore::set_setup(const char* name, const char* password) {
    std::snprintf(setup_name_, sizeof setup_name_, "%s", name);
    std::snprintf(setup_password_, sizeof setup_password_, "%s", password);
}

void DeckCore::render(Screen& screen, uint32_t now_ms) {
    // The time since, signed: a clock that wraps round still counts it, and a render that read the clock a moment
    // before the packet's time sees a little under 0, not 49 days.
    const int32_t since = static_cast<int32_t>(now_ms - last_heard_ms_);
    // Off Wi-Fi the feed can't be coming, unless it comes on the cable (#667): waiting at once.
    const bool cable = cable_heard_ && static_cast<int32_t>(now_ms - last_cable_ms_) < static_cast<int32_t>(kWaitAfterMs);
    // Stale once, forgotten: an old time would come round as recent when the clock's signed range wraps (24.8 days).
    if (!cable) cable_heard_ = false;
    const bool waiting = !heard_ || since >= static_cast<int32_t>(kWaitAfterMs) || (network_ != Network::connected && !cable);
    // Waiting holds until the next message: the old deck never comes back by itself, even when the clock comes round.
    if (waiting) heard_ = false;
    if (waiting) {
        const WaitingView view = waiting_view();
        if (shown_ && shown_waiting_ && view == shown_waiting_view_) return;
        const WaitingChanges changes = drawn_waiting_ ? changed(shown_waiting_view_, view) : WaitingChanges::all();
        shown_waiting_view_ = view;
        drawn_waiting_ = true;
        screen.show_waiting(shown_waiting_view_, changes);
    } else {
        // The beat as the panel's clock has it at this frame's time (#660); everything else as received.
        const int beat = clock_.beat_at(now_ms);
        // Every frame: the view compare is the cheap way out; the face is built only when the view or beat changed.
        if (shown_ && !shown_waiting_ && view_ == shown_view_ && beat == shown_beat_) return;
        shown_view_ = view_;
        shown_beat_ = beat;
        DeckView timed = view_;
        timed.beat = beat;
        const Face now = face(timed);
        const Changes changes = drawn_ ? changed(shown_face_, now) : Changes::all();
        // Back from waiting with nothing changed, the page needs showing even so: the board shows it on any call.
        if (drawn_ && !changes.any() && !shown_waiting_) return;
        shown_face_ = now;
        drawn_ = true;
        screen.show_deck(shown_face_, changes);
    }
    shown_ = true;
    shown_waiting_ = waiting;
}

WaitingView DeckCore::waiting_view() const {
    WaitingView view;
    view.logo = true;  // every waiting screen: the logo, the reason and the address beneath (#651)
    switch (network_) {
        case Network::setup:
            std::snprintf(view.headline, sizeof view.headline, "Set up the panel's Wi-Fi");
            std::snprintf(view.detail, sizeof view.detail, "Join %s, password %s, then open %s", setup_name_,
                          setup_password_, ip_);
            view.logo_small = true;  // the join instructions take more lines (#677)
            break;
        case Network::joining:
            std::snprintf(view.headline, sizeof view.headline, "Joining Wi-Fi\xE2\x80\xA6");
            // A wrong password looks like this forever: the way out is on the screen.
            std::snprintf(view.detail, sizeof view.detail, "Hold the screen 5 s to set up Wi-Fi again");
            break;
        case Network::connected:
            // What to type into DeckBridge's Settings, Display feed: host and port.
            std::snprintf(view.headline, sizeof view.headline, "Waiting for DeckBridge");
            std::snprintf(view.detail, sizeof view.detail, "%s  port %u", ip_, unsigned(kFeedPort));
            break;
    }
    // Fitted to the fonts, as the deck's texts are: the address and names come from outside.
    WaitingView fitted = view;  // every field; the texts then fitted over
    font_fallback::fit(view.headline, fitted.headline, sizeof fitted.headline);
    font_fallback::fit(view.detail, fitted.detail, sizeof fitted.detail);
    return fitted;
}

}  // namespace deck_core
