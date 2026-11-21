# Firmware updater

A separate Mac app (spec #684) with two sections, deck panel and LC6000. Today (#685) it only looks: it says what is
plugged in and writes nothing to any device. It is not part of DeckBridge or its App Store build, and shares nothing
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
  serial port, and the app listens there for 3 s, read-only, with DTR and RTS held off so the panel isn't reset. The
  build shows only if the panel boots while the app listens; otherwise it says "Build not read". Asking a running
  panel for its version is #715.
- **LC6000:** its MIDI port names ("LC6000 PRIME …"), and ST's bootloader (0483:DF11) for a unit in update mode.
  Nothing is sent to it; its firmware is checked in a later ticket (#692).

## Log

`~/Library/Logs/FirmwareUpdater/updater.log`: one line per device found. No serial numbers, port paths, MAC addresses
or Wi-Fi details.
