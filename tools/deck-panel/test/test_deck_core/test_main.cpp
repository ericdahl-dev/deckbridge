// The deck panel's portable core (#619): display feed bytes in, the screen's decisions out. Built and run on the Mac.
#include <unity.h>

#include <cstdlib>
#include <fstream>
#include <new>
#include <sstream>

#include "deck_core.h"
#include "deck_face.h"
#include "hold_reset.h"
#include "json_mini.h"
#include "osc_bytes.h"
#include "screen_stub.h"

using namespace osc_bytes;

// Every heap allocation in this test binary is counted, so a test can say the core makes none (on the board, small
// allocations come from the internal RAM LVGL and lwIP use, for hours).
static size_t allocations = 0;
void* operator new(size_t size) {
    ++allocations;
    if (void* p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, size_t) noexcept { std::free(p); }

void setUp() {}
void tearDown() {}

static void feed(deck_core::DeckCore& core, const Bytes& b, uint32_t now) { core.feed(b.data(), b.size(), now); }

void test_nothing_heard_yet_is_the_waiting_screen() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.render(screen, 0);
    TEST_ASSERT_EQUAL(1, screen.shown.size());
    TEST_ASSERT_TRUE(screen.last().waiting);
}

void test_a_deck_message_shows_that_deck() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 100);
    core.render(screen, 100);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(1, screen.last().deck);
}

void test_color_title_and_artist_show_with_the_deck() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 3), 100);
    feed(core, int_message(prefix + "color", 0x123456), 101);
    feed(core, string_message(prefix + "title", "Night Drive"), 102);
    feed(core, string_message(prefix + "artist", "Example Artist"), 103);
    core.render(screen, 103);
    TEST_ASSERT_EQUAL(3, screen.last().deck);
    TEST_ASSERT_EQUAL_HEX32(0x123456, screen.last().color);
    TEST_ASSERT_EQUAL_STRING("Night Drive", screen.last().title.c_str());
    TEST_ASSERT_EQUAL_STRING("Example Artist", screen.last().artist.c_str());
}

void test_an_empty_title_clears_the_last_one() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, string_message(prefix + "title", "Night Drive"), 100);
    feed(core, string_message(prefix + "title", ""), 101);
    core.render(screen, 101);
    TEST_ASSERT_EQUAL_STRING("", screen.last().title.c_str());
}

// A bad packet changes nothing: a core that heard only it still shows the waiting screen.
static void assert_ignored(const Bytes& packet) {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, packet, 100);
    core.render(screen, 100);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

void test_an_empty_packet_is_ignored() { assert_ignored({}); }

void test_a_cut_off_packet_is_ignored() {
    Bytes whole = string_message(prefix + "title", "Night Drive");
    for (size_t n = 1; n < whole.size(); ++n) assert_ignored(Bytes(whole.begin(), whole.begin() + n));
}

void test_a_packet_without_a_type_tag_is_ignored() {
    Bytes b;
    put_string(b, prefix + "deck");
    put_int(b, 1);
    assert_ignored(b);
    Bytes no_comma;
    put_string(no_comma, prefix + "deck");
    put_string(no_comma, "ii");
    put_int(no_comma, 1);
    assert_ignored(no_comma);
}

void test_a_value_of_the_wrong_type_is_ignored() {
    assert_ignored(float_message(prefix + "deck", 1.0f));
    assert_ignored(int_message(prefix + "title", 7));
}

void test_more_than_one_value_is_ignored() {
    Bytes b;
    put_string(b, prefix + "deck");
    put_string(b, ",ii");
    put_int(b, 1);
    put_int(b, 2);
    assert_ignored(b);
}

void test_a_length_that_is_not_a_multiple_of_4_is_ignored() {
    Bytes b = int_message(prefix + "deck", 1);
    b.push_back(0);
    assert_ignored(b);
}

void test_an_address_outside_the_prefix_is_ignored() {
    assert_ignored(int_message("/Syndicate/Deck1/deck", 1));
    assert_ignored(int_message("/DeckBridge/Displayx/deck", 1));
}

void test_text_that_is_not_utf8_is_ignored() {
    assert_ignored(string_message(prefix + "title", "Caf\xE9"));  // Latin-1, not UTF-8
    assert_ignored(string_message(prefix + "title", "\xC3"));  // a sequence cut short
    assert_ignored(string_message(prefix + "title", "\xC0\xAF"));  // overlong
}

void test_a_deck_outside_1_to_4_is_ignored() {
    assert_ignored(int_message(prefix + "deck", 0));
    assert_ignored(int_message(prefix + "deck", 5));
}

void test_3_seconds_without_the_feed_is_the_waiting_screen() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    core.render(screen, 3999);
    TEST_ASSERT_FALSE(screen.last().waiting);
    core.render(screen, 4000);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

void test_the_next_message_brings_the_deck_back_as_it_was() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    feed(core, string_message(prefix + "title", "Night Drive"), 1000);
    core.render(screen, 9000);
    TEST_ASSERT_TRUE(screen.last().waiting);
    feed(core, int_message(prefix + "color", 0xFF0000), 9000);
    core.render(screen, 9000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
    TEST_ASSERT_EQUAL_STRING("Night Drive", screen.last().title.c_str());
}

void test_a_message_for_an_address_the_panel_does_not_know_keeps_the_feed_alive() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    feed(core, float_message(prefix + "bpm", 128.0f), 3500);  // a newer DeckBridge's address (ADR 0011)
    core.render(screen, 5000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
}

void test_a_bad_packet_does_not_keep_the_feed_alive() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    feed(core, int_message("/Syndicate/Deck1/deck", 1), 3500);
    core.render(screen, 4000);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

