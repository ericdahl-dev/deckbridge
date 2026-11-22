// The shared message vectors (#456): every message in the file decodes to its fields, every invalid one is ignored.
// The Swift encoder walks the same file in the Kit tests.
#include "harness.h"
#include "view.h"
#include <string.h>

enum { KIND_CAPABILITY, KIND_CAPABILITY_ANSWER, KIND_BEGIN, KIND_END, KIND_DECK, KIND_STATE, KIND_BEAT, KIND_NEEDLE,
       KIND_TEXT, KIND_TEMPO, KIND_METER, KIND_TIME, KIND_PHASE };
typedef struct {
    const char *name;
    int kind, from_unit, version, number;
    int color[3];
    int player, flags, beat, angle, level, peak;
    /// Text: the field, and the Windows-1252 codes the chip decodes. Tempo: tenths of a BPM.
    int field;
    size_t code_count;
    uint8_t codes[DFW_TEXT_MAX];
    int tenths;
    /// Phase: 1/16384 beats from the master's beat, negative behind (#462).
    int offset;
    /// Time: elapsed and the track's length, whole seconds.
    int elapsed, track_length;
    size_t length;
    uint8_t bytes[DFW_MESSAGE_MAX];
} vector;
typedef struct {
    const char *name;
    int from_unit;
    size_t length;
    uint8_t bytes[DFW_MESSAGE_MAX];
} bad_vector;

#include "vectors.h"

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))
#define BEGIN_V1 "F0 00 02 0B 7F 10 20 00 02 01 01 F7"
#define STATE_LOADED_PLAYING "F0 00 02 0B 7F 10 20 00 02 07 03 F7"
#define TIME_65_OF_293 "F0 00 02 0B 7F 10 20 00 05 06 00 41 02 25 F7"
#define DECK_3_GREEN_SEQ "F0 00 02 0B 7F 10 20 00 09 03 03 00 00 01 7F 00 00 04 F7"

static dfw_unit unit;
static recording rec;

/// What drawing would see now (#573): the tests read this, never dfw_unit's fields.
static dfw_view view(void) {
    dfw_view v;
    dfw_view_of(&unit, &v);
    return v;
}

static void check(int ok, const char *name) {
    CHECK(ok);
    if (!ok) fprintf(stderr, "  in vector: %s\n", name);
}

void every_vector_decodes(void) {
    CHECK(COUNT(valid_vectors) > 0);
    for (size_t i = 0; i < COUNT(valid_vectors); i++) {
        const vector *v = &valid_vectors[i];
        fresh(&unit, &rec);
        switch (v->kind) {
        case KIND_CAPABILITY:
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(rec.sends == 1 && rec.sent[10] == (v->version < 1 ? v->version : 1), v->name);
            break;
        case KIND_CAPABILITY_ANSWER: {
            // Ours to send: asking at that version gets exactly these bytes.
            uint8_t ask[] = { 0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x10, 0x20, 0x00, 0x02, 0x00, (uint8_t)v->version, 0xF7 };
            dfw_message(&unit, ask, sizeof ask);
            dfw_tick(&unit, 0);
            check(rec.sends == 1 && rec.sent_length == v->length && memcmp(rec.sent, v->bytes, v->length) == 0, v->name);
            break;
        }
        case KIND_BEGIN:
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().drawn, v->name);
            break;
        case KIND_END:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(!view().drawn, v->name);
            break;
        case KIND_DECK:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(rec.presents == 1 && view().deck.number == v->number && view().deck.r == v->color[0] &&
                  view().deck.g == v->color[1] && view().deck.b == v->color[2] && view().deck.player == v->player, v->name);
            break;
        case KIND_STATE:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().flags == v->flags, v->name);
            break;
        case KIND_BEAT:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().beat == v->beat, v->name);
            break;
        case KIND_NEEDLE:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().needle == v->angle, v->name);
            break;
        case KIND_METER:
            feed(&unit, BEGIN_V1);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().level == v->level && view().peak == v->peak, v->name);
            break;
        case KIND_TIME:
            feed(&unit, BEGIN_V1);
            feed(&unit, DECK_3_GREEN_SEQ);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().time_heard && view().elapsed == v->elapsed && view().track_length == v->track_length, v->name);
            break;
        case KIND_TEXT:
            feed(&unit, BEGIN_V1);
            feed(&unit, DECK_3_GREEN_SEQ);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().text_length[v->field] == v->code_count &&
                  memcmp(view().text[v->field], v->codes, v->code_count) == 0, v->name);
            break;
        case KIND_TEMPO:
            feed(&unit, BEGIN_V1);
            feed(&unit, DECK_3_GREEN_SEQ);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().tempo == v->tenths, v->name);
            break;
        case KIND_PHASE:
            feed(&unit, BEGIN_V1);
            feed(&unit, DECK_3_GREEN_SEQ);
            dfw_message(&unit, v->bytes, v->length);
            dfw_tick(&unit, 0);
            check(view().phase == v->offset, v->name);
            break;
        default:
            check(0, v->name);
        }
    }
}

void every_invalid_vector_is_ignored(void) {
    CHECK(COUNT(invalid_vectors) > 0);
    for (size_t i = 0; i < COUNT(invalid_vectors); i++) {
        const bad_vector *v = &invalid_vectors[i];
        fresh(&unit, &rec);
        feed(&unit, BEGIN_V1);
        feed(&unit, DECK_3_GREEN_SEQ);
        feed(&unit, STATE_LOADED_PLAYING);
        // A time held, so a malformed one can't pass by leaving a fresh unit's zeros alone.
        feed(&unit, TIME_65_OF_293);
        dfw_tick(&unit, 0);
        dfw_view before = view(), after;
        dfw_message(&unit, v->bytes, v->length);
        dfw_tick(&unit, 0);
        after = view();
        // Nothing drawing sees changed, and nothing was presented or sent.
        check(after.drawn && rec.presents == 1 && rec.sends == 0 && memcmp(&before, &after, sizeof before) == 0,
              v->name);
    }
}
