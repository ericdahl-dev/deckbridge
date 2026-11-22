// The hook on the unit (#467): stock wd 00.50's addresses (#466), our state's home, and the panel. Built only for the
// chip (`make arm`); the logic it calls is hook.c, tested on the Mac.
#include <stdint.h>

#include "hook.h"
#include "panel_geometry.h"
#if HOOK_STUB_DRAWING
#include "draw.h"
#endif

#ifndef HOOK_DRAWING
#define HOOK_DRAWING 1
#endif

/// Our marker, the block's last word (0x0807FFDC): the entry shims check it before calling anything here.
const uint32_t hook_marker __attribute__((section(".marker"), used)) = HOOK_MARKER;

#if HOOK_DRAWING
#define REG(address) (*(volatile uint32_t *)(address))
/// LTDC (RM0090 section 16.7). Layer 2 is stock's second layer, set up at boot and never enabled (#466): ours.
#define LTDC_BPCR 0x4001680Cu
#define LTDC_SRCR 0x40016824u
#define SRCR_VBR 2u
#define L2 0x40016904u
#define L2_CR (L2 + 0x00)
#define L2_WHPCR (L2 + 0x04)
#define L2_WVPCR (L2 + 0x08)
#define L2_PFCR (L2 + 0x10)
#define L2_CACR (L2 + 0x14)
#define L2_DCCR (L2 + 0x18)
#define L2_BFCR (L2 + 0x1C)
#define L2_CFBAR (L2 + 0x28)
#define L2_CFBLR (L2 + 0x2C)
#define L2_CFBLNR (L2 + 0x30)
#define PF_RGB565 2u
/// Stock's layer-2 surface (struct at 0x20001DB8) holds its malloc'd pixels at +8: 320 x 240 x 2 + 64 bytes,
/// allocated at boot and never drawn into (#466).
#define LAYER2_PIXELS (*(uint16_t *const volatile *)0x20001DC0u)
/// The panel's size, the frame's place and the pack, from src/panel_geometry.h (#568): defined once for A and B.
#define LAYER_W DFW_LAYER_W
#define LAYER_H DFW_LAYER_H
/// Our frame sits where stock draws an uploaded slot: x 40 + 21, y 21.
#define FRAME_X DFW_FRAME_X
#define FRAME_Y DFW_FRAME_Y

/// Uploads show rotated 180 degrees unless the host pre-rotates them (#121), so the panel shows the frame buffer
/// upside down; dfw draws upright, so the copy turns it. To check on the unit.
/// It copies the whole square on every present, changed or not. test/present.c mirrors this copy natively through the
/// layer seam (#568), so the recording tests see the whole panel; on the unit this is the copy that runs.

static void layer_present(void *ctx, const dfw_pixel *frame) {
    (void)ctx;
    uint16_t *pixels = LAYER2_PIXELS;
    if (!(REG(L2_CR) & 1u)) {
        for (uint32_t i = 0; i < LAYER_W * LAYER_H; i++) pixels[i] = 0;
        uint32_t bpcr = REG(LTDC_BPCR), ahbp = (bpcr >> 16) & 0xFFFu, avbp = bpcr & 0x7FFu;
        REG(L2_WHPCR) = ((ahbp + LAYER_W) << 16) | (ahbp + 1);
        REG(L2_WVPCR) = ((avbp + LAYER_H) << 16) | (avbp + 1);
        REG(L2_PFCR) = PF_RGB565;
        REG(L2_CACR) = 255;
        REG(L2_DCCR) = 0;
        REG(L2_BFCR) = (4u << 8) | 5u;  // constant alpha 255: opaque over stock's layer
        REG(L2_CFBAR) = (uint32_t)(uintptr_t)pixels;
        REG(L2_CFBLR) = ((LAYER_W * 2u) << 16) | (LAYER_W * 2u + 3);
        REG(L2_CFBLNR) = LAYER_H;
    }
    for (uint32_t y = 0; y < DFW_SIZE; y++) {
        const dfw_pixel *from = frame + (DFW_SIZE - 1 - y) * DFW_SIZE + (DFW_SIZE - 1);
        uint16_t *to = pixels + (FRAME_Y + y) * LAYER_W + FRAME_X;
        for (uint32_t x = 0; x < DFW_SIZE; x++) to[x] = dfw_rgb565(*from--);
    }
    REG(L2_CR) |= 1u;
    REG(LTDC_SRCR) = SRCR_VBR;
}

/// Layer 2's pixels, for B's band (#524).
static uint16_t *layer_pixels(void) { return LAYER2_PIXELS; }

static void layer_hide(void) {
    REG(L2_CR) &= ~1u;
    REG(LTDC_SRCR) = SRCR_VBR;
}

/// Stock's SysEx sender (0x080144C4): cable, bytes, length; it queues 3-byte USB-MIDI packets (#466).
static void stock_send(void *ctx, const uint8_t *bytes, size_t length) {
    (void)ctx;
    ((void (*)(int, const uint8_t *, int))0x080144C5u)(0, bytes, (int)length);
}

static const hook_stock stock = {
    .marker = (const volatile uint32_t *)0x0807FFDCu,
    .uptime = (const volatile uint32_t *)0x20001BA0u,
    .witness = (volatile uint8_t *)0xE000E400u,
    .rx_count = (const volatile uint16_t *)0x2000189Au,
    .malloc = (void *(*)(size_t))0x08017861u,
    .hide = layer_hide,
    .layer = layer_pixels,
    .port = { .present = layer_present, .send = stock_send, .ctx = 0 },
    // No drawing in this block (#501): NULL until the drawing block's header checks out. The stub test build alone
    // carries an empty drawing, so the block tests can see the capability answer.
#if HOOK_STUB_DRAWING
    .drawing = &dfw_drawn,
#else
    .drawing = 0,
#endif    // Block B at 0x08080000 (#501), read only when built with ARM_UPPER_PROVEN=1, after the owner's read-only proof.
#if HOOK_UPPER_PROVEN
    .upper = (const uint8_t *)0x08080000u,
#endif
};

/// Our state, in the top of SRAM that stock never uses (0x2002AE94-0x2002FFFF, #466). Nothing zeroes it.
hook_state hook_ram __attribute__((section(".hookstate")));
#endif

void hook_command_entry(uint32_t cmd, const uint8_t *msg, uint32_t len);
void hook_tick_entry(void);

void hook_command_entry(uint32_t cmd, const uint8_t *msg, uint32_t len) {
#if HOOK_DRAWING
    hook_command(&hook_ram, &stock, (uint8_t)cmd, msg, len);
#else
    (void)cmd, (void)msg, (void)len;
#endif
}

void hook_tick_entry(void) {
#if HOOK_DRAWING
    hook_tick(&hook_ram, &stock);
#endif
}
