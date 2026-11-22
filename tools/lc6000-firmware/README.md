# LC6000 firmware patch tool

`dfupatch.py` patches the LC6000 PRIME's **jog wheel/display (`wd`)** firmware inside its DfuSe `.dfu` file and fixes both checksums. It is research tooling for #418 (custom firmware). It is not part of the app and isn't for end users.

Python 3, standard library only. Run it with `python3 -I`.

## Rules

- **Never commit or share vendor files or anything built from them.** That covers the stock `.dfu` files, the updater, extracted `.bin` images, dumps and patched `.dfu` files (all inMusic copyright). Only this tool, its tests and **patch descriptions** (addresses plus the few bytes being replaced) go in the repo or in issues. `.gitignore` here blocks `*.dfu`, `*.bin`, `*.hex`, `*.elf` and `*.patched*`, and `apply` refuses to write inside the repository.
- This tool only edits files. It never talks to the hardware. Flashing is a separate step that you do by hand; see the runbook on #431.

## Use

Get the stock `wd` file from your own copy of the updater (`docs/research/*.dmg`, which is gitignored): mount it read-only and copy `jc20_wd_update_00_50_3A7CE2CA.dfu` out of the `.app`'s `Contents/Resources` to a folder **outside the repo**.

Check that the tool understands the file:

```sh
python3 -I tools/lc6000-firmware/dfupatch.py verify ~/lc6000/jc20_wd_update_00_50_3A7CE2CA.dfu
# ok: trailer CRC 0x3A7CE2CA over 0x77fec bytes; a no-op patch reproduces the file bit for bit
```

Write a patch description: one edit per line, `ADDRESS OLD-HEX NEW-HEX`. The address is the absolute flash address (the image starts at `0x08008000`), and `#` starts a comment:

```
# what this changes and why, with the issue number
0x0800XXXX 0f28 1028
```

Apply it, writing the result outside the repo:

```sh
python3 -I tools/lc6000-firmware/dfupatch.py apply ~/lc6000/jc20_wd_update_00_50_3A7CE2CA.dfu my.patch ~/lc6000/wd-patched.dfu
# wrote ~/lc6000/wd-patched.dfu: new trailer CRC 0x........, DfuSe suffix CRC 0x........
```

`apply` refuses, and writes nothing, if:

- the file isn't a one-target, one-element DfuSe file with a good suffix CRC (the stock updater reads the element at a fixed offset, so nothing else would flash correctly);
- the image doesn't end with `EndOfFlashToken`, or it's a `wd` image whose stored trailer CRC doesn't match (see "The `tp` image" below);
- any old bytes don't match what's in the file (wrong image or wrong patch);
- an edit falls outside the image, reaches into the 32-byte trailer, overlaps another edit, or has old and new bytes of different lengths;
- the output already exists, or is inside the repository.

## Placing our block (`place`, #467)