void test_the_clock_wrapping_round_does_not_end_the_wait_early_or_late() {
    deck_core::DeckCore core;
    ScreenStub screen;
    const uint32_t near_end = 0xFFFFFFFFu - 500;
    feed(core, int_message(prefix + "deck", 1), near_end);
    core.render(screen, near_end + 2999);  // wraps
    TEST_ASSERT_FALSE(screen.last().waiting);
    core.render(screen, near_end + 3000);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// The board redraws only when something changed, so the core tells the screen only then.
void test_the_screen_hears_only_of_changes() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.render(screen, 0);
    core.render(screen, 10);
    TEST_ASSERT_EQUAL(1, screen.shown.size());  // waiting, once
    feed(core, int_message(prefix + "deck", 2), 100);
    core.render(screen, 100);
    core.render(screen, 200);
    TEST_ASSERT_EQUAL(2, screen.shown.size());
    feed(core, int_message(prefix + "deck", 2), 300);  // the keepalive snapshot: same value
    core.render(screen, 300);
    TEST_ASSERT_EQUAL(2, screen.shown.size());
    feed(core, string_message(prefix + "title", "Night Drive"), 400);
    core.render(screen, 400);
    TEST_ASSERT_EQUAL(3, screen.shown.size());
    core.render(screen, 400 + 3000);
    core.render(screen, 400 + 4000);
    TEST_ASSERT_EQUAL(4, screen.shown.size());  // waiting, once
    TEST_ASSERT_TRUE(screen.last().waiting);
    feed(core, int_message(prefix + "deck", 2), 5000);
    core.render(screen, 5000);
    TEST_ASSERT_EQUAL(5, screen.shown.size());  // back, unchanged deck shown again
    TEST_ASSERT_FALSE(screen.last().waiting);
}

static std::string repeat(const std::string& piece, size_t times) {
    std::string out;
    for (size_t i = 0; i < times; ++i) out += piece;
    return out;
}

static std::string title_shown(const std::string& title) {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, string_message(prefix + "title", title), 100);
    core.render(screen, 100);
    return core.view().title;  // the core's cut; the face then fits it to the fonts
}

static std::string artist_shown(const std::string& artist) {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, string_message(prefix + "artist", artist), 100);
    core.render(screen, 100);
    return core.view().artist;
}

static const std::string ellipsis = "\xE2\x80\xA6";  // …

void test_a_title_that_fits_is_shown_whole() {
    std::string fits = repeat("a", deck_core::kTitleMax);
    TEST_ASSERT_EQUAL_STRING(fits.c_str(), title_shown(fits).c_str());
}

void test_a_long_title_is_cut_with_an_ellipsis_to_the_limit() {
    std::string want = repeat("a", deck_core::kTitleMax - 1) + ellipsis;
    TEST_ASSERT_EQUAL_STRING(want.c_str(), title_shown(repeat("a", deck_core::kTitleMax + 1)).c_str());
}

void test_a_long_artist_is_cut_too() {
    std::string want = repeat("b", deck_core::kArtistMax - 1) + ellipsis;
    TEST_ASSERT_EQUAL_STRING(want.c_str(), artist_shown(repeat("b", deck_core::kArtistMax + 5)).c_str());
}

void test_the_cut_counts_characters_not_bytes_and_never_splits_one() {
    // é is 2 bytes, the emoji 4: the limit is in characters, and the cut lands between them.
    std::string fits = repeat("\xC3\xA9", deck_core::kTitleMax);
    TEST_ASSERT_EQUAL_STRING(fits.c_str(), title_shown(fits).c_str());
    std::string want = repeat("\xF0\x9F\x8E\xB5", deck_core::kTitleMax - 1) + ellipsis;
    TEST_ASSERT_EQUAL_STRING(want.c_str(), title_shown(repeat("\xF0\x9F\x8E\xB5", deck_core::kTitleMax + 1)).c_str());
}

void test_spaces_before_the_ellipsis_are_dropped() {
    std::string words = repeat("a", deck_core::kTitleMax - 3) + "   " + "tail";
    std::string want = repeat("a", deck_core::kTitleMax - 3) + ellipsis;
    TEST_ASSERT_EQUAL_STRING(want.c_str(), title_shown(words).c_str());
}

// The shared examples (#490 seam 3): feed/examples.json says, for each deck state, the messages DeckBridge sends. Its
// Swift test (DisplayFeedExamplesTests) checks DeckBridge sends them; this checks the panel shows that state from them.
static json_mini::Value examples() {
    std::string here = __FILE__;
    std::string path = here.substr(0, here.rfind('/')) + "/../../feed/examples.json";
    std::ifstream file(path);
    TEST_ASSERT_TRUE_MESSAGE(file.good(), ("can't open " + path).c_str());
    std::stringstream text;
    text << file.rdbuf();
    return json_mini::parse(text.str());
}

static Bytes example_message(const json_mini::Value& m) {
    const std::string& address = m["address"].string;
    const std::string& type = m["type"].string;
    if (type == "i") return int_message(address, static_cast<int32_t>(m["value"].number));
    if (type == "f") return float_message(address, static_cast<float>(m["value"].number));
    if (type == "s") return string_message(address, m["value"].string);
    TEST_FAIL_MESSAGE(("a type that isn't i, f or s: " + type).c_str());
    return {};
}

void test_the_shared_examples_prefix_is_the_panels() {
    const json_mini::Value file = examples();
    TEST_ASSERT_EQUAL_STRING(prefix.c_str(), file["prefix"].string.c_str());
    TEST_ASSERT_TRUE(file["cases"].array.size() >= 3);
}

