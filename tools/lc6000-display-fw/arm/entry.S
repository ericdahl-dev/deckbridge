@ Our block's two entries (#467), at fixed addresses the hook patch calls (wd-00.50-drawn-hook.patch). Each checks
@ our marker word before it calls our C; without it, each does only what the instruction it replaced did.
    .syntax unified
    .cpu cortex-m4
    .thumb

    .equ MARKER_AT, 0x0807FFDC
    .equ MARKER, 0x31574644         @ "DFW1", HOOK_MARKER
    .equ STOCK_RENDER, 0x0800BEA1   @ stock's render step, Thumb

@ Called from 0x0800F464 in place of `mov.w r8, #1`, the unknown-command fallthrough of stock's SysEx dispatcher.
@ In: sl = command, r7 = message (F0 ...), r5 = declared length; r4 = payload (r7 + 9, not needed). Out: r8 = 1;
@ r4, r5, r7, sl and every callee-saved register as they were (AAPCS keeps them through the C call). LR is free:
@ stock's dispatcher returns with pop {..., pc}.
    .section .entry_command, "ax", %progbits
    .global hook_entry_command
    .type hook_entry_command, %function
    .thumb_func
hook_entry_command:
    push    {r4, lr}
    ldr     r0, =MARKER_AT
    ldr     r0, [r0]
    ldr     r1, =MARKER
    cmp     r0, r1
    bne     1f
    mov     r0, r10
    mov     r1, r7
    mov     r2, r5
    bl      hook_command_entry
1:  mov.w   r8, #1
    pop     {r4, pc}
    .ltorg
    .size hook_entry_command, . - hook_entry_command

@ Called from 0x08012456 in place of `bl 0x0800BEA0`, the main loop's render step. Stock's render always runs, then
@ our tick; returns 0, because a nonzero result would make the main loop skip its 40 ms task.
    .section .entry_render, "ax", %progbits
    .global hook_entry_render
    .type hook_entry_render, %function
    .thumb_func
hook_entry_render:
    push    {r4, lr}
    ldr     r0, =STOCK_RENDER
    blx     r0
    ldr     r0, =MARKER_AT
    ldr     r0, [r0]
    ldr     r1, =MARKER
    cmp     r0, r1
    bne     1f
    bl      hook_tick_entry
1:  movs    r0, #0
    pop     {r4, pc}
    .ltorg
    .size hook_entry_render, . - hook_entry_render
