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

`~/Library/Logs/FirmwareUpdater/updater.log`: a "first look" line per launch, in status words only (#734), and one line per device found. No serial numbers, port paths, MAC addresses
or Wi-Fi details.

## Launch smoke check (#734)

`scripts/updater_smoke.sh` starts the built app with `--smoke`. The app logs its first look and quits. The check passes
only if the app quits with status 0 within 60 s and the run's only log line is
`first look: deck panel not found, LC6000 not found`. CI runs it on the Release build in the app job.

It needs nothing plugged in: it reads the USB device list first (`ioreg`) and stops without starting the app if a deck
panel or an LC6000 is there, since the app's first look opens a panel's serial port. On a Mac with either one
attached, let CI run it.

## End-to-end check (#734)

For the coordinator and the owner, on the owner's Mac, from a **signed, notarized** build (not Debug). One pass, in this
order. Write each result on #734; anything that fails becomes its own ticket in the "Firmware updater app" milestone,
linked there. Quoted text is the app's wording as of its ticket's branch; if the build says it differently but means the
same, note it and go on.

Before you start: quit DeckBridge (it holds the panel's cable and talks to the LC6000). Keep the stock LC6000 image and
Denon's updater at hand. Note what the panel runs now (build and Wi-Fi network).

### 1. First open from the download (#733)

1. Download the updater from the site and open it from Downloads.
   - **See:** macOS opens it after the usual "downloaded from the internet" question. No "can't be opened" or
     "damaged" message.
2. Look at the Dock and Finder.
   - **See:** the updater's own icon, not a blank app icon.

### 2. What is plugged in (#688)

1. Nothing plugged in.
   - **See:** two sections, "Deck panel" and "LC6000". Deck panel: "Nothing connected". LC6000: its warning first.
2. Plug in the deck panel.
   - **See:** "Deck panel found", without pressing anything. With WCH's CH34x driver installed: no driver warning.
3. Unplug it and plug it back in.
   - **See:** "Waiting for its port" for a moment, then the panel again. Never "The USB driver for its chip is missing"
     while the port is coming back.
4. Only if the driver isn't installed: the guide. "Open WCH's driver download page", the install steps, and
   "If macOS asks, allow the driver in System Settings > General > Login Items & Extensions > Driver Extensions."
   After the install, unplug and replug: the panel shows with no warning.

### 3. The panel's build and version (#715)

1. With the panel running (booted before the app looked), press "Look again".
   - **See:** "Version …, build …", the same build the panel's own screen or DeckBridge shows. Never
     "Build not read" for a running panel.

### 4. Flash the panel over the cable (#687)

1. Start the update over the cable from the catalog's newest panel image.
   - **See:** "Connecting to the deck panel…", then "Writing the new firmware: N%" counting up, then
     "Restarting the deck panel…", then "Updated: the panel now runs … (build …)".
2. Check the panel.
   - **See:** it starts, its screen shows the new build, and it joins the same Wi-Fi network as before (Wi-Fi kept).
3. Cancel, once at each step: while connecting, while writing, while restarting.
   - **See:** before writing: "Canceled. The panel was restarted.", and the panel runs its old firmware. While
     writing: "Canceled while writing. The panel may not start: try again before unplugging it." Then flash again;
     the panel must end up working.
4. With DeckBridge sending over the cable, start the update.
   - **See:** "DeckBridge is using the panel's cable. Turn off "Send over the USB cable" in DeckBridge, then try
     again." Nothing written.

### 5. Update the panel over Wi-Fi (#690, #691, #689)

1. With the panel on Wi-Fi and the cable unplugged, update it from a release signed with the owner's key.
   - **See:** progress, then the panel restarts into the new build. Its screen shows the new build; Wi-Fi kept.
2. Offer it a release signed with a key the app doesn't trust.
   - **See:** refused before anything is sent, with a plain reason. The panel keeps its build.

### 6. The newest release on GitHub (#704)

1. Online, open the app.
   - **See:** "Firmware from the newest release: deck panel …", the version on the repository's latest release.
2. Offline (Wi-Fi off), open the app.
   - **See:** "Firmware built into this app: deck panel …" and "GitHub couldn't be reached, so the firmware built
     into this app is offered." No error box, and the app stays usable.

### 7. LC6000: check and back up, reads only (#692)

1. Open the LC6000 section.
   - **See:** its warning first. Nothing else in the section shows until you accept it.
2. With DeckBridge running, try to start.
   - **See:** "DeckBridge is running. Quit it first: it talks to the LC6000."
3. Put one chip in update mode. Top panel chip: power off, hold BACK + FWD + VINYL while powering on. Display chip:
   type UPDATE and send the update-mode message.
   - **See:** the chip named ("LC6000 top panel chip" or "LC6000 display chip"), and its firmware checked.
4. Back it up to a folder on this Mac, outside any git repository.
   - **See:** "Backup saved: read twice and the same, N files." A folder inside a repository is refused: "That folder
     is inside a git repository. …"
5. Check that nothing was written: power the LC6000 off and on. It starts as before and DeckBridge connects to it.

### 8. The log

1. Open `~/Library/Logs/FirmwareUpdater/updater.log`.
   - **See:** a "first look" line per launch and one line per device and step. No serial numbers, MAC addresses, port
     paths (`/dev/…`) or Wi-Fi network names or passwords anywhere in it.
