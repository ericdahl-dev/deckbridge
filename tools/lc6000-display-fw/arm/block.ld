/* Our block for the display chip (#467): it fills wd 00.50's own padding, 0x0807DC00-0x0807FFDF (9,184 bytes, inside
   the image's CRC, #466). The two entries sit at fixed addresses the hook patch calls; the marker is the last word.
   There is no startup code: no .data, no .bss. Our state lives at the free top of SRAM, which nothing zeroes. */
MEMORY
{
    PAD (rx)   : ORIGIN = 0x0807DC00, LENGTH = 0x23E0
    STATE (rw) : ORIGIN = 0x2002AE94, LENGTH = 0x516C
}

ENTRY(hook_entry_command)

SECTIONS
{
    .entry_command 0x0807DC00 : { KEEP(*(.entry_command)) } > PAD
    .entry_render 0x0807DC40 : { KEEP(*(.entry_render)) } > PAD
    .text : { *(.text .text.*) *(.rodata .rodata.*) } > PAD
    .data : { *(.data .data.*) } > PAD
    .marker 0x0807FFDC : { KEEP(*(.marker)) } > PAD
    .hookstate (NOLOAD) : { *(.hookstate) } > STATE
    .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > STATE
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) *(.note*) }
}

ASSERT(SIZEOF(.entry_command) <= 0x40, "the command entry outgrew its 64 bytes")
ASSERT(ADDR(.text) + SIZEOF(.text) + SIZEOF(.data) <= 0x0807FFDC,
       "our code doesn't fit in the wd padding below the marker (9,184 bytes in all): move it to block B (#501)")
ASSERT(SIZEOF(.data) == 0, "no initialized data: there is no startup code to copy it")
ASSERT(SIZEOF(.bss) == 0, "no zeroed data: there is no startup code to zero it; use hook_state")
