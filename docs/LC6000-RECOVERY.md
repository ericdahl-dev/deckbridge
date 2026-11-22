# LC6000 recovery guide

For when an update from the DeckBridge Firmware Updater (#693) went wrong: the read-back didn't match, the chip stopped answering, or the LC6000 doesn't start afterwards. It's drawn from what's been seen on the owner's unit and recorded in [`tools/lc6000-firmware/README.md`](../tools/lc6000-firmware/README.md). Where something hasn't been seen on hardware yet, this guide says so.

Before anything else:

- **Don't unplug the LC6000 mid-step.** Leave it powered and on USB until a step has finished or clearly failed.
- **Keep the backup.** The updater saved it before writing: two files per chip, in the folder you picked. It's your own unit's flash, and the only copy of it. Don't send it to anyone or post it.
- **Quit DeckBridge** while you do any of this. It talks to the LC6000 over MIDI.

Work down the steps, and stop at the first one that brings the unit back.

## 1. Power cycle

Switch the LC6000 off, wait 5 seconds, and switch it on with no buttons held.

Update mode only lasts until a power cycle. A chip whose update was written and checked starts its new image now. A chip that was only read starts its old one. This has been seen on hardware for both chips (2026-11-19).

## 2. Restore your backup with the updater

If the updater showed **The chip read back different**, use **Restore backup** while the chip is still in update mode. It writes the backup's bytes back to the same sectors the update wrote, then reads them back and compares. No other sector is touched.

If the unit has left update mode since, put it back in (step 3 for your chip), open the updater, and use **Restore backup**.

## 3. Get the chip back into update mode

ST's ROM bootloader lives in the chip's system memory, not in its flash, so nothing written to flash can remove it.

- **Top panel chip (`tp`):** hold **BACK + FWD + VINYL** while you switch the LC6000 on. The chip enters ST's ROM bootloader whatever its flash holds. This has been seen on hardware (2026-11-19, #432, #435).
- **Display chip (`wd`):** there is no button combination. It enters update mode only when its own running firmware gets the update-mode command over MIDI: the updater's update-mode step, or the flash kit's. If the display chip's firmware doesn't start, this can't work. Go to step 5.

Then run step 2.

## 4. Denon's own updater, as a last resort before a probe

Denon's updater restores a chip that is in update mode to its stock firmware.

- For the **top panel chip** this has been seen on hardware (2026-11-19, #432).
- For the **display chip** it has **not been seen on hardware**: it's open on #469.

Never run Denon's updater "just to look". It starts erasing as soon as it finds the unit. DeckBridge doesn't supply Denon's firmware or its updater.

## 5. A hardware debug probe (SWD)

If the display chip's firmware doesn't start, nothing on USB can reach it: its update mode needs its own firmware running. The way back is an ST-Link (or another SWD probe) on the chip's debug pins, with the unit opened. That work is tracked on #433. Don't attempt it without the notes there.

This is the worst case that the updater's warning and its confirm name before anything is written.

## What the updater writes

Only the flash sectors whose bytes the update changes. Each is erased and written whole, then read back and compared. The confirm lists them, with their addresses and sizes, before anything is sent.

- **Display chip, slot-16 patch:** `0x08008000-0x0800BFFF` (16 KB, the patched instruction) and `0x08060000-0x0807FFFF` (128 KB, the image's trailer CRC).
- **Top panel chip, no-deck-select patch:** `0x08010000-0x0801FFFF` (64 KB).

Every other sector is untouched, including the bootloader area and the settings sector. **Restore backup** writes the same sectors.

## Block B on the display chip

Block B is DeckBridge's drawing for the jog display (#751). The updater installs it at `0x08080000` and up, in sectors 8-11 (`0x08080000-0x080FFFFF`, 128 KB each), outside Denon's image. Before writing, it reads that area twice and saves it beside the chip's backup as `lc6000-display-upper-<time>.bin`.

- **What it writes:** only the sectors from `0x08080000` whose bytes change. That's block B, then erased flash to the end of any longer B that was there. Nothing below `0x08080000` is written: not Denon's image, not our hook or block A, not the settings or the bootloader area.
- **If it went wrong:** block A checks B's header, CRC and layout before it calls anything in it, and stays silent for a B that fails them. Stock's own drawing runs either way. The kit's tests show both (`tools/lc6000-display-fw/arm/test/test_block.py`), on an emulator, not yet on hardware. A write cut off partway should fail B's CRC, since B's header, with its CRC over all of B, is in the first sector written. That's inferred, not tested.
- **If the read-back didn't match:** use **Restore backup** while the chip is still in update mode. It writes the saved area's bytes back to the same sectors and reads them back.
- **If the chip has left update mode, or stopped answering:** a B install doesn't touch the display chip's firmware, so its update-mode step still works (step 3). Put it back in update mode, back it up again, and install block B again: the updater rewrites whatever differs. The updater can't load an earlier `lc6000-display-upper-*.bin` yet; keep it anyway.
- **Denon's updater doesn't touch block B** (it never erases sector 8, #434). A B left there after a restore to stock is harmless: only our block A ever calls it.

