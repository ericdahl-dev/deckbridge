# Deck panel update protocol

How the firmware updater (#691) sends a signed firmware release to a deck panel over Wi-Fi (#690). The signing and
the manifest are ADR 0012's; this is the wire between the Mac and the panel. The panel's side is
`tools/deck-panel/lib/update_link` and `lib/update_session`, tested in the native env.

## Connection

- TCP, port **3310** on the panel. The display feed is UDP; nothing else uses this port.
- **One connection at a time.** A second one gets `refused busy` and is closed; the first carries on.
- The connection is the update: it ends with a switch or a refusal, and the panel closes it.

## Frames, Mac to panel

Each frame is one type byte, a 4-byte **little-endian** length, then that many bytes.

| Type | Payload | Cap (checked from the header, before a byte is kept) |
|---|---|---|
| `M` | the release's `manifest.json`, its exact bytes | 32 KB |
| `S` | `manifest.sig`: the 64-byte Ed25519 signature over those bytes | exactly 64 |
| `I` | the next piece of the deck panel image | 4 KB |
| `D` | done: the image is all sent | 0 |

The order is always `M`, `S`, then `I`... and `D`. Any other order, an unknown type or a frame over its cap is
refused, and the connection is closed.

## Lines, panel to Mac

One text line per step, ending in `\n`:

| Line | When |
|---|---|
| `ok manifest` | the signature checked out and every rule passed; the panel has erased the image's size in its spare slot |
| `progress <bytes>` | after each `I` frame: image bytes taken so far |
| `ok switched <version>` | after `D`: size and SHA-256 match, the new image is set to boot. The panel then closes the connection and restarts into it |
| `refused <reason>` | anything else, then the panel closes the connection. The old firmware keeps running |

Reasons: `busy`, `no-manifest`, `too-large`, `unreadable`, `unknown-key`, `bad-signature`, `unknown-format`,
`no-image`, `too-old`, `too-big`, `mismatch`, `timeout`, `slot-error`.

## What the panel checks, in order

1. **Nothing touches flash before the signature.** Until `S` checks out, the only thing read from the manifest is
   the name of the key that signed it.
2. **Signature:** the key the manifest names must be one the panel trusts (`lib/release_keys`, the same list as the
   app's `ReleaseKeys.swift`; empty until the owner makes the keys, so every update is `unknown-key` until then).
   The signature is checked over the manifest's exact bytes.
3. **Rules:**
   - `format` must be 1.
   - There must be a `deck-panel` file.
   - Its version must not be below the panel's **floor** or the manifest's `lowest_allowed`. The floor is kept in
     the panel's NVS and only ever raised: to the manifest's `lowest_allowed`, once the new image has confirmed
     itself. So a validly signed older image can't be sent back after a security fix.
   - It must fit the spare slot.
4. **Image:**
   - It is hashed as it arrives.
   - More bytes than the manifest's size are refused at the first extra byte.
   - At `D`, the size and SHA-256 must equal the manifest's, or the update is `mismatch` and the slot is never booted.
5. **After the switch:**
   - The new image boots as a trial.
   - It confirms itself once what recovery needs is up, within 120 s: its saved Wi-Fi joined, or, with no saved
     Wi-Fi, its setup network up. The update server must be listening too.
   - If that doesn't happen, the panel restarts into the previous image.
   - The display feed is not asked for, so an update with DeckBridge closed doesn't roll a good image back.

## Timeouts and a dropped link

- **Before the signature has checked out:** 3 s with nothing received ends the connection (`refused timeout`). A
  stray connection can't hold `busy`.
- **Mid-image:** 10 s with nothing received ends it.
- **The connection closing before `ok switched`:** nothing is switched. The bytes written so far are dropped and the
  old firmware keeps running. Power loss mid-transfer is the same: the boot slot was never changed.

## Open points for #691

- **Finding the panel.** Today the panel's address is shown on its waiting screen, so the app can take it typed in.
  Later: an mDNS name or a UDP answer to a broadcast.
- **What the app shows during the update:** the panel shows a still "Updating" screen while it writes flash,
  because flash writes make the picture tear.
