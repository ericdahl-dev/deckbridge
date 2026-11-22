#include "hook.h"
#include "protocol.h"
#include "upper.h"

/// Our state lives in the SRAM stock never uses, 0x2002AE94-0x2002FFFF (#466; block.ld's STATE). Caught here on the Mac
/// too, not only at the Arm link, since dfw's inbox grows with the longest message (#458).
#define HOOK_STATE_ROOM 0x516Cu
/// C99 has no _Static_assert: an array of size -1 fails the build when it doesn't fit.
typedef char hook_state_fits_stock_sram[sizeof(hook_state) <= HOOK_STATE_ROOM ? 1 : -1];

/// The ops that may need the frame (#456): the capability ask and begin, from the protocol's one description (#569).
enum { OP_CAPABILITY = DFW_OP_CAPABILITY, OP_BEGIN = DFW_OP_BEGIN };

static int marker_present(const hook_stock *stock) { return *stock->marker == HOOK_MARKER; }

static int valid(const hook_state *state) { return state->magic == HOOK_MAGIC && state->check == ~HOOK_MAGIC; }

/// The counter wraps after 4.97 days: a backwards step from within 10 s of the top is that, not a reboot.
#define HOOK_WRAP_WINDOW 100000u

/// A reset since our state was last good: the witness was cleared, or the uptime counter went back other than by
/// wrapping (a reboot whose first call came early).
static int reset_seen(const hook_state *state, const hook_stock *stock, uint32_t now) {
    if (stock->witness && *stock->witness == 0) return 1;
    return now < state->last_uptime && state->last_uptime < 0xFFFFFFFFu - HOOK_WRAP_WINDOW;
}

/// Our port to dfw: it notes that the screen is ours, then presents through stock's side.
static void present(void *ctx, const dfw_pixel *frame) {
    hook_state *state = ctx;
    state->shown = 1;
    state->stock->port.present(state->stock->port.ctx, frame);
    // Only here, right after a real present, so the band and the frame never disagree (#524): no band on a tick that
    // presented nothing, or after end. Set only for a B whose header, CRC and layout checked out.
    if (state->upper_band && state->stock->layer) state->upper_band(state->stock->layer(), &state->unit);
}

static void send(void *ctx, const uint8_t *bytes, size_t length) {
    hook_state *state = ctx;
    state->stock->port.send(state->stock->port.ctx, bytes, length);
}

/// Moves our clock on by the counter's step since we last looked (unsigned, so a wrap is just a step).
static void advance(hook_state *state, uint32_t now) {
    state->sub_ms += now - state->last_uptime;
    state->now_ms += state->sub_ms / 10;
    state->sub_ms %= 10;
    state->last_uptime = now;
}

static void start(hook_state *state, const hook_stock *stock, uint32_t now) {
    const dfw_port port = { .present = present, .send = send, .ctx = state };
    state->stock = stock;
    // With block B given, B alone decides the drawing (#501).
    dfw_init(&state->unit, &port, NULL, stock->upper ? NULL : stock->drawing);
    state->malloc_tried = 0;
    state->shown = 0;
    state->last_uptime = now;
    state->now_ms = 0;
    state->sub_ms = 0;
    state->upper_checked = 0;
    state->upper_band = 0;
    state->magic = HOOK_MAGIC;
    state->check = ~HOOK_MAGIC;
    if (stock->witness) *stock->witness = HOOK_WITNESS;
}

/// Checks B once per boot, at the first capability ask or begin (#501): about 1 ms for today's B, 45 ms for all
/// 512 KB, once. Never at boot, so our code still runs only after our first message. Once B checks out, the unit
/// draws through B's entry.
static void check_upper(hook_state *state, const hook_stock *stock) {
    if (!stock->upper || state->upper_checked) return;
    state->upper_checked = 1;
    upper_entries entries;
    if (!upper_check(stock->upper, DFW_LAYOUT, &entries)) return;
    state->upper_drawing.draw = (void (*)(dfw_pixel *, const struct dfw_unit *))(uintptr_t)entries.draw;
    state->upper_band = (void (*)(uint16_t *, const dfw_unit *))(uintptr_t)entries.band;
    state->unit.drawing = &state->upper_drawing;
}

/// The one stock malloc, ever, per boot: a frame for the capability ask or begin, and only with a drawing to use it
/// (#501): without one, block A leaves stock's heap alone. Never freed.
static void ensure_frame(hook_state *state, const hook_stock *stock) {
    if (!state->unit.drawing || state->unit.frame || state->malloc_tried) return;
    state->malloc_tried = 1;
    dfw_pixel *frame = stock->malloc(sizeof(dfw_pixel) * DFW_SIZE * DFW_SIZE);
    if (frame) dfw_set_frame(&state->unit, frame);
}

void hook_command(hook_state *state, const hook_stock *stock, uint8_t cmd, const uint8_t *msg, uint32_t len) {
    if (cmd != HOOK_CMD || !marker_present(stock)) return;
    uint32_t total = len + 10;
    if (len == 0 || total > *stock->rx_count || msg[9 + len] != 0xF7) return;
    uint32_t now = *stock->uptime;
    if (!valid(state) || reset_seen(state, stock, now)) start(state, stock, now);
    advance(state, now);
    state->stock = stock;
    uint8_t op = msg[9];
    if (op == OP_CAPABILITY || op == OP_BEGIN) {
        check_upper(state, stock);
        ensure_frame(state, stock);
    }
    // A begin with no frame is still passed on: dfw then presents nothing, so the screen stays stock's.
    dfw_message(&state->unit, msg, total);
}

void hook_tick(hook_state *state, const hook_stock *stock) {
    if (!marker_present(stock) || !valid(state)) return;
    uint32_t now = *stock->uptime;
    if (reset_seen(state, stock, now)) {
        state->magic = 0;
        return;
    }
    advance(state, now);
    state->stock = stock;
    dfw_tick(&state->unit, state->now_ms);
    if (state->shown && !state->unit.drawn) {
        state->shown = 0;
        stock->hide();
    }
}
