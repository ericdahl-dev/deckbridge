# The drawn display on the chip: our two blocks and the hook (#467, #501)

The same C sources the Mac tests (`src/`) run on the display chip (`wd`, STM32F429). They are built into two raw blocks:

| Block | Where | What | Limit |
|---|---|---|---|
| **A**, `block.bin` | The stock 00.50 image's own padding, `0x0807DC00`-`0x0807FFDF`, inside the image's CRC (#466) | The two entries, the reset witness, the protocol (`dfw.c`), the one malloc, the layer adapter | 9,184 bytes |
| **B**, `upper.bin` | `0x08080000`-`0x080FFFFF`, sectors 8-11, outside the image | The drawing (`draw.c`, `draw_live.c`, fonts) behind a header block A checks | 512 KB |

The hook patch (`tools/lc6000-firmware/patches/wd-00.50-drawn-hook.patch`) makes two stock instructions call block A's entries. Only block A ever calls into B.

Nothing here is flashed. Nothing here holds vendor bytes: the stock addresses come from the static analysis on #466.

## Build

```sh
make -C tools/lc6000-display-fw arm                       # build/arm/block.bin (A) and upper.bin (B): the flashed build
make -C tools/lc6000-display-fw arm ARM_UPPER_PROVEN=0    # the A from before the read-only checks: never reads B
make -C tools/lc6000-display-fw arm-test PYTHON=<python with unicorn>
make -C tools/lc6000-display-fw arm ARM_DRAW=0            # A's hook path alone, inert
make -C tools/lc6000-display-fw arm-size                  # A (hook and protocol), A (hook only), B; any one over fails
```

- **`ARM_UPPER_PROVEN`, 1 by default** (#573): `make arm` builds what's on the owner's unit, block A reading `0x08080000`, since the owner's read-only read of that flash (`tools/lc6000-firmware/README.md`, "Read-only checks") proved it. Built with 0, A never reads it and never answers the app's capability ask, so the app stays on images; the block tests keep that build for the switch's own tests.
- The build prints how much of each block is used. If A doesn't fit below its marker, the link fails with "our code doesn't fit in the wd padding". If B is over 512 KB, its link fails.
- The block tests build A with an empty drawing table (`ARM_DRAW=stub`, test builds only) so they see the capability answer without B.
- **Toolchain, pinned:** `arm-none-eabi-gcc` 16.2.0 with GNU Binutils 2.47 (Homebrew, macOS). CI builds with Ubuntu's `gcc-arm-none-eabi` package.
- **Reproducible per toolchain version:** two builds with the same toolchain are byte-identical (a test checks this). Builds from different toolchain versions, for example Mac and CI, are not expected to match.
- There is no C library. `libc_min.c` provides the four functions the sources may use, and `include/string.h` declares them. Each block links its own copy.

## Layout

| Address | What |
|---|---|
| `0x0807DC00` | Command entry (`entry.S`), called from `0x0800F464` |
| `0x0807DC40` | Render entry (`entry.S`), called from `0x08012456` |
| after that | Block A's code and constants (`hook.c`, `upper.c`, `adapter.c`, `dfw.c`) |
| `0x0807FFDC` | The marker word, `"DFW1"`, last |
| `0x08080000` | Block B's header (`upper.h`), then the drawing and its fonts |
| `0x2002AE94` | Our state (`hook_state`), in SRAM stock never uses. Nothing zeroes it, so it carries a magic and a check word |

There is no startup code. Both links refuse any `.data` or `.bss`.

## Block B's header

Seven little-endian words at `0x08080000` (`upper.h`), 28 bytes:

| Offset | Field |
|---|---|
| +0 | Marker `"DFWB"` |
| +4 | Version (4), changed whenever this header or the entry table changes |
| +8 | Length of B, header included, at most 512 KB |
| +12 | CRC-32 (zlib's) of B from +16 to its end |
| +16 | Layout: `DFW_LAYOUT` (`src/dfw.h`) as B was built (#516) |
| +20 | The draw entry: Thumb code inside B |
| +24 | The band entry (#524): Thumb code inside B |

- **The band.** The ring sits in layer 2's black border, outside our 198 px frame. B draws it straight into the layer: `band(layer, unit)`, 320 × 240 RGB565.
  - The hook keeps the band entry only once B checks out, and calls it from its present wrapper, right after stock's present. So it never runs on a tick that presented nothing, or after end.
  - The adapter hands over the layer's pixels through `hook_stock.layer`, so B never learns an address.
  - B's band is `dfw_draw_band` in `src/draw_band.c`: the ring's pixels outside the frame, turned as the frame is: each pixel of the band's annulus written once with its final value (black where there is no ring), and only if the layer doesn't hold it already (#468).

- **The layout word.** B reads A's `dfw_unit`, so both must agree on it. `DFW_LAYOUT` is worked out at compile time from every `dfw_unit` and `dfw_deck_state` field's offset and the shared sizes. A calls B only when B's word equals its own. Otherwise a B and an A from commits whose `dfw_unit` differs stay silent together, instead of B drawing from the wrong offsets. A new field in `dfw_unit` goes into `DFW_LAYOUT` too.

- `upper_header.c` puts the header first, and `upper_seal.py` fills in its length and CRC after the link.
- The header is described once per language (#572): `upper.h` in C and `upper_header.py` in Python, with `arm/test/test_upper_header.py` pinning them together. C's CRC is `upper_crc.h`, and `upper_build.c` builds headers for the Mac's tests. Tools and tests import these; a test fails if any other file carries its own marker, CRC table or hand-written CRC.
- `make arm` also writes `build.json`: each block's sha1, plus block A's `ARM_DRAW` and `ARM_UPPER_PROVEN`. The kit reads it (`tools/lc6000-firmware/build_record.py`) instead of asking the owner.
- B never calls into A, whose addresses move from build to build. It links its own copy of what the drawing uses (`dfw_stale`, say).
- **When A checks B:** once per boot, at the first capability ask or begin, never at boot, so a power cycle still clears any crash of ours. The CRC goes a nibble at a time with a 64-byte table, never the chip's CRC unit (stock uses it). On the chip build: about 1 ms for today's B (about 10 KB), and 45 ms for all 512 KB (6.1M instructions, measured in the emulator), well under the app's 0.5 s wait.
- If anything fails (marker, version, length, CRC, layout or either entry), A doesn't answer the capability ask, and the app falls back to images. That's the same path as a failed malloc.

## The entries

- **Command entry.** It replaces `mov.w r8, #1` at stock's unknown-command fallthrough. It checks the marker, then calls `hook_command(cmd = sl, msg = r7, len = r5)`, then sets `r8 = 1` itself and returns.
  - `r4`, `r5`, `r7`, `sl` and every callee-saved register are kept.
  - The C acts only on our command `0x20`, and only on a whole message: `len + 10` bytes received, with `F7` at `9 + len`. It copies the message, so nothing keeps a pointer into stock's receive buffer.
- **Render entry.** It replaces `bl 0x0800BEA0`. It always calls stock's render, then our tick if the marker is present, and returns `r0 = 0`. A nonzero result would make stock's main loop skip its 40 ms task.
- Before our first valid message since the last reset, the tick touches nothing.

## Resets

Our SRAM state survives a reboot, so the hook has to notice a reset.

- **The witness.** IRQ 0's NVIC priority byte (`0xE000E400`) is cleared by every reset, and stock never writes it: stock sets priorities only for IRQs 77, 88, 90 and SysTick (#466). The hook writes `0xF0` there when it starts. If it later reads 0, the chip was reset, so our state starts fresh: drawn mode off, no frame, one new malloc allowed.
- **The uptime counter.** Stock's SysTick counter `0x20001BA0` (100 µs, zeroed at boot) going backwards is also a reset. The exception is a step back from within 10 s of `0xFFFFFFFF`: that is the counter wrapping after 4.97 days, and the session carries on.

## Frame buffers

- **Visible layer.** Stock sets up a second LTDC layer at boot and never enables it. Its pixels (320 × 240 × 2 + 64 bytes) are already malloc'd; the pointer is at `0x20001DC0`. In drawn mode the adapter makes that layer an opaque RGB565 overlay above stock's layer and copies our frame into it, rotated 180° and centered at (61, 21). Ending drawn mode turns the layer off, and stock's picture underneath is current again.
- **dfw's back buffer.** 198 × 198 × 4 = 156,816 bytes, from one call to stock's malloc (`0x08017860`). The call happens at the first capability ask or begin of each boot, and only once block B has checked out: A without B leaves stock's heap alone. The buffer is never freed. If the malloc fails, the ask gets no answer, and the app falls back to images.
