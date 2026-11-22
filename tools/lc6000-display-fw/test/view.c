// dfw_view_of on the test side (#573) until #570 moves it into block A: it reads the fields the drawing code reads, and
// nothing else, so a test that reads the view tests what drawing sees.
#include "view.h"
#include <string.h>

void dfw_view_of(const dfw_unit *unit, dfw_view *view) {
    memset(view, 0, sizeof *view);
    view->drawn = unit->drawn;
    view->deck = unit->deck;
    view->flags = unit->flags;
    view->stale = dfw_stale(unit) != 0;
    view->beat = unit->beat;
    view->needle_heard = unit->needle_heard;
    view->needle = unit->needle;
    view->meter_heard = unit->meter_heard;
    view->level = unit->level;
    view->peak = unit->peak;
    view->text_heard = unit->text_heard;
    memcpy(view->text_length, unit->text_length, sizeof view->text_length);
    memcpy(view->text, unit->text, sizeof view->text);
    view->tempo = unit->tempo;
    view->time_heard = unit->time_heard;
    view->elapsed = unit->elapsed;
    view->track_length = unit->track_length;
    view->time_look = unit->time_look;
    view->phase = unit->phase;
}
