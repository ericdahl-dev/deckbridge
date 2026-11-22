# ControllerBridgeKit

All the bridge logic for the native macOS app, as a Swift package that builds and tests from the terminal:

```sh
cd Packages/ControllerBridgeKit
swift test
```

## Testing notes

- **Bind before `.contains` in `#expect`.** `#expect((x?.y ?? []).contains(z))` passes when `x` is nil: Swift Testing
  expands the `contains` call, and the optional chain short-circuits it, so the test can't fail (found in #148). Write
  `let sent = rig.midi.outputs[id]?.sent ?? []`, then `#expect(sent.contains(z))`. Comparisons such as `x?.y == v`,
  `x?.y ?? [] == v` and `(x?.y ?? []).last == v` fail correctly.
- When a new test passes on its first run, check it can fail: revert the change it covers, or bind its subject as above.

## Modules

- **ControllerBridgeCore**: the Coordinator, the Bridge, the mapping and the OSC codec. Pure Swift with Foundation only: no
  CoreMIDI, no Network framework, no UI.

## Controller profiles

A profile file is `{ "id", "name", "device_hints", "exclude_hints", "mapping" }`. A MIDI device gets the profile whose
`device_hints` its name contains (ignoring case; the longest hint wins), unless its name contains one of the profile's
`exclude_hints`. The LC6000 PRIME shows up as two ports, "…LC6000 PRIME Controller", which sends every control, and
"…LC6000 PRIME WD", which sends nothing, so its profile excludes `LC6000 PRIME WD` (#99). The LEDs go to the
destination with the same name as the connected source; a controller's layers share it (#143), and the fallback by
name hint never picks an excluded port.

## The default mapping

The `mapping` body of `Sources/ControllerBridgeCore/Resources/Profiles/denon-lc6000-prime.json`, the LC6000 controller
profile, is ported value for value from the Python bridge's
`lc6000_bridge/default_mapping.toml` (removed in #30; see the git history), with the same section and key names. A user mapping file merges over it the same
way the Python config merge does: objects merge key by key, and anything else replaces the default whole.

One value deliberately differs from Python: `osc.feedback_host` is `127.0.0.1`, not `0.0.0.0`. The feedback port takes
untrusted UDP, and the app's network server entitlement would otherwise expose it to the whole LAN. When Syndicate runs
on another Mac, Settings (#19) switches the feedback listen address from "this Mac only" to "all networks", which brings
up macOS's local-network prompt.

Two keys are new, with no Python counterpart: `leds.beat_pulse` (`"off"`, `"beat"` or `"downbeat"`, default `"off"`)
pulses the platter ring on Syndicate's master clock, and `leds.pulse_ms` (default 100) is how long each pulse stays lit.
The ring shows its deck's badge color (`DeckColors`, #122) while `leds.ring_follows_deck` is true, as in the bundled
profile. Set it to false to use the fixed `leds.ring_color` instead. A file without the key inherits the bundled true.

Feedback liveness (#21) adds three more: `osc.feedback_quiet_ms` (default 10000) is how long the bridge waits with no
feedback before asking Syndicate to resend, `osc.feedback_answer_ms` (default 2000) is how long that request may go
unanswered before feedback counts as stopped, and `leds.stale_idle` (`"dim"` or `"off"`, default `"dim"`) is what
Syndicate's LEDs show then.

JSON has no comments, so the notes on the LC6000 profile live here.

Checked on hardware (2026-11-15, see #12 and #103):

- `jog`: the platter sends its 14-bit position on CC 17 (MSB) and CC 49 (LSB), counting up going forward and wrapping
  at 16384. Movement is the change in position, read when the LSB arrives. One slow full turn measured about 3552
  counts, so `counts_per_rev` is 3600.
  - The platter also sends a 14-bit two's-complement speed on CC 55 (MSB) and CC 54 (LSB): forward 0/2…0/8, back
    127/120…127/127 (−8…−1). It isn't used yet: the position change is enough.
- `needle`: the Needle Drop strip is 14-bit on CC 64 (MSB) and CC 65 (LSB), with touch on note 70.
- `jog`, `pitch`, `needle` and `browse` may each be left out (#341) by a controller that hasn't got that control, such
  as the DDJ-400, which has no needle strip. Nothing then listens for it, and the demo skips it.
- `midi.ignore_notes`: the unit sends note 52 about every 0.3 s while idle, a heartbeat. It's dropped, and the
  Diagnostics monitor says so.
- `pitch`: 14-bit on CC 8/40, with the fader's top at 0, so `invert` stays false.
- `pitch.bits` (#195): 14 on the LC6000. A controller with a 7-bit pitch fader sets 7: the fader is then `msb_cc`
  alone and `lsb_cc` may be left out. 64 is the exact center (below it a step is 1/64, above it 1/63), so a centered
  fader reads 0; `invert`, `dead_zone` and pickup work as on 14-bit.
- `midi.encoder_format` (#193): the browse knob (CC 6) and the Auto Loop knob (CC 3) send two's complement:
  0x01–0x3F turn forward, 0x7F is one tick back. Another controller's profile can say `"offset_64"` (0x40 is still,
  0x41 one forward) or `"sign_magnitude"` (bit 6 is back, the low six bits how far). Left out, it's
  `"twos_complement"`.
- `jog.relative_cc` (#204): for a platter that sends relative ticks on one CC (most Pioneer DDJ jogs), not the LC6000's
  14-bit position. The ticks decode by `midi.encoder_format`, `jog.counts_per_rev` counts ticks per turn, and
  `jog.msb_cc`/`jog.lsb_cc` may be left out. `jog.relative_edge_cc` is the platter's edge on its own CC: it nudges
  without a touch, even with `require_touch`. Left out, the jog is the LC6000's absolute pair.
- `leds`: the button LED notes and the `0b00RRGGBB` color table are confirmed.
- `notes.pads` and `pads.roll_sizes` (#196): a controller has 1–16 pads (the LC6000 has 8, notes 32–39). Pad N is
  hot cue N, and in Roll mode plays `roll_sizes[N-1]`, by Syndicate's SlipLoop names (`ThirtySecond`, `Sixteenth`,
  `Eighth`, `Quarter`, `Half`, `One`, `Two`, `Four`); a pad past the list does nothing in Roll mode. Left out,
  `roll_sizes` is the LC6000's eight, shortest first. Syndicate sends 8 cue slots, so pads 9–16 stay dark.
- `notes.shifted` (#226): Shift done in hardware. On controllers that send a different note for a button while Shift is
  held (the DDJ-400, the MCX8000), each button's shifted note, such as `{ "beat_jump_back": 60 }`. That note acts as the
  button pressed with Shift held, for that press only, so Shift + Beat Jump Back still jumps a bar. Keys are the
  profile's button names, and each note is checked like any other (0–127, not another button's). Left out or empty
  (the LC6000), the app works Shift out from the Shift button, and nothing extra is saved.
- `notes.deck_select` (#420): `23` on the LC6000, its Slip button; Syndicate's slip mode is turned on and off in Syndicate itself. On a controller
  that follows its layers, a plain press moves to the next layer, 1 → 2 → 3 → 4 → 1, as Shift + deck select does on
  the unit itself, and sends no OSC. The unit's own layer doesn't move, so its next Shift + deck select steps from
  where the unit was, and DeckBridge follows that. With Follow controller layers off, it does nothing. `notes.slip`
  (optional) toggles Syndicate's `CueSlip` on a controller that maps it.
- `leds.mirror_shifted` (#226): `false` on the LC6000. On a controller whose shifted note has its own LED, `true`
  lights it with its button's state.
- `pads.mode_select` (#198): `buttons` on the LC6000, whose four buttons (`mode_hotcue`, `mode_roll`, `mode_loop`,
  `mode_slicer`) each pick a pad mode. A controller with one pad-mode button sets `cycle` and maps that button as
  `notes.mode_cycle`: each press moves Hot Cue → Roll → Loop → Slicer → Hot Cue, releasing a held pad first. Any
  `mode_*` notes it maps still light as indicators. Optional `pads.mode_cycle_velocities` (`hotcue`, `roll`, `loop`,
  `slicer`, each 0–127) lights the cycle button's own LED per mode; left out, DeckBridge leaves that LED alone.
- `pads.channel` and `midi.layers[].pad_channel` (#224): the MIDI channel (1–16) a deck's pads use when it isn't the
  deck's own, such as a Pioneer DDJ-400/FLX4 profile's 8 for deck 1 and 10 for deck 2. Pads then play only on that
  channel (the same note on the deck's channel isn't a pad), and their LEDs, and the LED sweep's color pass, go out on
  it. Left out (the LC6000, so the bundled profile doesn't name it), pads share the deck's channel.
- `pads.mode_notes` (#225): on a controller whose pads send a different note range in each pad mode (Pioneer's do),
  each mode's notes, one per pad: `hotcue`, `roll`, `loop` and `slicer`, all four, each as long as `notes.pads`. The
  note then says the mode: a roll note plays a roll, and a note from another mode switches to it first, letting a held
  pad go. The pad LEDs light the current mode's notes; the other modes' go dark. The `mode_*` buttons still pick the
  mode. Left out (the LC6000), `notes.pads` serves every mode and DeckBridge tracks the mode itself. The LED sweep's
  color pass covers `notes.pads` only.
- `leds.levels` (#194): a button LED's velocity at full, dim and off, 127, 1 and 0 on the LC6000. Another controller's
  profile can set any of them (each 0–127; one left out keeps the LC6000's). They drive the button and pitch-center
  LEDs, turning the LEDs off, and the LED sweep's button pass; pad and ring colors don't use them.
- `leds.color_table` (#197): how a pad or ring color becomes a velocity. `"rgb222"` (the LC6000, and the default) packs
  2 bits per channel. Another controller lists its own: `[{ "rgb": [255, 0, 0], "value": 5 }, …]`, and a color takes
  the nearest entry's value (the first of equally near ones). Black is off; a dim color never rounds to a black entry
  but takes the nearest lit one. Each `rgb` is three values 0–255, each `value` 0–127.
- `leds.color_message` (#530): the LEDs that take Denon's color message, `F0 00 02 0B 7F 10 03 00 04 <note> <r> <g>
  <b> F7`, exact RGB at 7 bits a channel, in place of a table velocity. `notes` lists them; each must be `leds.ring` or
  a pad. The LC6000's stock top panel firmware takes it for its pads and ring (32-40). Left out, a controller has none
  and every color goes through `leds.color_table`.

Still PROVISIONAL:

- `midi.channel`: the spec only documents channel 1.
- `jog.seek_seconds_per_rev` (2.0) and `jog.beats_per_rev` (4): how far a turn seeks or skips while paused. Tune them by
  feel.
- The mixer's Cue button (`/Syndicate/Mixer/CH{n}/Cue`): the other mixer inputs were confirmed on Syndicate (#207), but
  Cue did nothing in that spike. Check it with a headphone output set up.

## Mapping keys

Every key a mapping takes, from the key table in `Sources/ControllerBridgeCore/ProfileKeys.swift` (#382), which the
check and the decoder both read. A list item is written `[]`. "Optional" keys are ones the LC6000's mapping leaves
out; "left out" is what the decoder uses when a mapping leaves the key out. `ProfileKeysReadmeTests` keeps this list
equal to the table.

- `midi`: an object
- `midi.input`: text; LC6000 `"LC6000"`
- `midi.output`: text; LC6000 `"LC6000"`
- `midi.channel`: a whole number; 1–16; LC6000 `1`
- `midi.ignore_notes`: a list; LC6000 `[52]`; left out: `[]`
- `midi.ignore_notes[]`: a whole number; 0–127; LC6000 `52`
- `midi.layers`: a list; left out: `[]`
- `midi.layers[]`: an object
- `midi.layers[].channel`: a whole number; 1–16; LC6000 `1`
- `midi.layers[].deck`: a whole number; 1–4; LC6000 `1`
- `midi.layer_note`: a whole number; 0–127; LC6000 `51`
- `midi.encoder_format`: text; one of `twos_complement`, `offset_64`, `sign_magnitude`; LC6000 `"twos_complement"`
- `osc`: an object
- `osc.host`: text; LC6000 `"127.0.0.1"`
- `osc.port`: a whole number; 1–65535; LC6000 `9090`
- `osc.root`: text; LC6000 `"/Syndicate/"`
- `osc.feedback_host`: text; LC6000 `"127.0.0.1"`
- `osc.feedback_port`: a whole number; 1–65535; LC6000 `9096`
- `osc.feedback_quiet_ms`: a whole number; 0–60000; LC6000 `10000`
- `osc.feedback_answer_ms`: a whole number; 0–60000; LC6000 `2000`
- `deck`: an object
- `deck.number`: a whole number; 1–4; LC6000 `1`
- `jog`: an object
- `jog.msb_cc`: a whole number; 0–127; LC6000 `17`
- `jog.lsb_cc`: a whole number; 0–127; LC6000 `49`
- `jog.counts_per_rev`: a whole number; 1–16384; LC6000 `3600`
- `jog.bend_release_ms`: a whole number; 1–5000; LC6000 `80`
- `jog.seek_seconds_per_rev`: a number; 0–60; LC6000 `2`
- `jog.beats_per_rev`: a whole number; 1–16; LC6000 `4`
- `jog.require_touch`: true or false; LC6000 `false`
- `pitch`: an object
- `pitch.bits`: a whole number; one of 7, 14; LC6000 `14`
- `pitch.msb_cc`: a whole number; 0–127; LC6000 `8`
- `pitch.lsb_cc`: a whole number; 0–127; LC6000 `40`
- `pitch.invert`: true or false; LC6000 `false`
- `pitch.dead_zone`: a number; 0–1; LC6000 `0.005`
- `pitch.pickup`: true or false; LC6000 `true`
- `pitch.pickup_tolerance`: a number; 0–1; LC6000 `0.02`
- `needle`: an object
- `needle.msb_cc`: a whole number; 0–127; LC6000 `64`
- `needle.lsb_cc`: a whole number; 0–127; LC6000 `65`
- `needle.touch_note`: a whole number; 0–127; LC6000 `70`
- `needle.require_touch`: true or false; LC6000 `true`
- `needle.shift_fader`: true or false; LC6000 `true`. The strip's channel fader (#609). Despite the name, since #729
  it's the plain touch, and Shift + the strip seeks; false, the strip seeks with or without Shift. The name is kept so
  existing profiles still load
- `needle.shift_fader_mode`: text; one of `relative`, `jump`; LC6000 `"relative"`. How that fader moves: from its level
  by the finger's travel, or to the finger
- `browse`: an object
- `browse.select_turn_cc`: a whole number; 0–127; LC6000 `6`
- `browse.auto_loop_size_cc`: a whole number; 0–127; LC6000 `3`
- `notes`: an object
- `notes.play`: a whole number; 0–127; LC6000 `1`
- `notes.cue`: a whole number; 0–127; LC6000 `2`
- `notes.beat_jump_back`: a whole number; 0–127; LC6000 `3`
- `notes.beat_jump_forward`: a whole number; 0–127; LC6000 `4`
- `notes.track_prev`: a whole number; 0–127; LC6000 `5`
- `notes.track_next`: a whole number; 0–127; LC6000 `6`
- `notes.censor`: a whole number; 0–127; LC6000 `7`
- `notes.loop_in`: a whole number; 0–127; LC6000 `8`
- `notes.loop_out`: a whole number; 0–127; LC6000 `9`
- `notes.auto_loop`: a whole number; 0–127; LC6000 `10`
- `notes.back`: a whole number; 0–127; LC6000 `16`
- `notes.forward`: a whole number; 0–127; LC6000 `17`
- `notes.select_press`: a whole number; 0–127; LC6000 `18`
- `notes.vinyl`: a whole number; 0–127; LC6000 `19`
- `notes.sync`: a whole number; 0–127; LC6000 `20`
- `notes.master`: a whole number; 0–127; LC6000 `21`
- `notes.key_lock`: a whole number; 0–127; LC6000 `22`
- `notes.deck_select`: a whole number; 0–127; LC6000 `23`
- `notes.pitch_minus`: a whole number; 0–127; LC6000 `24`
- `notes.pitch_plus`: a whole number; 0–127; LC6000 `25`
- `notes.shift`: a whole number; 0–127; LC6000 `26`
- `notes.mode_hotcue`: a whole number; 0–127; LC6000 `27`
- `notes.mode_roll`: a whole number; 0–127; LC6000 `28`
- `notes.mode_slicer`: a whole number; 0–127; LC6000 `29`
- `notes.mode_loop`: a whole number; 0–127; LC6000 `30`
- `notes.pads`: a list; 1–16 items; LC6000 `[32, 33, 34, 35, 36, 37, 38, 39]`
- `notes.pads[]`: a whole number; 0–127; LC6000 `32`
- `notes.platter_touch`: a whole number; 0–127; LC6000 `40`
- `notes.param_back`: a whole number; 0–127; LC6000 `68`
- `notes.param_forward`: a whole number; 0–127; LC6000 `69`
- `leds`: an object
- `leds.pitch_center`: a whole number; 0–127; LC6000 `42`
- `leds.pitch_arrow_back`: a whole number; 0–127; LC6000 `41`. Lit during pitch pickup when the fader must move toward a lower value (#475); optional
- `leds.pitch_arrow_forward`: a whole number; 0–127; LC6000 `43`. Lit during pitch pickup when the fader must move toward a higher value; optional
- `leds.ring`: a whole number; 0–127; LC6000 `40`
- `leds.ring_color`: a list; exactly 3; LC6000 `[0, 128, 255]`
- `leds.ring_color[]`: a whole number; 0–255; LC6000 `0`
- `leds.ring_follows_deck`: true or false; LC6000 `true`
- `leds.roll_pad_color`: a list; exactly 3; LC6000 `[255, 140, 0]`
- `leds.roll_pad_color[]`: a whole number; 0–255; LC6000 `255`
- `leds.loop_pad_color`: a list; exactly 3; LC6000 `[0, 255, 0]`
- `leds.loop_pad_color[]`: a whole number; 0–255; LC6000 `0`
- `leds.dim_unlit_buttons`: true or false; LC6000 `true`
- `leds.mirror_shifted`: true or false; LC6000 `false`
- `leds.beat_pulse`: text; one of `off`, `beat`, `downbeat`; LC6000 `"off"`
- `leds.pulse_ms`: a whole number; 0–60000; LC6000 `100`
- `leds.stale_idle`: text; one of `dim`, `off`; LC6000 `"dim"`
- `leds.levels`: an object
- `leds.levels.full`: a whole number; 0–127; LC6000 `127`
- `leds.levels.dim`: a whole number; 0–127; LC6000 `1`
- `leds.levels.off`: a whole number; 0–127; LC6000 `0`
- `leds.color_table`: text `"rgb222"` (the LC6000's), or a list of at least 1 entry (`leds.color_table[]` below)
- `leds.color_message`: an object
- `leds.color_message.notes`: a list; at least 1
- `leds.color_message.notes[]`: a whole number; 0–127; LC6000 `32`
- `pads`: an object
- `pads.roll_sizes`: a list
- `pads.roll_sizes[]`: text; one of `ThirtySecond`, `Sixteenth`, `Eighth`, `Quarter`, `Half`, `One`, `Two`, `Four`; LC6000 `"ThirtySecond"`
- `pads.mode_select`: text; one of `buttons`, `cycle`; LC6000 `"buttons"`
- `leds.color_table[]`: an object; optional
- `leds.color_table[].rgb`: a list; exactly 3; optional
- `leds.color_table[].rgb[]`: a whole number; 0–255; optional
- `leds.color_table[].value`: a whole number; 0–127; optional
- `jog.relative_cc`: a whole number; 0–127; optional
- `jog.relative_edge_cc`: a whole number; 0–127; optional
- `notes.slip`: a whole number; 0–127; optional
- `notes.mode_cycle`: a whole number; 0–127; optional
- `pads.mode_cycle_velocities`: an object; optional
- `pads.mode_cycle_velocities.hotcue`: a whole number; 0–127; optional
- `pads.mode_cycle_velocities.roll`: a whole number; 0–127; optional
- `pads.mode_cycle_velocities.loop`: a whole number; 0–127; optional
- `pads.mode_cycle_velocities.slicer`: a whole number; 0–127; optional
- `pads.channel`: a whole number; 1–16; optional
- `midi.layers[].pad_channel`: a whole number; 1–16; optional
- `pads.shifted_channel`: a whole number; 1–16; optional
- `midi.layers[].shifted_pad_channel`: a whole number; 1–16; optional
- `pads.mode_notes`: an object; optional
- `pads.mode_notes.hotcue`: a list; optional
- `pads.mode_notes.hotcue[]`: a whole number; 0–127; optional
- `pads.mode_notes.roll`: a list; optional
- `pads.mode_notes.roll[]`: a whole number; 0–127; optional
- `pads.mode_notes.loop`: a list; optional
- `pads.mode_notes.loop[]`: a whole number; 0–127; optional
- `pads.mode_notes.slicer`: a list; optional
- `pads.mode_notes.slicer[]`: a whole number; 0–127; optional
- `notes.shifted`: an object; optional; left out: `{}`
- `notes.shifted.play`: a whole number; 0–127; optional
- `notes.shifted.cue`: a whole number; 0–127; optional
- `notes.shifted.beat_jump_back`: a whole number; 0–127; optional
- `notes.shifted.beat_jump_forward`: a whole number; 0–127; optional
- `notes.shifted.track_prev`: a whole number; 0–127; optional
- `notes.shifted.track_next`: a whole number; 0–127; optional
- `notes.shifted.censor`: a whole number; 0–127; optional
- `notes.shifted.loop_in`: a whole number; 0–127; optional
- `notes.shifted.loop_out`: a whole number; 0–127; optional
- `notes.shifted.auto_loop`: a whole number; 0–127; optional
- `notes.shifted.back`: a whole number; 0–127; optional
- `notes.shifted.forward`: a whole number; 0–127; optional
- `notes.shifted.select_press`: a whole number; 0–127; optional
- `notes.shifted.vinyl`: a whole number; 0–127; optional
- `notes.shifted.sync`: a whole number; 0–127; optional
- `notes.shifted.master`: a whole number; 0–127; optional
- `notes.shifted.key_lock`: a whole number; 0–127; optional
- `notes.shifted.deck_select`: a whole number; 0–127; optional
- `notes.shifted.pitch_minus`: a whole number; 0–127; optional
- `notes.shifted.pitch_plus`: a whole number; 0–127; optional
- `notes.shifted.shift`: a whole number; 0–127; optional
- `notes.shifted.mode_hotcue`: a whole number; 0–127; optional
- `notes.shifted.mode_roll`: a whole number; 0–127; optional
- `notes.shifted.mode_slicer`: a whole number; 0–127; optional
- `notes.shifted.mode_loop`: a whole number; 0–127; optional
- `notes.shifted.slip`: a whole number; 0–127; optional
- `notes.shifted.platter_touch`: a whole number; 0–127; optional
- `notes.shifted.param_back`: a whole number; 0–127; optional
- `notes.shifted.param_forward`: a whole number; 0–127; optional
- `mixer`: an object; optional
- `mixer.volume`: an object; optional
- `mixer.volume.msb_cc`: a whole number; 0–127; optional
- `mixer.volume.lsb_cc`: a whole number; 0–127; optional
- `mixer.volume.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.trim`: an object; optional
- `mixer.trim.msb_cc`: a whole number; 0–127; optional
- `mixer.trim.lsb_cc`: a whole number; 0–127; optional
- `mixer.trim.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.eq_high`: an object; optional
- `mixer.eq_high.msb_cc`: a whole number; 0–127; optional
- `mixer.eq_high.lsb_cc`: a whole number; 0–127; optional
- `mixer.eq_high.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.eq_mid`: an object; optional
- `mixer.eq_mid.msb_cc`: a whole number; 0–127; optional
- `mixer.eq_mid.lsb_cc`: a whole number; 0–127; optional
- `mixer.eq_mid.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.eq_low`: an object; optional
- `mixer.eq_low.msb_cc`: a whole number; 0–127; optional
- `mixer.eq_low.lsb_cc`: a whole number; 0–127; optional
- `mixer.eq_low.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.filter`: an object; optional
- `mixer.filter.msb_cc`: a whole number; 0–127; optional
- `mixer.filter.lsb_cc`: a whole number; 0–127; optional
- `mixer.filter.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.filter_res`: an object; optional
- `mixer.filter_res.msb_cc`: a whole number; 0–127; optional
- `mixer.filter_res.lsb_cc`: a whole number; 0–127; optional
- `mixer.filter_res.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.filter_width`: an object; optional
- `mixer.filter_width.msb_cc`: a whole number; 0–127; optional
- `mixer.filter_width.lsb_cc`: a whole number; 0–127; optional
- `mixer.filter_width.bits`: a whole number; one of 7, 14; optional; left out: `14`
- `mixer.cue_note`: a whole number; 0–127; optional
- `mixer.mute_note`: a whole number; 0–127; optional
- `mixer.solo_note`: a whole number; 0–127; optional
- `mixer.meter`: an object; optional
- `mixer.meter.cc`: a whole number; 0–127; optional
- `mixer.meter.steps`: a list; at least 1; optional
- `mixer.meter.steps[]`: a whole number; 0–127; optional
- `mixer.meter.clip`: a whole number; 0–127; optional
- `mixer.meter.hold_ms`: a whole number; 0–10000; optional; left out: `300`
- `mixer.meter.rate_hz`: a whole number; 1–120; optional; left out: `30`
- `mixer.pickup`: true or false; optional; left out: `true`
- `mixer.pickup_tolerance`: a number; 0–1; optional; left out: `0.02`
