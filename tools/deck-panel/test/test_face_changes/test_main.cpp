// What changed between two faces (#665): the core tells the screen only these parts, so a part that isn't compared
// never redraws. Each part here is changed alone and must come back alone.
#include <unity.h>

#include <cstring>
#include <functional>

#include "deck_face.h"

void setUp() {}
void tearDown() {}

using deck_core::Changes;
using deck_core::Face;
using deck_core::Part;

void test_the_same_face_changes_nothing() {
    const Face a, b;
    TEST_ASSERT_FALSE(deck_core::changed(a, b).any());
}

struct Case {
    const char* name;
    std::function<void(Face&)> change;
    Part part;
    int index;
};

void test_each_part_changed_alone_comes_back_alone() {
    const Case cases[] = {
        {"deck", [](Face& f) { std::strcpy(f.deck, "2"); }, Part::deck, 0},
        {"deck_color", [](Face& f) { f.deck_color = 0x123456; }, Part::deck_color, 0},
        {"title", [](Face& f) { std::strcpy(f.title, "A"); }, Part::title, 0},
        {"artist", [](Face& f) { std::strcpy(f.artist, "A"); }, Part::artist, 0},
        {"key", [](Face& f) { std::strcpy(f.key, "Am"); }, Part::key, 0},
        {"bpm", [](Face& f) { std::strcpy(f.bpm, "126.0"); }, Part::bpm, 0},
        {"tempo", [](Face& f) { std::strcpy(f.tempo, "+1.0%"); }, Part::tempo, 0},
        {"elapsed", [](Face& f) { std::strcpy(f.elapsed, "0:01"); }, Part::elapsed, 0},
        {"remaining", [](Face& f) { std::strcpy(f.remaining, "-0:01"); }, Part::remaining, 0},
        {"progress_px", [](Face& f) { f.progress_px = 1; }, Part::progress_px, 0},
        {"progress_color", [](Face& f) { f.progress_color = 0xFF3B30; }, Part::progress_color, 0},
        {"phase_track_color", [](Face& f) { f.phase_track_color = 0xFF0000; }, Part::phase_track_color, 0},
        {"phase_bar_x", [](Face& f) { f.phase_bar_x = 352; }, Part::phase_bar_x, 0},
        {"phase_bar_w", [](Face& f) { f.phase_bar_w = 1; }, Part::phase_bar_w, 0},
        {"phase_tick", [](Face& f) { f.phase_tick = 1; }, Part::phase_tick, 0},
        {"phase_tick_color", [](Face& f) { f.phase_tick_color = 0; }, Part::phase_tick_color, 0},
        {"level_px", [](Face& f) { f.level_px = 1; }, Part::level_px, 0},
        {"beat 1", [](Face& f) { f.beat_color[0] = 0xFF0000; }, Part::beat_color, 0},
        {"beat 4", [](Face& f) { f.beat_color[3] = 0xFF0000; }, Part::beat_color, 3},
        {"lamp 1", [](Face& f) { f.lamp_color[0] = 0x30D158; }, Part::lamp_color, 0},
        {"lamp 5", [](Face& f) { f.lamp_color[4] = 0x64D2FF; }, Part::lamp_color, 4},
        {"lamp text 2", [](Face& f) { f.lamp_text_color[1] = 0; }, Part::lamp_text_color, 1},
        {"lamp text 5", [](Face& f) { f.lamp_text_color[4] = 0; }, Part::lamp_text_color, 4},
        {"loop_label", [](Face& f) { std::strcpy(f.loop_label, "LOOP 4"); }, Part::loop_label, 0},
    };
    for (const Case& c : cases) {
        const Face was;
        Face now;
        c.change(now);
        const Changes changes = deck_core::changed(was, now);
        TEST_ASSERT_TRUE_MESSAGE(changes.has(c.part, c.index), c.name);
        TEST_ASSERT_EQUAL_MESSAGE(1, changes.count(), c.name);
    }
}

// 9 texts, 9 numbers and colors (5 of them the phase bar's, #721), 4 beat blocks, 5 lamps and their 5 texts: a field
// added to Face without a part here doesn't compile (deck_face.h checks the list covers the struct), and one added to the list shows in this count.
void test_the_face_has_32_parts() { TEST_ASSERT_EQUAL(32, static_cast<int>(Part::count)); }

// A text compares by its characters, not what follows the NUL.
void test_a_text_compares_up_to_its_end() {
    Face a, b;
    std::strcpy(a.title, "AB");
    std::strcpy(b.title, "AB");
    b.title[5] = 'x';
    TEST_ASSERT_FALSE(deck_core::changed(a, b).any());
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_the_same_face_changes_nothing);
    RUN_TEST(test_each_part_changed_alone_comes_back_alone);
    RUN_TEST(test_the_face_has_32_parts);
    RUN_TEST(test_a_text_compares_up_to_its_end);
    return UNITY_END();
}
