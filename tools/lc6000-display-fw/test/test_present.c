// The frame's arrival in the layer (#568): what A's present does on the unit, composed natively through the layer seam
// and the panel's geometry, so a recording adapter sees the whole panel per present: the turned copy of the 198 square,
// then B's band, as the hook calls them.
#include "harness.h"
#include "present.h"
#include "layer_record.h"
#include <string.h>

static layer_recorder record;
static dfw_pixel frame[DFW_SIZE * DFW_SIZE];

/// A's copy writes the whole square, every present, changed or not: 198 x 198 = 39,204 writes, each pixel once, in its
/// turned place and packed. (The known gap: on the unit that copy is A's code, as flashed; a changed-rows copy belongs to
/// #570's two-block batch.)
static void a_present_copies_the_whole_square_turned(void) {
    for (int i = 0; i < DFW_SIZE * DFW_SIZE; i++) frame[i] = (dfw_pixel)i * 2654435761u & 0xFFFFFFu;
    recorder_fill(&record, 0);
    const dfw_layer layer = recorder_layer(&record);
    present_through_layer(&layer, frame);
    CHECK(record.total == DFW_SIZE * DFW_SIZE && record.in_square == DFW_SIZE * DFW_SIZE);
    CHECK(recorder_most_writes(&record) == 1);
    int off = 0;
    for (int y = 0; y < DFW_SIZE; y++)
        for (int x = 0; x < DFW_SIZE; x++)
            off += record.pixels[dfw_panel_index(x, y)] != dfw_rgb565(frame[y * DFW_SIZE + x]);
    CHECK(off == 0);
    // The same frame again: all 39,204 written again with what they already hold.
    recorder_next_present(&record);
    present_through_layer(&layer, frame);
    CHECK(record.total == DFW_SIZE * DFW_SIZE && record.unchanged == DFW_SIZE * DFW_SIZE);
}

const test_case present_tests[] = {
    { "a present copies the whole square turned", a_present_copies_the_whole_square_turned },
    { 0, 0 },
};