void test_each_shared_example_shows_its_deck_state() {
    const json_mini::Value file = examples();  // held here: a range-for over examples()["cases"] would dangle
    size_t walked = 0;
    for (const json_mini::Value& example : file["cases"].array) {
        ++walked;
        const char* name = example["name"].string.c_str();
        // Each case twice: as single messages (an older DeckBridge), and as one bundle (#636); both must show it.
      for (int as_bundle = 0; as_bundle < 2; ++as_bundle) {
        deck_core::DeckCore core;
        ScreenStub screen;
        std::vector<Bytes> messages;
        for (const json_mini::Value& m : example["messages"].array) messages.push_back(example_message(m));
        if (as_bundle) {
            feed(core, bundle(messages), 100);
        } else {
            for (const Bytes& m : messages) feed(core, m, 100);
        }
        core.render(screen, 100);
        // A key this walker doesn't know (a later field, #617) is left for its own test.
        const json_mini::Value& state = example["state"];
        const auto& rgb = state["color"].array;
        uint32_t color = static_cast<uint32_t>(rgb[0].number) << 16 | static_cast<uint32_t>(rgb[1].number) << 8 |
                         static_cast<uint32_t>(rgb[2].number);
        TEST_ASSERT_FALSE_MESSAGE(screen.last().waiting, name);
        TEST_ASSERT_EQUAL_MESSAGE(static_cast<int>(state["deck"].number), screen.last().deck, name);
        TEST_ASSERT_EQUAL_HEX32_MESSAGE(color, core.view().color, name);
        // A missing title or artist is "", as in the Swift walker.
        std::string title = state.has("title") ? state["title"].string : "";
        std::string artist = state.has("artist") ? state["artist"].string : "";
        TEST_ASSERT_EQUAL_STRING_MESSAGE(title.c_str(), core.view().title, name);
        TEST_ASSERT_EQUAL_STRING_MESSAGE(artist.c_str(), core.view().artist, name);
        // #617's fields. A state leaves out what's off or 0; phase left out is -1, unknown.
        const deck_core::DeckView& v = core.view();
        auto flag = [&](const char* key) { return state.has(key) && state[key].boolean; };
        auto number = [&](const char* key, double otherwise) { return state.has(key) ? state[key].number : otherwise; };
        TEST_ASSERT_EQUAL_MESSAGE(!state.has("loaded") || state["loaded"].boolean, v.loaded, name);
        TEST_ASSERT_EQUAL_STRING_MESSAGE(state.has("key") ? state["key"].string.c_str() : "", v.key, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("bpm", 0)), v.bpm, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("tempo", 0)), v.tempo, name);
        TEST_ASSERT_EQUAL_MESSAGE(flag("playing"), v.playing, name);
        TEST_ASSERT_EQUAL_MESSAGE(flag("cue"), v.cue, name);
        TEST_ASSERT_EQUAL_MESSAGE(flag("sync"), v.sync, name);
        TEST_ASSERT_EQUAL_MESSAGE(flag("master"), v.master, name);
        TEST_ASSERT_EQUAL_MESSAGE(flag("loop"), v.loop, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("loopLength", 0)), v.loop_length, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("clockBpm", 0)), v.clock_bpm, name);  // #674
        TEST_ASSERT_EQUAL_MESSAGE(static_cast<int>(number("beat", 0)), v.beat, name);
        TEST_ASSERT_EQUAL_MESSAGE(static_cast<int32_t>(number("elapsed", 0)), v.elapsed, name);
        TEST_ASSERT_EQUAL_MESSAGE(static_cast<int32_t>(number("remaining", 0)), v.remaining, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("progress", 0)), v.progress, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("phase", -1)), v.phase, name);
        TEST_ASSERT_EQUAL_FLOAT_MESSAGE(static_cast<float>(number("level", 0)), v.level, name);
        // The screen: an empty case shows "No track loaded" and nothing else; a loaded one its title.
        const deck_core::Face f = deck_core::face(v);
        if (!v.loaded) {
            TEST_ASSERT_EQUAL_STRING_MESSAGE(deck_core::kNoTrack, f.title, name);
            TEST_ASSERT_EQUAL_STRING_MESSAGE("", f.elapsed, name);
            TEST_ASSERT_EQUAL_STRING_MESSAGE("", f.bpm, name);
            TEST_ASSERT_EQUAL_MESSAGE(deck_core::kPhaseHidden, f.phase_px, name);
        } else {
            TEST_ASSERT_EQUAL_STRING_MESSAGE(title.c_str(), f.title, name);
        }
      }
    }
    TEST_ASSERT_EQUAL(file["cases"].array.size(), walked);
    TEST_ASSERT_TRUE(walked >= 3);
}

// On the board the packet's time and the render's are read apart, so a render can read a moment before the packet.
void test_a_render_a_moment_before_the_last_packet_still_shows_the_deck() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    core.render(screen, 990);
    TEST_ASSERT_FALSE(screen.last().waiting);
}

// Once waiting, the panel waits until a message comes, however long: the old deck never shows again by itself, not
// even when the 32-bit clock comes round (49.7 days).
void test_once_waiting_the_old_deck_does_not_come_back_without_a_message() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    core.render(screen, 5000);
    TEST_ASSERT_TRUE(screen.last().waiting);
    core.render(screen, 1000 + 0x80000000u);
    core.render(screen, 1000);  // the clock came round
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// A line break or tab in a title would make the board's label two lines or jagged: control characters show as spaces.
void test_control_characters_show_as_spaces() {
    TEST_ASSERT_EQUAL_STRING("Night Drive  mix", title_shown("Night\nDrive\t\x7Fmix").c_str());
    TEST_ASSERT_EQUAL_STRING("A B", artist_shown("A\rB").c_str());
}

// The waiting screen says why it's waiting, and on Wi-Fi gives the address to type into DeckBridge's Settings (#620).
void test_the_waiting_screen_says_why() {
    deck_core::DeckCore core;
    ScreenStub screen;
    // No saved Wi-Fi (#622): the panel's own setup network, and how to reach the page on it.
    core.set_setup("DeckPanel-1A2B", "abcd2345");
    core.set_network(deck_core::Network::setup, "192.168.4.1");
    core.render(screen, 0);
    TEST_ASSERT_EQUAL_STRING("Set up the panel's Wi-Fi", screen.last().headline.c_str());
    TEST_ASSERT_EQUAL_STRING("Join DeckPanel-1A2B, password abcd2345, then open 192.168.4.1",
                             screen.last().detail.c_str());
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 0);
    TEST_ASSERT_EQUAL_STRING("Joining Wi-Fi…", screen.last().headline.c_str());
    // A wrong password looks like joining forever: the way out is on the screen.
    TEST_ASSERT_EQUAL_STRING("Hold the screen 5 s to set up Wi-Fi again", screen.last().detail.c_str());
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 0);
    TEST_ASSERT_EQUAL_STRING("Waiting for DeckBridge", screen.last().headline.c_str());
    TEST_ASSERT_EQUAL_STRING("192.168.1.40  port 9100", screen.last().detail.c_str());
}

// The feed over the USB cable (#667) needs no Wi-Fi: in setup mode or joining, the cable's deck shows. Wi-Fi's feed off
// Wi-Fi is still the waiting screen at once.
void test_the_cables_feed_shows_the_deck_off_wifi() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_setup("DeckPanel-1A2B", "abcd2345");
    core.set_network(deck_core::Network::setup, "192.168.4.1");
    const osc_bytes::Bytes deck3 = int_message(prefix + "deck", 3);
    core.feed(deck3.data(), deck3.size(), 1000, deck_core::Source::cable);
    core.render(screen, 1000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(3, screen.last().deck);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 1100);
    TEST_ASSERT_FALSE(screen.last().waiting);
    // Quiet on the cable for the usual 3 s: waiting, as for Wi-Fi.
    core.render(screen, 1000 + deck_core::DeckCore::kWaitAfterMs);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// Both feeds on (#667): Wi-Fi's datagram last when Wi-Fi drops, the cable's deck still shows; it doesn't hang on which
