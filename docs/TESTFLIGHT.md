# TestFlight: What to test

The release workflow puts everything after the rule below into each build's "What to Test" (en-US), so keep it current
for the version being tagged (#180). App Store Connect allows 4,000 characters.

**Who gets the build (#244).** A tag goes to the **Internal** group only:

    git tag -a v1.0.3 -m "Jog display check"

To also send it to the external **Syndicate** group and submit it for Beta App Review, put `[external]` in the
annotated tag's message:

    git tag -a v1.0.3 -m "Release 1.0.3 [external]"

To send out a build that's already uploaded, run the Release workflow by hand with its version and build number and
**external** ticked. Run by hand, a build keeps the What to Test it was uploaded with; tick **replace_what_to_test** to
give it this branch's text instead (#312). A lightweight tag, or a message without the marker, is always internal only.

---

DeckBridge 1.1.0 shows the deck on the LC6000's jog display, lights the unit in exact colors and adds controller moves. Please try:

- The jog display: it's on by default (Settings › Controller › "Show the deck on the jog display"). The screen should
  show the deck in front, in its color, with the track's title, artist and key · BPM. Load a track, then a long title.
  Is it upright and easy to read, and does it appear quickly? Key display sets traditional or Camelot keys. Firmware:
  leave it on Denon unless your unit runs custom firmware.
- The ring and needle: play a deck. The lit green segment should step with the master beat, and the needle should go
  round once per bar, in time. Pause and seek with the jog: the needle moves to the new spot.
- Deck layers: switch decks with Shift + Slip, or plain Slip. The screen should change at once, never black.
- Off and back: turn the switch off (the unit's own screen comes back), then on. Unplug and replug, and power cycle the
  unit with DeckBridge running: lights and screen come back. Quit DeckBridge: the unit goes back to its own screen.
- Without the unit: open Diagnostics › Jog display. It previews every deck's screen live, even with no LC6000.
- Colors: with Settings › Decks › Exact colors on the LC6000 (on by default), the ring and pads match the deck and cue
  colors. Try Light brightness.
- The Needle Drop strip moves the deck's channel fader in Syndicate (Relative or Jump, Settings › Controller); Shift +
  the strip seeks. Relative needs Syndicate's Volume feedback on.
- Top panel: the pitch arrows during pickup, Shift + Sync (sync off), Shift + browse (zoom), Shift + Auto Loop (move the
  loop), VINYL (bend or seek while playing).
- Transpose: Shift + Pitch Bend − / + moves the key a semitone (Key Lock turns on).
- CUE: hold CUE, press PLAY: the deck keeps playing. Shift + CUE goes back to the cue point and stops.
- Hot cues: Shift + a pad jumps straight to that cue, and a stopped deck stays stopped.
- Subscriptions: if Syndicate's OSC Feedback subscriptions aren't all on, the panel lists each missing one and what it
  breaks.
- Display feed (Settings › Syndicate, off by default): if you have an OSC monitor on your network, point it there. It
  sends the deck in front, unencrypted, to the one address you set, and Settings says whether it's sending.
- Help add a controller: in Settings › Controller, choose "Controller not found?" from the Controller menu (or try it
  with the demo controller). Walk a few steps, then end the capture and save the file.
- Your set as usual: transport, hot cues, jog, the pitch fader and the LEDs on all four deck layers.

Tell us what you see on the display, and anything that looks wrong or behaves differently from 1.0.2.
