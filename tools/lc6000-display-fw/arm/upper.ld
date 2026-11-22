/* Block B, the drawing, for the wd's upper flash (#501): 0x08080000-0x080FFFFF, sectors 8-11, outside Denon's image.
   It starts with the header block A checks (upper.h); upper_seal.py fills in its length and CRC after the link.
   B runs only when block A calls its draw entry. No startup code: no .data, no .bss. */
MEMORY
{
    UPPER (rx) : ORIGIN = 0x08080000, LENGTH = 0x80000
}

ENTRY(dfw_draw)

SECTIONS
{
    .upper_header 0x08080000 : { KEEP(*(.upper_header)) } > UPPER
    .text : { *(.text .text.*) *(.rodata .rodata.*) } > UPPER
    .data : { *(.data .data.*) } > UPPER
    .bss (NOLOAD) : { *(.bss .bss.* COMMON) } > UPPER
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) *(.note*) }
}

ASSERT(SIZEOF(.upper_header) == 28, "B's header is 28 bytes (upper.h)")
ASSERT(SIZEOF(.data) == 0, "no initialized data in B: there is no startup code to copy it")
ASSERT(SIZEOF(.bss) == 0, "no zeroed data in B: there is no startup code to zero it")