// of the two came last.
void test_with_both_feeds_losing_wifi_keeps_the_cables_deck() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    const osc_bytes::Bytes deck2 = int_message(prefix + "deck", 2);
    core.feed(deck2.data(), deck2.size(), 1000, deck_core::Source::cable);
    core.feed(deck2.data(), deck2.size(), 1010, deck_core::Source::wifi);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 1020);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
}

// Hold-to-reset (#622) counts only on the waiting screen, as before #667: a 5 s hold on the cable's deck while Wi-Fi is
// joining doesn't forget the network (the owner's decision). To set up Wi-Fi, turn off the cable feed or unplug, then hold.
void test_a_hold_on_the_cables_deck_while_joining_doesnt_reset_wifi() {
    deck_core::DeckCore core;
    ScreenStub screen;
    wifi_setup::HoldReset hold;
    core.set_network(deck_core::Network::joining, "");
    const osc_bytes::Bytes deck2 = int_message(prefix + "deck", 2);
    bool reset = false;
    for (uint32_t now = 1000; now <= 1000 + wifi_setup::HoldReset::kHoldMs + 500; now += 100) {
        core.feed(deck2.data(), deck2.size(), now, deck_core::Source::cable);
        core.render(screen, now);
        reset = hold.update(true, core.waiting(), now) || reset;
    }
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_FALSE(reset);
}

// The cable heard once, then Wi-Fi only for longer than the clock's signed range (24.8 days): losing Wi-Fi is still the
// waiting screen at once, the old cable time doesn't come round as recent.
void test_a_cable_heard_long_ago_doesnt_come_round_as_recent() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    const osc_bytes::Bytes deck2 = int_message(prefix + "deck", 2);
    core.feed(deck2.data(), deck2.size(), 1000, deck_core::Source::cable);
    core.render(screen, 1000);
    core.feed(deck2.data(), deck2.size(), 5000, deck_core::Source::wifi);
    core.render(screen, 5000);
    const uint32_t later = 1000u + 0x80000000u + 5u;
    core.feed(deck2.data(), deck2.size(), later, deck_core::Source::wifi);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, later);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// Off Wi-Fi the feed can't be coming: waiting at once, not 3 s later; back on, the next message brings the deck.
void test_losing_wifi_is_the_waiting_screen_at_once() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    feed(core, int_message(prefix + "deck", 2), 1000);
    core.render(screen, 1000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 1100);
    TEST_ASSERT_TRUE(screen.last().waiting);
    TEST_ASSERT_EQUAL_STRING("Joining Wi-Fi\xE2\x80\xA6", screen.last().headline.c_str());
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 1200);
    TEST_ASSERT_TRUE(screen.last().waiting);  // no message since
    feed(core, int_message(prefix + "deck", 2), 1300);
    core.render(screen, 1300);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
}

// What the last render showed, for hold-to-reset (#622): the waiting screen (joining and setup too), not the deck.
void test_waiting_says_what_the_last_render_showed() {
    deck_core::DeckCore core;
    ScreenStub screen;
    TEST_ASSERT_TRUE(core.waiting());  // nothing heard yet
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    feed(core, int_message(prefix + "deck", 2), 1000);
    core.render(screen, 1000);
    TEST_ASSERT_FALSE(core.waiting());
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 1100);
    TEST_ASSERT_TRUE(core.waiting());
    core.set_network(deck_core::Network::setup, "192.168.4.1");
    core.render(screen, 1200);
    TEST_ASSERT_TRUE(core.waiting());
}

// #617's fields (ADR 0011): one address-table row each.
static deck_core::DeckView after(std::initializer_list<Bytes> messages) {
    deck_core::DeckCore core;
    ScreenStub screen;
    for (const Bytes& m : messages) feed(core, m, 100);
    core.render(screen, 100);
    return core.view();
}

void test_every_field_of_the_feed_has_its_row() {
    const deck_core::DeckView& v = after({
        int_message(prefix + "loaded", 1), string_message(prefix + "key", "11B"),
        float_message(prefix + "bpm", 174.25f), float_message(prefix + "tempo", -2.5f),
        int_message(prefix + "playing", 1), int_message(prefix + "cue", 1), int_message(prefix + "sync", 1),
        int_message(prefix + "master", 1), int_message(prefix + "loop", 1), float_message(prefix + "loopLength", 0.25f),
        int_message(prefix + "beat", 3), int_message(prefix + "elapsed", 95), int_message(prefix + "remaining", 212),
        float_message(prefix + "progress", 0.3125f), float_message(prefix + "phase", 0.75f),
        float_message(prefix + "level", 0.5f), float_message(prefix + "clockBpm", 128.0f),
    });
    TEST_ASSERT_TRUE(v.loaded);
    TEST_ASSERT_EQUAL_STRING("11B", v.key);
    TEST_ASSERT_EQUAL_FLOAT(174.25f, v.bpm);
    TEST_ASSERT_EQUAL_FLOAT(-2.5f, v.tempo);
    TEST_ASSERT_TRUE(v.playing && v.cue && v.sync && v.master && v.loop);
    TEST_ASSERT_EQUAL_FLOAT(0.25f, v.loop_length);
    TEST_ASSERT_EQUAL(3, v.beat);
    TEST_ASSERT_EQUAL(95, v.elapsed);
    TEST_ASSERT_EQUAL(212, v.remaining);
    TEST_ASSERT_EQUAL_FLOAT(0.3125f, v.progress);
    TEST_ASSERT_EQUAL_FLOAT(0.75f, v.phase);
    TEST_ASSERT_EQUAL_FLOAT(0.5f, v.level);
    TEST_ASSERT_EQUAL_FLOAT(128.0f, v.clock_bpm);
}

void test_flags_go_off_with_0_and_phase_takes_minus_1() {
    const deck_core::DeckView& v = after({
        int_message(prefix + "playing", 1), int_message(prefix + "playing", 0),
        float_message(prefix + "phase", 0.5f), float_message(prefix + "phase", -1.0f),
    });
    TEST_ASSERT_FALSE(v.playing);
    TEST_ASSERT_EQUAL_FLOAT(-1.0f, v.phase);
}

