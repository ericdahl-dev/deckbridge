# Firmware updater

A separate Mac app (spec #684) with two sections, deck panel and LC6000. Today it only looks: it says what is plugged
in. Its one write is the text line `version` to the deck panel's own console (#715); nothing goes to the LC6000. It is not part of DeckBridge or its App Store build, and shares nothing
with it at runtime.

## Build and run

```sh
scripts/updater.sh          # build (Debug) and open
scripts/updater.sh build    # build only
```

Needs Xcode 26 and XcodeGen (`brew install xcodegen`). The logic lives in `Packages/FirmwareUpdaterKit`, tested with
`swift test` there.

## What it reads

- **Deck panel:** the CrowPanel's USB serial chip (CH340K, 1A86:7522) in the USB list. With WCH's CH34x driver it has a
  serial port. The app opens it with DTR and RTS held off so the panel isn't reset, at 921600 (#711's board wiring),
  writes `version` and listens 3 s for the answer (#702's firmware) or a boot line. Nothing read: the same at 115200,
  today's firmware's speed. A panel that answers at neither shows "Build not read".
- **LC6000:** its MIDI port names ("LC6000 PRIME …"), and ST's bootloader (0483:DF11) for a unit in update mode.
  Nothing is sent to it; its firmware is checked in a later ticket (#692).

## Log

`~/Library/Logs/FirmwareUpdater/updater.log`: one line per device found. No serial numbers, port paths, MAC addresses
or Wi-Fi details.
