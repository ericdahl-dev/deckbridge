# Adding a controller

How a new controller gets a bundled profile, from an owner's capture to a release. The loop is
**capture → draft → review → TestFlight build for the owner → bundle**.

## 1. Capture

The owner records what their controller sends. There are two ways, and both write the same file (`ControllerBridgeCapture`,
format 1):

- **In the app.** When DeckBridge sees a controller it has no profile for, the panel says so and offers
  **Help add it…**, also while a supported controller is connected (#329). The capture window opens with that device
  chosen and walks the owner through about 27 steps: hands off
  for 5 seconds (which records the noise, such as heartbeats), then Play, Cue, Sync, pads 1–8, the pitch fader, the
  jog (touched and spun on the edge), the needle strip, the loop buttons, the browse knob, Shift, three steps repeated
  with Shift held, a switch to deck 2, and deck 2's Play. A step can be skipped. At the end the owner saves the file or
  emails it to us.
- **On the website** (#190), in Chrome or Firefox with Web MIDI. The browser writes the raw messages; the Kit works out
  the controls when it reads the file (`CaptureFile.inferred()`, #250).

The file keeps only MIDI, the step it belongs to, and an optional note the owner typed.

## 2. Draft

```sh
scripts/capture_to_profile capture.json --docs facts.json --out drafts/
```

This writes three files, named after the profile's id (a slug of the device name):

- **`<id>.json`**: the draft profile.
- **`<id>.fixture.json`**: the capture's traffic as a replay test.
- **`<id>.report.md`**: what to review.

`--docs` is optional. It's a partial profile in the profile's own JSON shape, plus a `sources` object with one
citation per dotted key:

```json
{
  "mapping": { "notes": { "sync": 88 }, "pitch": { "invert": true } },
  "sources": { "mapping.notes.sync": "DDJ-FLX4 MIDI list p.1", "mapping.pitch.invert": "Mixxx DDJ-400 XML L321" }
}
```

Take docs facts from the manufacturer's MIDI chart or from Mixxx's public mappings, and cite them. **Never take bytes
from djay, Serato or Engine captures.**

How the draft decides:

- **The capture wins.** When the docs say something else, the report lists the disagreement with both values, and the
  capture's value is kept.
- **The docs fill gaps.** A key the capture didn't set comes from the docs, and the report lists it with its source.
- **Nothing is guessed.** Whatever neither one knows is a TODO that says how to find it. These are always TODOs:
  - the jog's counts per turn (it needs a measured full turn)
  - decks 3 and 4
  - per-mode pad notes and how the pad mode is chosen (the capture only records Hot Cue mode)
  - the LEDs
  - any button the capture has no step for
  - the mixer (`mapping.mixer`, #207): the capture has no mixer steps yet, so take the faders, EQ, filter, cue/mute/solo
    and the VU meter from the MIDI chart
- **What the capture reads:**
  - the buttons' notes, with the deck's channel taken from Play
  - the pads, and their channel when it isn't the deck's
  - the pitch fader: a 14-bit pair or one 7-bit CC, and whether it's inverted
  - the needle strip and its touch note
  - the browse knob and the relative encoder format
  - the jog: an absolute pair, or a relative CC with its edge CC, plus the touch note
  - the layers and the layer note
  - Shift done in hardware (`notes.shifted`)
  - the noise notes to ignore

## 3. Review

Work through `<id>.report.md`:

1. **Import check.** Fix every problem listed. The draft has to pass the same check a bundled profile does, and load as
   a profile file: the report includes the decoder's own rules, such as a jog with no pair and no `relative_cc`.
2. **Placeholders.** A profile file needs its other sections, so each key the capture and the docs didn't give is
   filled with the LC6000's value and listed under "Placeholders from the LC6000". Replace each one with the
   controller's real value. A control the capture found nothing for (the needle strip, jog, pitch fader or browse
   knob) is left out instead (#341), as for a controller without one; add it if the controller has one.
3. **Disagreements.** For each one, decide whether the capture or the docs is right, and note why in the PR.
4. **TODOs.** Resolve each one: with the owner and MIDI Monitor, from the chart, or by leaving the key out because the
   controller has no such control. A TODO you can't resolve goes in the PR as a known gap.
5. **Name and hints.** Set `id`, `name` and `device_hints` to what the controller's ports are really called. The
   draft uses the device name the capture saw. Check that `exclude_hints` names every port that isn't for the
   controls, such as a display port.

## 4. TestFlight build for the owner

1. Put the profile in `Packages/ControllerBridgeKit/Sources/ControllerBridgeCore/Resources/Profiles/<id>.json` and
   add its id to `ControllerProfile.bundledIDs`.
2. Put the fixture in `Packages/ControllerBridgeKit/Tests/ControllerBridgeCoreTests/Resources/Fixtures/<id>.json`.
   The replay test (`ReplayFixtureTests`) runs every fixture against the bundled profile it names. Each step's MIDI
   goes in, and the steps whose result is certain (Play, Cue, Sync, the loops, hot cues, deck 2's Play) must send
   exactly the OSC the fixture lists.
3. Open a PR, test-first as always. Once it merges, tag a build for **internal** testers. A tag without `[external]`
   goes to the Internal group only (docs/TESTFLIGHT.md).
4. Ask the owner to run the hardware check (docs/HARDWARE-CHECK.md) with their controller and Syndicate, and report
   anything that's wrong.

## 5. Bundle

Fix what the owner found, with a test for each fix. When the owner's check passes, the profile ships in the next
release. Close the controller's issue with the owner's check and the known gaps.