// Fast fields (phase, level, progress) come at up to 30 a second: each change that shows is one show_deck, the same
// value again none.
void test_a_fast_field_change_is_one_redraw_and_the_same_value_none() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 100);
    core.render(screen, 100);
    const size_t before = screen.shown.size();
    const char* fields[] = {"phase", "level", "progress", "bpm", "tempo", "loopLength"};
    for (const char* field : fields) {
        feed(core, float_message(prefix + field, 0.25f), 110);
        core.render(screen, 110);
        feed(core, float_message(prefix + field, 0.25f), 120);
        core.render(screen, 120);
    }
    const char* ints[] = {"playing", "cue", "sync", "master", "loop", "beat", "elapsed", "remaining"};
    for (const char* field : ints) {
        feed(core, int_message(prefix + field, 2), 130);
        core.render(screen, 130);
    }
    feed(core, string_message(prefix + "key", "11B"), 140);
    core.render(screen, 140);
    // Last: an empty deck shows none of the above, so a change after it would show nothing.
    feed(core, int_message(prefix + "loaded", 0), 150);
    core.render(screen, 150);
    TEST_ASSERT_EQUAL(before + 6 + 9 + 1, screen.shown.size());
}

// #636: what a fresh panel shows from a clipped stream after boot (a playing deck's fast fields, a keepalive burst cut
// to its first messages). "No track loaded" comes only from a received loaded 0, never from what's missing.
void test_a_clipped_stream_after_boot_never_says_no_track_loaded() {
    const Bytes fast[] = {
        float_message(prefix + "level", 0.6f), float_message(prefix + "progress", 0.4f),
        float_message(prefix + "phase", 0.5f), float_message(prefix + "bpm", 126.0f),
        float_message(prefix + "tempo", 0.8f), int_message(prefix + "beat", 2),
        int_message(prefix + "elapsed", 95), int_message(prefix + "remaining", 212),
    };
    deck_core::DeckCore core;
    ScreenStub screen;
    for (const Bytes& m : fast) feed(core, m, 1000);
    core.render(screen, 1000);
    deck_core::Face f = screen.last().face;
    TEST_ASSERT_EQUAL_STRING("", f.deck);  // no deck yet
    TEST_ASSERT_EQUAL_STRING("", f.title);
    TEST_ASSERT_EQUAL_STRING("126.0", f.bpm);

    feed(core, int_message(prefix + "deck", 1), 1010);
    feed(core, int_message(prefix + "color", 0xFF0000), 1010);
    core.render(screen, 1010);
    f = screen.last().face;
    TEST_ASSERT_EQUAL_STRING("1", f.deck);
    TEST_ASSERT_EQUAL_STRING("", f.title);

    feed(core, int_message(prefix + "loaded", 1), 1020);
    core.render(screen, 1020);
    f = screen.last().face;
    TEST_ASSERT_EQUAL_STRING("", f.title);  // blank until a title arrives, not "No track loaded"

    feed(core, int_message(prefix + "loaded", 0), 1030);
    core.render(screen, 1030);
    TEST_ASSERT_EQUAL_STRING(deck_core::kNoTrack, screen.last().face.title);
}

// #636: the feed sends each update tick and each full snapshot as one bundle, so a burst is one datagram.
void test_a_bundle_applies_all_its_messages_as_one_arrival() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, bundle({int_message(prefix + "deck", 3), string_message(prefix + "title", "Night Drive"),
                       string_message(prefix + "artist", "Example Artist"), float_message(prefix + "bpm", 126.0f)}),
         1000);
    core.render(screen, 1000);
    TEST_ASSERT_EQUAL(1, screen.shown.size());
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(3, screen.last().deck);
    TEST_ASSERT_EQUAL_STRING("Night Drive", screen.last().title.c_str());
    TEST_ASSERT_EQUAL_STRING("Example Artist", screen.last().artist.c_str());
    TEST_ASSERT_EQUAL_FLOAT(126.0f, core.view().bpm);
    core.render(screen, 3999);
    TEST_ASSERT_FALSE(screen.last().waiting);  // the bundle's arrival keeps it alive 3 s
    core.render(screen, 4000);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// A bad message in a bundle is skipped and the rest kept; a bad element size (past the end, not a multiple of 4)
// stops the bundle there, since nothing after it can be found, keeping what came before.
void test_a_bad_element_does_not_lose_the_good_ones() {
    deck_core::DeckCore core;
    ScreenStub screen;
    Bytes wrong_type = int_message(prefix + "title", 7);
    feed(core, bundle({int_message(prefix + "deck", 2), wrong_type, string_message(prefix + "artist", "Kept")}), 100);
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
    TEST_ASSERT_EQUAL_STRING("Kept", screen.last().artist.c_str());

    Bytes cut = bundle({int_message(prefix + "deck", 3), string_message(prefix + "title", "Lost")});
    cut.resize(cut.size() - 4);  // the last element's size now runs past the end
    feed(core, cut, 200);
    Bytes odd = bundle({int_message(prefix + "deck", 4)});
    odd[16 + 3] = 30;  // a size that isn't a multiple of 4
    feed(core, odd, 200);
    core.render(screen, 200);
    TEST_ASSERT_EQUAL(3, screen.last().deck);  // the cut bundle's first element counted
    TEST_ASSERT_EQUAL_STRING("", screen.last().title.c_str());
}

// The feed never nests bundles: one inside is skipped, its messages unread; the bundle's own messages still count.
void test_a_nested_bundle_is_skipped() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, bundle({bundle({int_message(prefix + "deck", 4)}), int_message(prefix + "deck", 2)}), 100);
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(2, screen.last().deck);
    deck_core::DeckCore only_nested;
    feed(only_nested, bundle({bundle({int_message(prefix + "deck", 4)})}), 100);
    only_nested.render(screen, 100);
    TEST_ASSERT_TRUE(screen.last().waiting);
}

// #636, the panel as it boots, not a fresh core: joining, joined with the waiting screen up, time passing, then a
// clipped stream. Neither the network nor leaving the waiting screen resets the deck: "No track loaded" still comes
// only from a received loaded 0.
static std::string title_after_boot_then(std::initializer_list<Bytes> stream) {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 0);
    core.render(screen, 2500);
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 3000);
    core.render(screen, 20000);
    TEST_ASSERT_TRUE(screen.last().waiting);
    for (const Bytes& m : stream) feed(core, m, 20500);
    core.render(screen, 20500);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_TRUE(core.view().loaded);
    return screen.last().face.title;
}

