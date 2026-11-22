# LC6000 drawn jog display firmware

This is the C for the LC6000 PRIME's display chip that draws the jog display itself from small messages, instead of
showing uploaded images (spec #455; #457 and #464 so far). DeckBridge sends the messages over the WD port. This code
parses them and draws today's design B into a back buffer.

Everything here builds and is tested natively, on a Mac or on Linux, with no hardware and no vendor data. The
Arm build and the hook in the stock image are #467. The repo never holds vendor firmware or built
images.

## Build and test

```sh
make -C tools/lc6000-display-fw test
```

This needs only a C compiler and Python 3, which turns the vectors file into a C header. It does two things:

- Builds `src/` and `test/` with AddressSanitizer and UndefinedBehaviorSanitizer, and runs every test.
- Builds `src/` again with `-ffreestanding -O2` and no sanitizers, and fails if the objects need anything from
  libc but `memcpy`, `memmove`, `memset` and `memcmp` (`test/check_symbols.sh`). That catches malloc, stdio and
  libm. The chip has none of them to give.

CI runs the same command in the Display firmware job, on Linux with gcc.

## How it fits together

- `src/dfw.h`, `src/dfw.c`: the unit.
  - `dfw_init` takes the port: `present` sends a finished frame to the panel, and `send` sends a reply to the host.
  - It also takes the drawing as a table (`dfw_drawing`). `dfw.c` draws only through it, so it links without
    `draw.c` and the hook block can leave the drawing out (#501). The Mac tests pass `&dfw_drawn`. The hook passes
    whatever stock hands it, which is NULL until the drawing block checks out.
  - `dfw_message` only copies a whole message (F0 through F7) into a fixed inbox. It can be called from anywhere.
  - `dfw_tick(unit, now_ms)` parses what's waiting, then redraws and presents if something changed. `now_ms` is
    a millisecond clock that may wrap; on the unit it's the HAL tick.
  - With none of our messages for 3 s, or the state's feedback-stale bit set, the unit is stale (`dfw_stale`) and
    draws the waiting look. Any of our messages ends the silence (#464).
  - The back buffer belongs to the caller (`dfw_set_frame`). On the unit it is in SDRAM.
  - With no frame or no drawing, nothing is drawn and the capability ask gets no answer, so DeckBridge falls back
    to images.
- `src/draw.h`, `src/draw.c`: `dfw_draw` draws design B for the deck in front. For now that is the ground, the
  unlit ring, the deck chip and the player badge. When stale it draws the waiting look instead: our logo (the app
  icon's deck ring) with the beat ring dark, its hub in the deck's color with the deck's number in black and no hole
  (#524), so a deck change while stale still shows. The logo is drawn from the icon SVG's own numbers, not stored as an
  image. It uses `float` only, with no `double` and no libm (Cortex-M4F).
- `src/draw_live.h`, `src/draw_live.c`: `dfw_draw_live`, called last by `dfw_draw`, draws the live elements over
  design B (#459): the master beat's section lit in the live green, and the marker (Swift's `drawMarker`: a white
  wedge with a 2 px black keyline) at the needle's angle. No marker until a needle message has come since begin.
  Under the marker, the level meter (#461, Swift's `drawMeter`): an arc 80-83 px out on the left, 240° to 300°, a
  dark track filled green to three quarters and yellow above, all red at clip, with the held peak as a 2° tick. No
  meter until a meter message has come since begin. Over the meter and under the marker, the track time (#460,
  Swift's `drawTime`): the time left, "-m:ss" in GeistMono-SemiBold 21 at (99, 160), drawn mode's layout (#524). None until a time message has come since begin or
  the deck changed, and none for an unknown length. In the last minute while playing and not looping (a loop holds it) it is steady red, and from 30 s
  left it blinks at 1 Hz: red for the first 500 ms from when the time last changed, then white, text and fill, for
  every deck (#524). The tick
  works the look out from `now_ms`, so the flip draws a frame; with no new time it keeps alternating off the last one.
  Nothing while the display is stale.
- `src/panel_geometry.h`: the panel, defined once (#568): the 320 x 240 RGB565 layer, the frame at (61, 21) turned 180
  degrees, the pack, and the layer seam `dfw_layer` {read, write, ctx}. Every write to the panel goes through a
  `dfw_layer`: the real layer inside `dfw_draw_band` (the only code that touches the layer's pointer), the recording
  adapter the tests use (`test/layer_record.c`), and frame-dump's. A's present (arm/adapter.c, as flashed) takes the
  same geometry; the tests compose its copy natively through the seam (`test/present.c`) and check every present on the
  whole panel (`test/test_panel_record.c`): no pixel written twice, none black then lit, the band writing only what
  changes. Known gap: A's copy rewrites the whole square, 39,204 writes, every present (#570).
- `src/draw_band.h`, `src/draw_band.c`: the progress ring (#524), out in the panel's black band round the frame: r 103-107
  from the frame's center, a 0x4A4A4A track and the fill clockwise from 12 o'clock in the deck color, or the
  warning's red or white. `dfw_band_pixels` puts its pixels in the frame's coordinates (some below 0 or past 197),
  each over what lies under it, and keeps no state. The frame draws the ones inside its 198 square (the ring crosses
  its corners); `dfw_draw_band`, block B's band entry, writes the rest into layer 2, turned as the frame is,
  each band pixel once with its final value (black where there is no ring), only where the layer
  differs (#468), so a ring that goes leaves nothing and an unchanged one writes nothing.
  The band's shape is a table (#558): `src/band_table.c`, generated by `gen/band_table_gen.c` from
  `src/band_geometry.h` (the code that ran per pixel before), holds each pixel's cover, start edge and track; only the
  fill's end edge is worked out per present. Don't edit it; regenerate with `make tables`. `make test` fails if it
  isn't what the generator writes now.
  The beat ring is a table too: `src/ring_table.c`, from `gen/ring_table_gen.c` and `src/ring_geometry.h` (draw.c's
  `ring()` and draw_live.c's `lit_section()` as they were), holds each ring pixel's unlit and all-dark gray and its
  section's lit color.
- `src/font_header.h`: glyph coverage for the header's two faces and the track time's (#460), generated from the bundled Geist fonts
  (SIL OFL 1.1). Don't edit it. Regenerate it from the repo root with:

  ```sh
  swift tools/lc6000-display-fw/gen/font_gen.swift > tools/lc6000-display-fw/src/font_header.h
  ```

  The generator copies how CoreText places glyphs, so the C text lands where the Swift renderer's does. Add a
  glyph by adding it to the generator's list.

## The picture's numbers

`layout/layout.json` (#571) holds every number the Swift renderer and this C share: the colors (ground, text, the key's
blue, the live green, the beat ring's grays, the warning's red and white, the band's track, the meter's), the radii
(the beat ring, the meter, the band), drawn mode's foot (key/BPM 18 px at 140.5, the time 21 px at 160), the untitled
text tops, and the thresholds (60 and 30 s for the warning, 0.1791 for the deck number's white).
`layout/gen_layout.py` writes `src/layout_generated.h` and the Kit's `JogLayout.generated.swift` from it, each value
written as its literal was, so neither side's numbers changed. Don't edit either; change the JSON and run
`make layout`. `make test` regenerates both into `build/` and fails if they differ. The font generators read their
sizes and middles from the same file.

## The messages

`vectors/messages.json` is the protocol's one description (#456, #569), shared with the Swift side.

- **`protocol`**: the ops (number, and one exact length or `framed`), the caps, the state flags, the reserved values
  and the timing. `vectors/gen_protocol.py` generates `src/protocol.h` and the Kit's `DrawnDisplayProtocol.swift`
  from it; `make test` and a Kit test fail if either is out of date.
- **`messages`** and **`invalid`**: each message's exact bytes, and bytes that must all be ignored. The Kit tests walk
  them with the Swift encoder and decoder, and `test/test_vectors.c` with this decoder.
- **`sequences`**: the sequence rules as cases, messages at times in, the expected state out (a deck change, end,
  the 3 s silence, the time's look…). `test/test_sequences.c` walks them with `dfw.c`, and the Kit's
  `DrawnDisplaySequenceTests` with `DrawnDisplayState`.
- **`about`**: the framing, in words.

To add a message, red first:

1. **Describe it:** its op in `protocol`, its entries in `messages` and `invalid`, and any rule it brings as a
   `sequences` case. Run `python3 vectors/gen_protocol.py`.
2. **The host:** its case in `DrawnDisplay.Message` and its encoding (the Kit), and where the driver sends it.
3. **The decoders:** its case in `DrawnDisplayState` and in `dfw.c`'s `act`, plus any field it fills in `dfw_unit`
   (which moves its layout: see `DFW_LAYOUT`).
4. **The walks:** its kind in `test/vectors_to_c.py`, `test/test_vectors.c` and the Kit's vectors walks. An unknown
   kind fails the build.

A change to the vectors file runs the Mac jobs too, so the Swift walk always runs on it.

Anything that isn't exactly one of our messages is ignored:

- wrong header or command;
- a length that isn't the op's one exact length, or isn't the bytes actually received (text, #458, has no one
  length: its field and at most 96 bytes of characters);
- text with a control code, a lone escape at its end, an undefined Windows-1252 code other than the box (0x81), or a
  field over 3;
- F7 anywhere but its place;
- a data byte with its top bit set;
- a version of 0, or a value out of range.

Commands 0x78 and 0x79, which write the unit's settings flash, are never acted on. The only reply this code
ever sends is the capability answer.

## Reference images

`test/test_draw.c` compares the drawing with design B as the app's Swift renderer (`JogDisplayRenderer`) draws
it, never with images made by this code.

- The references are binary PPMs in `test/ref/`.
- Three bands are compared: the ring (radius 83.5 to 96.5), the header (y 20 to 55), and the text inside the
  ring below the header (#458): the title or an untitled deck's words, the artist or caption, the rule in the deck
  color, and key and BPM. Before a deck's first text message, the text band is the rule alone.

The waiting look (`test/ref/stale.ppm`) is compared over the whole frame, since the logo is all of it.
`stale-preview.png` is a PNG of it for people to look at; the tests read the PPM. The Kit's `JogLogoTests` read
`design/icon/icon-1-deck-ring.svg` and fail if the logo's numbers no longer match the icon.

**Tolerance**, per channel, 0-255:

- **Ring:** no pixel more than 6 off.
- **Header:** at most 24 pixels more than 8 off, and none more than 24 off.
- **Waiting look:** at most 64 pixels more than 8 off, and none more than 24 off.
- **Text:** at most 200 pixels more than 8 off, and none more than 56 off (measured worst: 48, and 169 pixels over
  8, on the titled references; the untitled ones are within 26).

CoreGraphics and this code anti-alias curves slightly differently: up to 18 levels on a few edge pixels of a white
chip, and within 8 everywhere else. The limits are tight enough that a wrong color, a 1 px shift or a wrong glyph
fails, and each of those was checked. The test prints each case's worst difference, so a change shows up in the
log.

The text (#458) is drawn from Geist bitmaps made by `gen/text_font_gen.swift` with CoreText: 4-bit coverage at each
x phase CoreText snaps glyphs to (halves at 26, 20 and 18 px, thirds at 16 px). Its layout (the title's size, the
wrap, every ellipsis cut) is checked exactly, not by pixels, against `test/ref/text_layout.h`, which the Kit writes
from the renderer (`DisplayFirmwareTextLayoutTests`), and its widths against CoreText's in `test/ref/text_widths.h`.
The text references are `test/ref/text-*.ppm`; a letter the font lacks (0x81) draws Geist's own box, which the
renderer can't show (it falls back to another font), so a test checks the box's shape instead. A 1 px shift, the
wrong phase, the key's blue drawn white, or kerning left off each fails.

The live elements (#459) are checked in `test/test_draw_live.c` against references with a beat lit or the marker
drawn. Like every reference, they come from `test/ref/manifest.json` through the Kit's `jog-reference` (#571).
The lit section is the live green on the ground, three times the contrast of the unlit sections, so at most 10 of
its pixels may be more than 6 off, and none more than 10 (measured worst: 8 on 7 pixels). The marker is compared from
radius 77 out (inside that is only the chip, for deck 4 empty) as the unlit ring is: none more than 6 off (measured
worst: 3, at the references and at 19 more angles swept round the turn). Half a degree off fails.

The track time (#460) is checked against `*-time*.ppm` the same way: the ring's corners from radius 95.5 out, the text
in a box around its line. The whole ring (#524) is checked in `test/test_draw_band.c` against `band-*.ppm`, the whole
216 drawn image (a manifest entry with `canvas` 216), over r 101-109. The ring is all edge, as the meter is: the track within
3, the fills worst 10 with up to 68 pixels over 6, all on its circles, so 6 with a budget a little over each case's
count and nothing past 16. The text
is within 1 (2, no budget); its warning red has glyphs of its own, since light text is drawn heavier.

**To add or change a reference image:**

1. Add an entry to `test/ref/manifest.json` (its file and the renderer inputs; #571: every reference is made from that
   one list, and the Kit's `DisplayFirmwareReferenceTests` checks every entry against the renderer, failing on a stale
   one), then run `make_refs.sh`, which renders all of them through the Kit's `jog-reference`:

   ```sh
   sh tools/lc6000-display-fw/test/ref/make_refs.sh
   ```

2. Add a row for it to `cases[]` in `test/test_draw.c`.
3. Commit the new or changed `.ppm` (and the preview PNG) with the change that needed it, so the review shows it.
   The script needs a Mac: it builds the Kit and uses `sips` for the preview.

Never regenerate the references to make a failing test pass. They change only when design B changes in the
Swift renderer.
