// Our side of the hook in the stock wd 00.50 image (#466, #467). The stock image calls two entries in our block:
// the command entry for unknown SysEx commands (0x0800F464) and the render entry from the main loop (0x08012456).
// Their Thumb shims (entry.S) call hook_command and hook_tick. This file is portable C: everything it needs from the
// stock firmware arrives through hook_stock, so the logic runs and is tested on the Mac.
#ifndef HOOK_H
#define HOOK_H
#include <stddef.h>
#include <stdint.h>

#include "dfw.h"
#include "upper.h"

/// The last word of the padding, 0x0807FFDC on the unit: our block is present only if it holds this.
#define HOOK_MARKER 0x31574644u /* "DFW1" */
/// Our state's magic, and its check word (its complement).
#define HOOK_MAGIC 0x6B6F6F48u /* "Hook" */
/// The value the hook leaves in the witness byte; only the top 4 bits exist in the NVIC priority byte it uses.
#define HOOK_WITNESS 0xF0u
/// Our one command byte (#456, #466).
#define HOOK_CMD 0x20u

/// What the stock firmware provides. On the unit (adapter.c): marker 0x0807FFDC, uptime 0x20001BA0 (SysTick,
/// 100 us, zeroed at boot), witness 0xE000E400 (IRQ 0's priority byte: zeroed by every reset, never written by
/// stock), rx_count 0x2000189A, malloc 0x08017860.
typedef struct {
    const volatile uint32_t *marker;
    const volatile uint32_t *uptime;
    volatile uint8_t *witness;
    const volatile uint16_t *rx_count;
    void *(*malloc)(size_t size);
    /// Hands the screen back to stock (on the unit: our overlay layer off). Called once when drawn mode ends.
    void (*hide)(void);
    dfw_port port;
    /// The drawing's table, or NULL while there is none we trust: then the capability ask gets no answer (#501).
    /// Used only when `upper` is NULL: the stub test build's empty drawing, and the Mac tests.
    const dfw_drawing *drawing;
    /// Block B, the drawing block (upper.h): 0x08080000 on a unit built with HOOK_UPPER_PROVEN=1, else NULL. When
    /// set, the drawing comes from B alone, once its header checks out.
    const uint8_t *upper;
    /// Layer 2's pixels, 320 x 240 RGB565 (#524): B's band draws straight into them after each present. NULL on the
    /// Mac, where B's entries are chip addresses and never called.
    uint16_t *(*layer)(void);
} hook_stock;

/// Our state, in SRAM stock never uses (0x2002AE94 on the unit), which no boot zeroes.
typedef struct {
    uint32_t magic;
    uint32_t check;
    uint32_t last_uptime;
    /// dfw's clock: milliseconds since our state started, built from the counter's steps so it runs on across the
    /// counter's wrap (counter / 10 would jump back). `sub_ms` holds the leftover 100 us counts.
    uint32_t now_ms;
    uint32_t sub_ms;
    uint8_t malloc_tried;
    /// Something was presented since drawn mode last ended, so the screen is ours until hidden.
    uint8_t shown;
    /// The stock side this state was started with: the port wrapper below reaches it through here.
    const hook_stock *stock;
    /// B was checked this boot (#501), and B's table once it checks out; the unit then points there.
    uint8_t upper_checked;
    dfw_drawing upper_drawing;
    /// B's band entry (#524), once B checks out: the ring outside the frame, drawn after each present.
    void (*upper_band)(uint16_t *layer, const dfw_unit *unit);
    dfw_unit unit;
} hook_state;

/// The command entry: stock's dispatcher found command `cmd` (sl), message `msg` (r7), declared length `len` (r5).
/// Acts only on our command, with our marker present, and only on a whole message: len + 10 bytes received and F7
/// at 9 + len. Copies the message; never keeps a pointer into stock's buffer.
void hook_command(hook_state *state, const hook_stock *stock, uint8_t cmd, const uint8_t *msg, uint32_t len);
/// The draw tick, once per main-loop pass. Does nothing until our first valid message since the last reset.
void hook_tick(hook_state *state, const hook_stock *stock);

#endif