void test_a_booted_panel_given_a_clipped_stream_never_says_no_track_loaded() {
    const Bytes level = float_message(prefix + "level", 0.6f), phase = float_message(prefix + "phase", 0.5f),
                elapsed = int_message(prefix + "elapsed", 95);
    const Bytes deck = int_message(prefix + "deck", 1), color = int_message(prefix + "color", 0xFF0000),
                loaded = int_message(prefix + "loaded", 1);
    TEST_ASSERT_EQUAL_STRING("", title_after_boot_then({level, phase, elapsed}).c_str());
    TEST_ASSERT_EQUAL_STRING("", title_after_boot_then({deck, color, level, phase, elapsed}).c_str());
    TEST_ASSERT_EQUAL_STRING("", title_after_boot_then({deck, color, loaded, level}).c_str());
}

// And a deck that went to the waiting screen comes back as it was, loaded included: waiting never empties it.
void test_coming_back_from_waiting_keeps_the_deck_loaded() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, bundle({int_message(prefix + "deck", 1), int_message(prefix + "loaded", 1),
                       string_message(prefix + "title", "Night Drive")}), 1000);
    core.render(screen, 1000);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 2000);
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 9000);
    TEST_ASSERT_TRUE(screen.last().waiting);
    feed(core, float_message(prefix + "level", 0.5f), 9500);
    core.render(screen, 9500);
    TEST_ASSERT_EQUAL_STRING("Night Drive", screen.last().face.title);
}

// For the perf env's capture (#636): what the core holds now, read without a render.
void test_the_core_says_what_it_holds() {
    deck_core::DeckCore core;
    TEST_ASSERT_TRUE(core.view().loaded);
    feed(core, bundle({int_message(prefix + "deck", 2), int_message(prefix + "loaded", 0),
                       string_message(prefix + "title", "")}), 100);
    TEST_ASSERT_EQUAL(2, core.view().deck);
    TEST_ASSERT_FALSE(core.view().loaded);
    feed(core, string_message(prefix + "title", "Night Drive"), 110);
    TEST_ASSERT_EQUAL_STRING("Night Drive", core.view().title);
}

// #651: every waiting screen shows the DeckBridge logo, with its reason and address beneath.
void test_every_waiting_screen_shows_the_logo() {
    deck_core::DeckCore core;
    ScreenStub screen;
    const deck_core::Network states[] = {deck_core::Network::setup, deck_core::Network::joining,
                                         deck_core::Network::connected};
    for (deck_core::Network state : states) {
        core.set_network(state, "192.168.1.40");
        core.render(screen, 0);
        TEST_ASSERT_TRUE(screen.last().waiting);
        TEST_ASSERT_TRUE(screen.last().logo);
        TEST_ASSERT_TRUE(screen.last().headline.size() > 0);
    }
    TEST_ASSERT_EQUAL_STRING("192.168.1.40  port 9100", screen.last().detail.c_str());
}

// A quit DeckBridge sends nothing more: within 3 s the panel shows the logo, never a frozen deck (#651).
void test_a_quit_deckbridge_is_the_logo_within_3_seconds() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    feed(core, bundle({int_message(prefix + "deck", 1), int_message(prefix + "loaded", 1),
                       string_message(prefix + "title", "Night Drive"), int_message(prefix + "playing", 1)}), 1000);
    core.render(screen, 1000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    core.render(screen, 3999);
    TEST_ASSERT_FALSE(screen.last().waiting);
    core.render(screen, 4000);
    TEST_ASSERT_TRUE(screen.last().waiting);
    TEST_ASSERT_TRUE(screen.last().logo);
    TEST_ASSERT_EQUAL_STRING("Waiting for DeckBridge", screen.last().headline.c_str());
}

// DeckBridge's goodbye (ADR 0011, #651): the logo at once, the deck kept for when the feed comes back.
void test_a_goodbye_is_the_logo_at_once_and_the_next_message_brings_the_deck_back() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, bundle({int_message(prefix + "deck", 2), string_message(prefix + "title", "Night Drive")}), 1000);
    core.render(screen, 1000);
    feed(core, bundle({int_message(prefix + "goodbye", 1)}), 1100);
    core.render(screen, 1100);
    TEST_ASSERT_TRUE(screen.last().waiting);
    TEST_ASSERT_TRUE(screen.last().logo);
    feed(core, int_message(prefix + "deck", 2), 9000);
    core.render(screen, 9000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL_STRING("Night Drive", screen.last().title.c_str());
}

void test_a_goodbye_of_another_value_is_ignored() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 2), 1000);
    feed(core, int_message(prefix + "goodbye", 0), 1100);
    core.render(screen, 1100);
    TEST_ASSERT_FALSE(screen.last().waiting);
}

// A screen that keeps nothing, so the count is the core's own.
struct QuietScreen : deck_core::Screen {
    int calls = 0;
    void show_waiting(const deck_core::WaitingView&, const deck_core::WaitingChanges&) override { ++calls; }
    void show_deck(const deck_core::Face&, const deck_core::Changes&) override { ++calls; }
};

void test_reading_packets_and_rendering_use_no_heap() {
    Bytes deck = int_message(prefix + "deck", 3);
    Bytes title = string_message(prefix + "title", repeat("\xC3\xA9 long title ", 20));
    Bytes artist = string_message(prefix + "artist", "Example Artist with a name past the inline size");
    Bytes other_title = string_message(prefix + "title", "Night Drive, the extended mix of it");
    Bytes snapshot = bundle({deck, title, artist, float_message(prefix + "phase", 0.5f)});
    deck_core::DeckCore core;
    QuietScreen screen;
    size_t before = allocations;
    for (uint32_t t = 0; t < 50; ++t) {
        core.feed(snapshot.data(), snapshot.size(), t * 100);  // the title it sets is overwritten next
        core.feed(deck.data(), deck.size(), t * 100);
        const Bytes& this_title = t % 2 ? title : other_title;
        core.feed(this_title.data(), this_title.size(), t * 100);
        core.feed(artist.data(), artist.size(), t * 100);
        core.render(screen, t * 100);
    }
    core.render(screen, 50 * 100 + 5000);
    TEST_ASSERT_EQUAL(0, allocations - before);
    TEST_ASSERT_TRUE(screen.calls > 2);
}