`place` writes a raw block (our drawn-display code, built by `tools/lc6000-display-fw`'s `make arm`) into the `wd` image's own padding: `0x0807DC00`-`0x0807FFDF`, 9,184 bytes that are `0xFF` in stock 00.50 and lie inside the trailer CRC (#466). It then recomputes the trailer CRC and the DfuSe suffix CRC.

```sh
python3 -I tools/lc6000-firmware/dfupatch.py place ~/lc6000/wd-patched.dfu block.bin ~/lc6000/wd-placed.dfu
# wrote ...: N bytes at 0x0807DC00, new trailer CRC 0x........, DfuSe suffix CRC 0x........
```

It refuses, and writes nothing, if the image isn't `wd` or doesn't hold that range, if the block is empty or bigger than 9,184 bytes, if any byte it would write over isn't `0xFF` (wrong image, or a block is already there), or if the output exists or is inside the repository.

## Patches in this folder

Patch descriptions live in `patches/`. Each one is a few bytes for one firmware version; it holds no vendor image.

### `patches/wd-00.50-show-slot-16.patch` (#425)

- **For:** `wd` firmware 00.50 only, the stock file `jc20_wd_update_00_50_3A7CE2CA.dfu` (trailer CRC `0x3A7CE2CA`). `apply` refuses any other image, because the old bytes won't match.
- **What it changes:** one byte. The show command (`0A`) drops any slot index above 15, although uploads (`0E`) take slots 1-16 and the slot table has room for 16. At `0x0800BDA4`, `cmp r0, #0xf` becomes `cmp r0, #0x10` (`0f 28` to `10 28`), so "show 16" works. The tool then rewrites the trailer CRC (to `0x36DF3956`) and the DfuSe suffix CRC.
- **Why slot 16 is safe to show:** slot N is table entry N + 29, and the table has 46 entries (0-45), so slot 16 is the last entry, set up at boot exactly like slots 1-15. Nothing else in the firmware compares a slot index with 15 or loops over the slots. The details are on #425.
- **Status: proven on the owner's unit (2026-11-19).** The owner flashed it with `dfu-util` from ST's ROM bootloader, entered by the update-mode SysEx. The read-back matched, and the trailer CRC stored on the chip equals the one computed over the read-back. The unit booted with its screen up, and a test image uploaded to slot 16 showed. This was the first `wd` flash on hardware. Evidence: [#425](https://github.com/ericdahl-dev/deckbridge/issues/425#issuecomment-7000989396). Restoring the display chip to stock is not proven (see "What isn't known yet").

```sh
python3 -I tools/lc6000-firmware/dfupatch.py apply ~/lc6000/jc20_wd_update_00_50_3A7CE2CA.dfu \
  tools/lc6000-firmware/patches/wd-00.50-show-slot-16.patch ~/lc6000/jc20_wd_00_50_show16.dfu
# wrote ...: new trailer CRC 0x36DF3956, DfuSe suffix CRC 0x5F321B11
```

### `patches/wd-00.50-vos-scale-1.patch` (#438)

- **For:** `wd` firmware 00.50 only, the stock file `jc20_wd_update_00_50_3A7CE2CA.dfu` (trailer CRC `0x3A7CE2CA`). `apply` refuses any other image, because the old bytes won't match.
- **What it changes:** one byte. The clock setup lowers the STM32F429's core regulator to Scale 2 (`PWR_CR.VOS = 0b10`) and then runs the chip at 180 MHz with over-drive on. ST rates Scale 2 with over-drive to 168 MHz; only Scale 1 with over-drive is rated to 180 MHz. At `0x0800A69E`, `orr r0, r0, #0x8000` becomes `orr r0, r0, #0xc000` (`40 f4 00 40` to `40 f4 40 40`), so VOS stays at `0b11`, Scale 1, the chip's reset value. Nothing else in the image writes VOS.
- **What it costs:** the core runs about 0.06 V higher (typical 1.26 V to 1.32 V), so the chip draws a little more current. Clock speed and all timing stay the same.
- **Status: unproven on hardware.** Nobody has flashed it. Nobody has read `PWR_CR` on a running unit either, so the stock setting is known only from the code. It is not shown to fix the display drop-outs in #428. The bootloader does accept a patched `wd` image with a recomputed CRC ([#425](https://github.com/ericdahl-dev/deckbridge/issues/425#issuecomment-7000989396)), so the route is proven; this patch is not. Follow the runbook on #431, and have an SWD probe working before you try. The evidence is on #438.

### `patches/tp-00.31-no-deck-select-on-hello.patch` (#439)

- **For:** `tp` (top panel) firmware 00.31 only, the stock file `jc20_tp_update_00_31_120936.dfu`. `apply` refuses any other image, because the old bytes won't match.
- **What it changes:** one byte of start-up data, no code. On a freshly powered unit a host hello (`F0 00 20 7F 01 F7`) puts the top panel into "pick a deck" mode: pads 1-4 blink and the other controls are muted until a pad is pressed. The hello handler (`0x0800C280`) does that only while the deck byte at `0x20000703` is `0xFF`, "no deck picked yet", its power-on value. That value is a literal in the compressed start-up data, at `0x08015CDD`; the patch makes it `0x00`, deck 1. The line covers the whole 4-byte token at `0x08015CDB` (`0a 14 ff 64` to `0a 14 00 64`).
- **What the host then sees after a hello:** ch16 note 55 on (`9F 37 7F`), note 51 at 127 on ch1 (`90 33 7F`), ch16 note 55 off (`8F 37 00`). That is what the stock firmware sends on a hello once deck 1 has been picked. No blinking, no pad press.
- **What stays the same:** with no host the unit already sends on ch1, and still does. Shift + deck select still opens deck select, and a pad still switches deck; pad 1 shows as the current deck from the start. A hello after you picked another deck reports that deck, as before. Goodbye (`F0 00 20 7F 02 F7`) is untouched.
- **Status: proven on the owner's unit (2026-11-19).** Flashed with `dfu-util` from ST's ROM bootloader; the read-back matched the image. After power-on and a host hello, the unit sent the layer 1 signal 24 ms later with no pad press and no blinking; on stock it waits for a pad. Manual deck select still worked. Evidence: [#439](https://github.com/ericdahl-dev/deckbridge/issues/439#issuecomment-7000740559). Restoring stock after this patch is **not recorded** on any issue. What is recorded is the route: Denon's updater in bootloader mode flashed stock `tp` onto this unit earlier the same night, before any patch ([#435](https://github.com/ericdahl-dev/deckbridge/issues/435#issuecomment-7000152436)).
- **Way back:** hold BACK + FWD + VINYL at power-on (ST's ROM bootloader, which nothing in flash can remove), then run Denon's updater to restore stock 00.31.

```sh
python3 -I tools/lc6000-firmware/dfupatch.py apply ~/lc6000/jc20_tp_update_00_31_120936.dfu \
  tools/lc6000-firmware/patches/tp-00.31-no-deck-select-on-hello.patch ~/lc6000/jc20_tp_00_31_no_deck_select.dfu
# wrote ...: tp image, trailer unchanged (no trailer CRC), DfuSe suffix CRC 0x7AA5BB38
```

### `patches/wd-00.50-drawn-hook.patch` (#466, #467)

- **For:** `wd` firmware 00.50 only, and **only together with our block** (`build_owner_image.py` below does both). The hook calls into the block. A hook pointing at bare `0xFF` padding would fault on the first unknown command and on the first main-loop pass.
- **What it changes:** two instructions, each turned into a `bl` into the block's fixed entries:
  - `0x0800F464`: `mov.w r8, #1`, the SysEx dispatcher's unknown-command fallthrough. It becomes `bl 0x0807DC00`.
  - `0x08012456`: `bl 0x0800BEA0`, the main loop's render step. It becomes `bl 0x0807DC40`.
- **The update-mode command (`72`) never reaches either site.** It branches away at `0x0800F29E`.
- Each entry checks our marker word at `0x0807FFDC` before running our code; without it, it does only what the replaced instruction did. See `tools/lc6000-display-fw/arm/README.md`.
- **Status: proven on the owner's unit (2026-11-19),** together with blocks A and B. The owner ran the two-step wizard with no SWD probe; both read-backs matched, the unit looked like stock with no host after the power cycle, and DeckBridge got the drawn display answering ([#468](https://github.com/ericdahl-dev/deckbridge/issues/468#issuecomment-7016642431)). Two checks were not run and stay on #469: that `end` returns to stock images, and that restoring Denon's image works ([#468](https://github.com/ericdahl-dev/deckbridge/issues/468#issuecomment-7031599661)).

## Drawn display: the owner's image and what gets flashed where (#467)

`build_owner_image.py` builds the one file to flash. It takes the stock file and our block, applies the hook patch, places the block in the padding, and recomputes both CRCs.
- The output must be outside the repository.
- It refuses a block that isn't exactly the 9,184-byte padding or doesn't end with our marker, so the hook never goes out without its block.

**Two blocks (#501).** `make arm` builds both:
- **Block A,** `block.bin`: the hook and the protocol, placed in the image's padding by `build_owner_image.py`.
- **Block B,** `upper.bin`: the drawing, with its own `.dfu` at `0x08080000` (see "Block B's own file" below).

Block A reads B only when it is built with `ARM_UPPER_PROVEN=1`. That is the default since the owner's read-only checks below proved the upper flash (#573). Built with `ARM_UPPER_PROVEN=0`, A never reads `0x08080000`, so it never answers the app's capability ask: DeckBridge stays on images and the unit behaves as stock.

```sh
make -C tools/lc6000-display-fw arm                       # the flashed build: A reads B; also writes build.json (#572)
python3 -I tools/lc6000-firmware/build_owner_image.py ~/lc6000/jc20_wd_update_00_50_3A7CE2CA.dfu \
  tools/lc6000-display-fw/build/arm/block.bin ~/lc6000/jc20_wd_00_50_drawn.dfu --show-slot-16
```

**Options:**
- **Slot 16: you must choose; there is no default.** `--show-slot-16` keeps the slot 16 patch (#425), and `--no-show-slot-16` leaves it out. A build that names neither is refused.
  - **The owner's unit runs slot 16 now, and DeckBridge (Firmware = Custom) uploads 16 slots. Keep it on.** Without it, image mode loses slot 16 (deck 4, beat 4) after the flash.
  - With it on, the first drawn flash changes only one thing: the hook and its block.
- `--vos-scale-1` adds the core voltage fix (#438). **It is off by default.** Flash it on its own later, so a problem can be traced to one change.

**What goes where:**

| What | Address | How |
|---|---|---|
| The owner's image: stock code, the hook, block A in the padding, the trailer | `0x08008000`-`0x0807FFFF` (sectors 2-7) | One `.dfu`, by the same route as slot 16 (#425), then read back and compare with `dfupatch.py compare` |
| Block B, the drawing | `0x08080000` and up (sectors 8-11, up to 512 KB) | Its own `.dfu` (`build_upper_dfu.py`). **Never before the read-only checks below** show that flash exists and is erased |
| Nothing | sectors 0-1, option bytes | Never written |

**Way back:** the same as for every `wd` image. Put it in update mode and flash the stock file, or use Denon's updater.
- Block A lives inside the image, so restoring stock removes it with the hook.
- Block B is outside the image, and Denon's updater never erases sector 8 (#434), so B stays after a restore. That's harmless: only block A ever calls into B, and stock never does. A without B, or B without A, behaves exactly like stock.
- A crash in our code after boot is cleared by a power cycle: drawn mode starts only on our message (see `tools/lc6000-display-fw/arm/README.md`).
- A crash before the update-mode command can run needs SWD (#433), as for any changed `wd` image (#434).

### Read-only checks before the first drawn flash (the owner runs these; nothing is written)

**Where the files go:** every file these steps write goes in `~/lc6000`, never in the repository. They are reads of your unit, and they are never committed or posted; post only what the checks print. `dfu-util -U` won't overwrite an existing file, so move an old one aside first.

**You need:** `dfu-util` (`brew install dfu-util`), and `enter-update-mode`, built as the flash day kit builds it:
`swiftc -O -swift-version 5 tools/lc6000-firmware/enter-update-mode.swift -o ~/lc6000/enter-update-mode`, then `~/lc6000/enter-update-mode selftest`, which sends nothing.

They answer what static analysis can't (#466): whether flash above the image exists and is erased, and how the chip's option bytes are set. Block B (#501) goes in that flash, and it is never flashed before these reads. `build_upper_dfu.py` checks step 4's read itself before it writes B's file.

1. Quit DeckBridge and anything else that talks to the unit.
2. Put the display chip in update mode:
   - Run `~/lc6000/enter-update-mode check`. It sends nothing and must find exactly one WD port.
   - Then run `~/lc6000/enter-update-mode send --yes-enter-update-mode`. The jog screen goes dark.
   - If `check` fails, stop here and post what it printed on #467. The BACK + FWD + VINYL buttons enter update mode on the top panel chip, not the display chip.
3. Run `dfu-util -l`. Expect one `0483:df11` device, `STM32  BOOTLOADER`, at the WD path. Use the path `dfu-util -l` shows in the commands below as `PATH`: it depends on the USB port (`0-1.2` and `2-1.2` on the owner's unit).
   - Alt 0 should read `@Internal Flash  /0x08000000/04*016Kg,01*064Kg,07*128Kg`, which is 1 MB, single bank (#432).
   - If there is more than one device, or the layout differs, stop.
4. Read the flash above the image, 512 KB:
   `dfu-util -p PATH -a 0 -s 0x08080000:0x80000 -U ~/lc6000/wd-upper-512k.bin`
   - Expect 524,288 bytes, all `0xFF`: `python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); print(len(d), set(d))" ~/lc6000/wd-upper-512k.bin`.
   - A read error here means that flash isn't there. Record it.
5. Read the option bytes, both blocks the ROM lists (alt 1):
   - Nothing hangs on reading these by hand: `flash-day.sh drawn` reads bank 1 itself and checks it before it writes anything (#468). This read is for the record on #467.
   - `dfu-util -p PATH -a 1 -s 0x1FFFC000:16 -U ~/lc6000/wd-option-bytes-1.bin`
   - `dfu-util -p PATH -a 1 -s 0x1FFEC000:16 -U ~/lc6000/wd-option-bytes-2.bin`
   - What to read, per RM0090's option-byte table:
     - RDP is the byte at offset 1. `0xAA` means level 0, which matches the reads already done on #432.
     - nWRP is the low 12 bits of the half-word at offset 8, one bit per sector, 1 = not write-protected. Sectors 8-11 must read 1.
     - DB1M is bit 14 of that same half-word. 0 means single bank, matching the layout string.
6. Try the flash-size word, `dfu-util -p PATH -a 0 -s 0x1FFF7A22:2 -U ~/lc6000/wd-flash-size.bin`. Expect `00 04` (0x0400, 1,024 KB).
   - It isn't inside any alt setting the ROM lists, so the ROM may refuse it. Then it is a read for SWD (#433). The layout string in step 3 already says 1 MB.
7. **Leave update mode:** switch the unit off, wait 5 s, and switch it on with no buttons held. Update mode only reads, and nothing was written, so the display chip comes back in its own app with the stock picture. If the screen stays dark and `dfu-util -l` still lists the bootloader, do as the flash day kit does: open Denon's updater, which restores a chip that is in update mode (#434). That restore is not yet proven on the display chip (#469).
8. Post the results on #467. Never write anything in this session.

### Block B's own file (#501)

`build_upper_dfu.py` writes block B as its own `.dfu`: one element at `0x08080000`, for the ST bootloader (`0483:df11`). Nothing here talks to the unit.

```sh
python3 -I tools/lc6000-firmware/build_upper_dfu.py tools/lc6000-display-fw/build/arm/upper.bin \
  ~/lc6000/wd-upper-drawing.dfu --proof ~/lc6000/wd-upper-512k.bin
```

It refuses:
- **The proof:** if `--proof` is missing, or the file isn't the whole read of step 4 above (524,288 bytes, all `0xFF`), or it is inside the repository. A flag anyone can type isn't proof, so the tool reads the file itself.
- **The block:** if its header doesn't check out the way block A checks it (`upper_header.py`, #572): marker `DFWB`, version 4, a length equal to the file and at most 512 KB, CRC-32, and a draw entry and a band entry (#524) that are Thumb code inside B. It can't check the layout word (#516): only block A can, on the chip, so A and B come from the same commit.
- **The output:** if it is inside the repository, or the file already exists.

**Order, after the read-only checks:** build with `ARM_UPPER_PROVEN=1`, flash B's `.dfu`, then the owner's image. Either order is safe: A checks B's header before it calls anything in B, and stays silent until B checks out. Each flash is a separate step the owner runs, with its own OK. `flash-day.sh drawn` walks through both (see "The drawn flash" below).

### The build record (#572)

`make arm` writes `build.json` next to `block.bin` and `upper.bin`. It holds each block's sha1, plus `ARM_DRAW` and `ARM_UPPER_PROVEN` for block A.

```sh
python3 -I tools/lc6000-firmware/build_record.py check build.json OWNER.dfu UPPER.dfu
```

`check` trusts the record only for the bytes it names. Block A inside the owner's image and block B inside its `.dfu` must both have the record's sha1. That also shows A and B come from the same build. Then A must have been built with `ARM_DRAW=1` and `ARM_UPPER_PROVEN=1`.

A missing, unreadable or mismatched record refuses. Nothing is assumed and no one is asked.

The flags live in the record, not on the unit. Making them readable from a read of the unit would need new header fields, which wait for #570's two-block flash.

## Flash day kit (#435)

Four pieces for flashing the display chip, all run **by the unit's owner**, never by an agent:

- `flash-day.sh`: a step-by-step wizard. It checks the stock file, puts the display chip into update mode, lists what `dfu-util` sees (exactly one device, or it stops) and backs up the settings sector and the app (read-only). Then **Denon's own updater does the stock flash**: on this unit it flashes a chip that's in update mode and refuses a running, current one (seen 2026-11-19 on the top panel chip). If the updater won't, the wizard offers the same stock file through `dfu-util`, after you type `FLASH`, and reads it back. Then you power-cycle and it checks the display's MIDI port returns. A patched image is an optional last step, off by default: it goes through `dfu-util`, only after the chip is confirmed to hold stock, and is read back and compared. Everything it saves goes to `~/lc6000` (or `$LC6000_WORK`), outside the repo.
- `enter-update-mode.swift`: sends the stock updater's one "enter update mode" SysEx to the unit's WD port. `selftest` and `check` send nothing; `send` needs `--yes-enter-update-mode` and exactly one WD port.
- `dfupatch.py compare <file.dfu> <readback.bin>`: checks a raw read-back of the app area against a `.dfu`'s image and says where the first difference is.
- `drawn_flash.py`: the drawn flash's checks (#468). `files` checks that B's file and the owner's image are each in their place; `upper` judges a read of the upper flash against B's file. It reads files only.

```sh
brew install dfu-util
tools/lc6000-firmware/flash-day.sh
```

### The drawn flash (#468)

`flash-day.sh drawn [--current PATH] [--upper PATH --owner PATH] [--probe-again]` does the two writes of the drawn display. It's run by the owner after the read-only checks above, with B's `.dfu` and the owner's image built. There is no stock flash: the chip must already hold a known image (stock, your slot 16 file, or the owner's image).

**It asks only what it can't find out itself (#603).** A typed word before each send or write, shown with the file, its sha256 and the address range: `UPDATE` for the update-mode message, `FLASH` or `REWRITE` for block B, `FLASH` for the owner's image. The probe question is asked only when the owner's image is to be written, up front before any write, and kept for the day. Everything else is found and printed, or watched on USB. Stops per path, pinned by `test_flash_day_runs.py`: first flash 4, B-only rewrite 2, B-only with the chip already in update mode 1, two-block rewrite 4; without a probe, one more the first time in a day.

- **Files.** Block B and the owner's image are found, not asked: the newest build the kit tools left in `~/lc6000` (each `.dfu` with its build record beside it), since the normal rewrite is "rebuild, then flash"; with no build there, the last run's pair. `--upper` and `--owner` name them. Asked only when there's no build anywhere, or two newest from the same moment. `build_record.py` records the commit and build time, and each word screen shows them, plus last run's commit when it differs.
- **The image the chip runs now.** Found from the read: the owner's image, the last run's file, or a `.dfu` in `~/lc6000` that matches byte for byte. It's the way back, so a read that matches none of them stops. `--current PATH` names a file kept elsewhere.
- **Apps.** DeckBridge, djay Pro (it ships LC6000 MIDI mappings), Engine DJ (it knows the LC6000 as a controller) and Denon's updater are waited for, then refused after 60 s. Syndicate isn't on the list: DeckBridge sits between it and the unit.
- **Update mode.** A chip already in update mode (a re-run after a stop) is listed, so nothing is sent.
- **Probe.** The answer, yes or no with `NO PROBE` typed, is kept in `~/lc6000/probe.json` for today and this unit's DFU serial, and shown on the owner's image's screen. `--probe-again` forgets it. A B-only rewrite never asks: block B runs only after the host's own command, and update mode branches off before the hook.
- **An interrupted write of the owner's image.** The wizard records each write of the owner's image (`~/lc6000/app-write.json`) until its read-back matches. A re-run that finds a half-written app area offers that same write again (same file, same sha256, same unit), behind `FLASH`. Anything else unknown still stops.
- **Power cycle.** Seen on USB: the DFU device leaves, then the display's MIDI port comes back, 120 s each. A timeout says what to check and stops.
- **Refused, not asked:** a device whose layout isn't the display chip's (in the stock wizard's look too).

1. **Ready check.** Nothing is sent. It verifies the owner's image (and `--current`'s file, if given). `drawn_flash.py files` checks that B's file is one element at `0x08080000` that passes block A's header checks, and that the owner's image is a `wd` image at `0x08008000`, so the two can't be swapped. Then it reads `make arm`'s build record (`build.json`), and doesn't ask you (#593). `build_upper_dfu.py` and `build_owner_image.py` each copy that record next to the .dfu they write (`wd-upper-drawing.build.json`, for example), so the wizard finds it there and prints which one it uses. It asks for the path only when there's no record, or when the two copies differ. The record must name the exact block A inside the owner's image and the exact block B inside its .dfu, so both come from one build (#516). It must also say A was built with `ARM_DRAW=1` and `ARM_UPPER_PROVEN=1`. If the record is missing or doesn't match, the run stops, and nothing is sent.
2. **Update mode and look**, as on the first flash day.
3. **Before (read-only).** It reads the app and finds the image the chip runs now in it, as above.
   - It reads the option bytes (`0x1FFFC000`, 16 bytes, alt 1), and `drawn_flash.py options` checks them: read protection at level 0, sectors 8-11 not write-protected, one bank. Otherwise it stops with a plain message, and nothing is written.
   - Then it reads all of `0x08080000`-`0x080FFFFF`, and `drawn_flash.py upper` judges that read against B's file:
     - erased: go on;
     - exactly this B, then erased: step 1 is already done (a re-run);
     - part of this B (a cut-off write), or a B from another build whose header and CRC check out, then erased: step 1 rewrites it. Every layout change makes a new B (#516), so B is never write-once;
     - anything else: stop, and nothing is written over it.
4. **Step 1: block B**, after you type `FLASH`, or `REWRITE` when it replaces what's there. A rewrite writes `drawn_flash.py rewrite`'s file: this B, then erased bytes to the end of the old one, since a write erases only the sectors it covers. It reads all of the upper flash back and must find exactly B, then erased flash. With only B on the chip, the image there runs as before.
5. **Step 2: the owner's image**, after you type `FLASH` again. It's read back and compared, as every image is.
6. **Power cycle**, seen on USB. With no host the display should look like stock: the wizard prints it as a check. Then DeckBridge in drawn mode draws the deck chip, and `end` brings back stock images. Write what you see on #468.

**Where the decisions live (#567).**
- `drawn_plan.py` decides every step of the drawn flash, from the facts so far: the owner's three files, each answer and typed word, each read, and each write's result. `flash-day.sh drawn` is a thin loop: it asks `drawn_plan.py next` for one step, does it with `dfu-util` or the keyboard, records the result with `drawn_plan.py record`, and asks again.
- **Every write rests on a read made in the same run, after update mode was entered.** A plan file from an earlier run authorizes nothing.
- `drawn_flash.py` and `dfupatch.py` hold the judges the plan uses, and they only read files.

**How it's tested.**
- `test_drawn_plan.py` runs whole flashes against a fake unit: a fresh flash, a B-only rewrite, a cut-off write of B, the device list (none, two, the top panel chip, another layout), the found files, the kept probe answer, the word screens, and every refusal.
- `test_flash_day_runs.py` runs the real `flash-day.sh drawn` with stand-ins for `dfu-util`, the update-mode tool, `pgrep` and `swiftc`, on a `PATH` that can't reach the real ones. Its fake unit enters update mode on the stand-in's send and power-cycles when the wizard waits for it. It pins the stops per path.
- The wizard itself is never run by an agent against the unit, since it calls the real `dfu-util`.

**Seen on hardware (2026-11-19):** ST's ROM bootloader, entered by the update-mode SysEx, allows reading flash; a power cycle leaves it and starts the app; and it takes a changed image, which the startup stage starts when its CRC is right ([#425](https://github.com/ericdahl-dev/deckbridge/issues/425#issuecomment-7000989396), [#435](https://github.com/ericdahl-dev/deckbridge/issues/435#issuecomment-7031597620)). **Still unproven:** restoring the display chip to Denon's stock image (open on #469). The wizard stops at each surprise and prints the way back (power cycle; then update mode plus Denon's own updater; then SWD, #433). A patched image still reports version 00.50, so the updater calls a running patched unit current: put the chip in update mode first. Have an ST-Link on the desk first. Never run Denon's updater "to look": it starts erasing as soon as it finds the unit.

The top panel chip needs none of this: hold BACK + FWD + VINYL at power-on and it enters ST's ROM bootloader (seen on hardware, #432); a power cycle leaves it.

The tests (`test_flash_day.py`) guard the kit's shape without hardware: one write, behind the typed word; no mass-erase, unprotect, option-byte or bootloader-sector access; reads only in the settings and app sectors.

## What it recomputes

1. **The `wd` trailer CRC.** The last 32 bytes of the image are a trailer: version, `0xDEADBEEF`, the number of bytes covered (element size − 20), the CRC, then `EndOfFlashToken\0`. The CRC is the **STM32 hardware CRC unit**'s algorithm (CRC-32, polynomial `0x04C11DB7`, init `0xFFFFFFFF`, little-endian 32-bit words, no reflection, no final XOR) over element bytes `0` to `0x77FEB`, so it includes the length field. On the stock image it gives `0x3A7CE2CA`, the hex in the file name.
2. **The DfuSe suffix CRC.** zlib CRC-32 over the whole file except its last 4 bytes, XORed with `0xFFFFFFFF`.

Nothing else changes: every byte outside the patched ranges, the trailer CRC and the suffix CRC stays as it was.

## Verification

- `python3 -I -m unittest discover tools/lc6000-firmware` runs the tests. They build their own synthetic DfuSe files, so they need no vendor data; CI runs them in the Site check job. They pin the CRC to a known answer (one word `0x12345678` gives `0xDF8A8A2B`), check that a no-op patch reproduces the input bit for bit, and that a one-byte patch changes only that byte and the two CRCs.
- `verify` on your own stock `wd` file must print `0x3A7CE2CA` and report a bit-for-bit round trip. If it doesn't, stop: your file isn't the one this tool was written against.

## The `tp` image

The **top panel (`tp`)** image can be patched too. Its trailer has no magic, length or CRC: a version, one word (`0x0001D868`, also in the file name) and `EndOfFlashToken\0`.

The unit's own startup stage was read out through ST's ROM bootloader and analyzed (#432, #434). Before it starts the app it checks **one thing**: the last 16 bytes of the image are `EndOfFlashToken\0`. There is no checksum, length, version or vector check, and the `0x0001D868` word is never read (its meaning is still unknown).

So for a `tp` image the tool:

- tells the chip from the trailer (`wd` has the `0xDEADBEEF` magic; `tp` doesn't);
- applies the edits, refusing any that reach into the last 32 bytes;
- leaves the trailer exactly as it was, and recomputes only the DfuSe suffix CRC.

`verify` on the stock `tp` file prints `ok: tp image, EndOfFlashToken present; it has no checksum …`.

`tp` is also the safe chip to experiment on: BACK + FWD + VINYL at power-on enters ST's ROM bootloader, which nothing in flash can remove; flash isn't read-protected; and Denon's updater restores stock from that mode (all seen on hardware, 2026-11-19, [#432](https://github.com/ericdahl-dev/deckbridge/issues/432#issuecomment-7000392340), [#435](https://github.com/ericdahl-dev/deckbridge/issues/435#issuecomment-7000152436)). A patched `tp` image boots: a one-byte test image and the no-deck-select patch were both flashed, verified by read-back and run on the owner's unit (2026-11-19, #435, #439).

## What isn't known yet

- **The `wd` CRC check.** The display chip's startup stage checks the end token and the STM32 CRC, and falls back to ST's ROM bootloader on a mismatch. That was read from the owner's own read-out ([#434](https://github.com/ericdahl-dev/deckbridge/issues/434#issuecomment-7000894739)), and an image with a correct recomputed CRC was started on the unit ([#425](https://github.com/ericdahl-dev/deckbridge/issues/425#issuecomment-7000989396)). The stale-CRC case was not run on the unit; the analysis answers it ([#435](https://github.com/ericdahl-dev/deckbridge/issues/435#issuecomment-7031597620), [#434](https://github.com/ericdahl-dev/deckbridge/issues/434#issuecomment-7031596085)).
- **Restoring the display chip to stock.** No hardware result is recorded anywhere. The routes are the update-mode SysEx, then `dfu-util` with the stock file, or Denon's updater while the chip is in update mode. The check is open on #469 ("Denon's firmware restores cleanly").