// #665: the screen is told the face and only the parts that changed. The first deck it sees is every part.
void test_the_first_deck_is_every_part_then_only_what_changed() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 100);
    core.render(screen, 100);
    TEST_ASSERT_EQUAL(28, screen.last().changes.count());
    feed(core, int_message(prefix + "playing", 1), 110);
    core.render(screen, 110);
    TEST_ASSERT_EQUAL(2, screen.last().changes.count());  // the play lamp's box and its text
    TEST_ASSERT_TRUE(screen.last().changes.has(deck_core::Part::lamp_color, 0));
    TEST_ASSERT_TRUE(screen.last().changes.has(deck_core::Part::lamp_text_color, 0));
    TEST_ASSERT_EQUAL_HEX32(0x30D158, screen.last().face.lamp_color[0]);
}

// A fast field that moves no whole pixel is no redraw: the level meter is 310 px, so 0.5 and 0.501 are both 155 px.
void test_a_change_that_moves_no_pixel_tells_the_screen_nothing() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 100);
    feed(core, float_message(prefix + "level", 0.5f), 100);
    core.render(screen, 100);
    const size_t before = screen.shown.size();
    feed(core, float_message(prefix + "level", 0.501f), 110);
    core.render(screen, 110);
    TEST_ASSERT_EQUAL(before, screen.shown.size());
    feed(core, float_message(prefix + "level", 0.51f), 120);  // 158 px
    core.render(screen, 120);
    TEST_ASSERT_EQUAL(before + 1, screen.shown.size());
    TEST_ASSERT_TRUE(screen.last().changes.has(deck_core::Part::level_px));
    TEST_ASSERT_EQUAL(158, screen.last().face.level_px);
}

// Back from waiting, the deck page shows what its objects already hold: only what changed meanwhile redraws.
void test_back_from_waiting_only_what_changed_meanwhile_redraws() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 100);
    core.render(screen, 100);
    core.render(screen, 100 + deck_core::DeckCore::kWaitAfterMs);
    TEST_ASSERT_TRUE(screen.last().waiting);
    feed(core, int_message(prefix + "beat", 2), 5000);
    core.render(screen, 5000);
    TEST_ASSERT_FALSE(screen.last().waiting);
    TEST_ASSERT_EQUAL(1, screen.last().changes.count());
    TEST_ASSERT_TRUE(screen.last().changes.has(deck_core::Part::beat_color, 1));
}


// #665: the waiting screen is told what changed too: the first time both texts, then only the one that changed.
void test_the_waiting_screen_is_told_only_what_changed() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 0);
    TEST_ASSERT_TRUE(screen.last().waiting_changes.headline && screen.last().waiting_changes.detail);
    core.set_network(deck_core::Network::connected, "192.168.1.41");
    core.render(screen, 10);
    TEST_ASSERT_FALSE(screen.last().waiting_changes.headline);
    TEST_ASSERT_TRUE(screen.last().waiting_changes.detail);
    TEST_ASSERT_EQUAL_STRING("192.168.1.41  port 9100", screen.last().detail.c_str());
}

// #651 in #665's shape: the logo is a part of the waiting screen too. The first waiting screen shows it (the board's
// logo starts hidden), and a view that differs only in the logo says so.
void test_the_waiting_screen_is_told_when_the_logo_changes() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 0);
    TEST_ASSERT_TRUE(screen.last().waiting_changes.logo);
    deck_core::WaitingView with, without;
    with.logo = true;
    const deck_core::WaitingChanges c = deck_core::changed(without, with);
    TEST_ASSERT_TRUE(c.logo);
    TEST_ASSERT_FALSE(c.headline || c.detail);
    TEST_ASSERT_TRUE(c.any());
}

// Its texts come fitted to the fonts, as the deck's do.
void test_the_waiting_texts_come_fitted_to_the_fonts() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::connected, "\xE6\x9D\xB1");  // 東, not in the fonts
    core.render(screen, 0);
    TEST_ASSERT_EQUAL_STRING("?  port 9100", screen.last().detail.c_str());
}


// #660: the beat box lights when its beat is due, from the panel's clock, before the message for it arrives.
void test_the_next_beat_box_lights_when_due_before_its_message() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 1000);
    feed(core, int_message(prefix + "beat", 1), 1000);
    feed(core, int_message(prefix + "beat", 2), 1469);
    core.render(screen, 1937);
    TEST_ASSERT_EQUAL_HEX32(0x262626, screen.last().face.beat_color[2]);
    core.render(screen, 1938);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[2]);  // beat 3, lit
    TEST_ASSERT_EQUAL_HEX32(0x262626, screen.last().face.beat_color[1]);
}


// #660: the deck in front is the master and stops. The beats stop with it at once: the box shows the last beat heard,
// never the one the clock had lit ahead of its message.
void test_the_master_stopping_stops_the_beat_at_once() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 1000);
    feed(core, int_message(prefix + "master", 1), 1000);
    feed(core, int_message(prefix + "playing", 1), 1000);
    feed(core, int_message(prefix + "beat", 1), 1000);
    feed(core, int_message(prefix + "beat", 2), 1469);
    core.render(screen, 1940);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[2]);  // 3, lit ahead of its message
    feed(core, int_message(prefix + "playing", 0), 1950);
    core.render(screen, 1950);
    TEST_ASSERT_EQUAL_HEX32(0x262626, screen.last().face.beat_color[2]);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[1]);  // 2, the last heard
    core.render(screen, 3000);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[1]);
}

// Not the master: its pause says nothing about the master clock, which runs on.
void test_a_deck_that_is_not_the_master_stopping_leaves_the_beat() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 1000);
    feed(core, int_message(prefix + "playing", 1), 1000);
    feed(core, int_message(prefix + "beat", 1), 1000);
    feed(core, int_message(prefix + "beat", 2), 1469);
    feed(core, int_message(prefix + "playing", 0), 1500);
    core.render(screen, 1940);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[2]);
}


// #660 with #674: the feed's clockBpm is the master clock's BPM; with it, the first beat heard is enough.
void test_the_feeds_clock_bpm_times_the_beat_from_the_first_edge() {
    deck_core::DeckCore core;
    ScreenStub screen;
    feed(core, int_message(prefix + "deck", 1), 1000);
    feed(core, float_message(prefix + "clockBpm", 128.0f), 1000);
    feed(core, int_message(prefix + "beat", 1), 1000);
    core.render(screen, 1469);
    TEST_ASSERT_NOT_EQUAL(0x262626, screen.last().face.beat_color[1]);  // beat 2, due
}

// #677: the setup screen's logo is half size, so the join instructions have the room; every other waiting screen's is
// full size. The first screen and a change between them say so.
void test_the_setup_screen_has_the_small_logo_and_no_other() {
    deck_core::DeckCore core;
    ScreenStub screen;
    core.set_network(deck_core::Network::setup, "192.168.4.1");
    core.render(screen, 0);
    TEST_ASSERT_TRUE(screen.last().logo && screen.last().logo_small);
    TEST_ASSERT_TRUE(screen.last().waiting_changes.logo_small);
    core.set_network(deck_core::Network::joining, "");
    core.render(screen, 10);
    TEST_ASSERT_TRUE(screen.last().logo);
    TEST_ASSERT_FALSE(screen.last().logo_small);
    TEST_ASSERT_TRUE(screen.last().waiting_changes.logo_small);
    TEST_ASSERT_FALSE(screen.last().waiting_changes.logo);
    core.set_network(deck_core::Network::connected, "192.168.1.40");
    core.render(screen, 20);
    TEST_ASSERT_FALSE(screen.last().logo_small);
    TEST_ASSERT_FALSE(screen.last().waiting_changes.logo_small);
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_nothing_heard_yet_is_the_waiting_screen);
    RUN_TEST(test_a_deck_message_shows_that_deck);
    RUN_TEST(test_color_title_and_artist_show_with_the_deck);
    RUN_TEST(test_an_empty_title_clears_the_last_one);
    RUN_TEST(test_an_empty_packet_is_ignored);
    RUN_TEST(test_a_cut_off_packet_is_ignored);
    RUN_TEST(test_a_packet_without_a_type_tag_is_ignored);
    RUN_TEST(test_a_value_of_the_wrong_type_is_ignored);
    RUN_TEST(test_more_than_one_value_is_ignored);
    RUN_TEST(test_a_length_that_is_not_a_multiple_of_4_is_ignored);
    RUN_TEST(test_an_address_outside_the_prefix_is_ignored);
    RUN_TEST(test_text_that_is_not_utf8_is_ignored);
    RUN_TEST(test_a_deck_outside_1_to_4_is_ignored);
    RUN_TEST(test_3_seconds_without_the_feed_is_the_waiting_screen);
    RUN_TEST(test_the_next_message_brings_the_deck_back_as_it_was);
    RUN_TEST(test_a_message_for_an_address_the_panel_does_not_know_keeps_the_feed_alive);
    RUN_TEST(test_a_bad_packet_does_not_keep_the_feed_alive);
    RUN_TEST(test_the_clock_wrapping_round_does_not_end_the_wait_early_or_late);
    RUN_TEST(test_the_screen_hears_only_of_changes);
    RUN_TEST(test_a_title_that_fits_is_shown_whole);
    RUN_TEST(test_a_long_title_is_cut_with_an_ellipsis_to_the_limit);
    RUN_TEST(test_a_long_artist_is_cut_too);
    RUN_TEST(test_the_cut_counts_characters_not_bytes_and_never_splits_one);
    RUN_TEST(test_spaces_before_the_ellipsis_are_dropped);
    RUN_TEST(test_the_shared_examples_prefix_is_the_panels);
    RUN_TEST(test_each_shared_example_shows_its_deck_state);
    RUN_TEST(test_reading_packets_and_rendering_use_no_heap);
    RUN_TEST(test_every_waiting_screen_shows_the_logo);
    RUN_TEST(test_a_quit_deckbridge_is_the_logo_within_3_seconds);
    RUN_TEST(test_a_goodbye_is_the_logo_at_once_and_the_next_message_brings_the_deck_back);
    RUN_TEST(test_a_goodbye_of_another_value_is_ignored);
    RUN_TEST(test_waiting_says_what_the_last_render_showed);
    RUN_TEST(test_a_bundle_applies_all_its_messages_as_one_arrival);
    RUN_TEST(test_the_core_says_what_it_holds);
    RUN_TEST(test_a_bad_element_does_not_lose_the_good_ones);
    RUN_TEST(test_a_nested_bundle_is_skipped);
    RUN_TEST(test_a_clipped_stream_after_boot_never_says_no_track_loaded);
    RUN_TEST(test_a_booted_panel_given_a_clipped_stream_never_says_no_track_loaded);
    RUN_TEST(test_coming_back_from_waiting_keeps_the_deck_loaded);
    RUN_TEST(test_every_field_of_the_feed_has_its_row);
    RUN_TEST(test_the_next_beat_box_lights_when_due_before_its_message);
    RUN_TEST(test_the_feeds_clock_bpm_times_the_beat_from_the_first_edge);
    RUN_TEST(test_the_master_stopping_stops_the_beat_at_once);
    RUN_TEST(test_a_deck_that_is_not_the_master_stopping_leaves_the_beat);
    RUN_TEST(test_the_waiting_screen_is_told_only_what_changed);
    RUN_TEST(test_the_waiting_screen_is_told_when_the_logo_changes);
    RUN_TEST(test_the_setup_screen_has_the_small_logo_and_no_other);
    RUN_TEST(test_the_waiting_texts_come_fitted_to_the_fonts);
    RUN_TEST(test_the_first_deck_is_every_part_then_only_what_changed);
    RUN_TEST(test_a_change_that_moves_no_pixel_tells_the_screen_nothing);
    RUN_TEST(test_back_from_waiting_only_what_changed_meanwhile_redraws);
    RUN_TEST(test_flags_go_off_with_0_and_phase_takes_minus_1);
    RUN_TEST(test_a_fast_field_change_is_one_redraw_and_the_same_value_none);
    RUN_TEST(test_the_waiting_screen_says_why);
    RUN_TEST(test_the_cables_feed_shows_the_deck_off_wifi);
    RUN_TEST(test_with_both_feeds_losing_wifi_keeps_the_cables_deck);
    RUN_TEST(test_a_hold_on_the_cables_deck_while_joining_doesnt_reset_wifi);
    RUN_TEST(test_a_cable_heard_long_ago_doesnt_come_round_as_recent);
    RUN_TEST(test_losing_wifi_is_the_waiting_screen_at_once);
    RUN_TEST(test_control_characters_show_as_spaces);
    RUN_TEST(test_a_render_a_moment_before_the_last_packet_still_shows_the_deck);
    RUN_TEST(test_once_waiting_the_old_deck_does_not_come_back_without_a_message);
    return UNITY_END();
}
