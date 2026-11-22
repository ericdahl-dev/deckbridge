# Changelog

## 1.1.0

The LC6000's jog display shows the deck (#165).

- The round screen in the jog wheel shows the deck in front: its number in the deck's color, the track's title and
  artist, and key · BPM. Long titles wrap; an empty deck says "No track". It's on by default for new settings; a saved
  choice is kept. Switch it in Settings › Controller › "Show the deck on the jog display".
- The ring's lit segment, in green, steps with Syndicate's master beat, drawn on the unit itself (#215). The needle turns
  once per bar with that deck's own phase, so you can see at a glance whether the decks are in sync. Turning the platter
  doesn't move it; a seek on a paused deck does, once Syndicate reports it (#388).
- It follows the controller's deck layers, and gives the screen back to the LC6000 when switched off, unplugged or quit.
  Every deck's screen stays loaded on the LC6000, so a deck switch shows at once; a new track's screen replaces the
  old one as it lands, never black.
- Diagnostics › Jog display previews every deck's screen live, even without an LC6000 connected (#221).
- Settings › Controller › Key display (with the jog display on) writes keys as Syndicate does, traditional or Camelot
  (#590).
- Settings › Controller › Firmware (shown with the jog display on):
  leave it on Denon unless your unit runs custom firmware (#456).

Controller:

- Shift + Pitch Bend − / + transposes the deck down or up a semitone, turning its key lock on first, as Syndicate needs
  (#377). Without Shift, Pitch Bend still nudges the tempo.
- Main CUE: pressing PLAY while CUE is held keeps the deck playing, and Shift + CUE goes back to the cue point and stops
  (#360).
- Shift + a hot cue pad jumps to that cue at once, whatever the quantize setting, without starting a stopped deck (#361,
  #364).
- The jog and the Needle Drop strip seek a paused deck exactly where you put them, with quantize off while seeking
  (#375).
- The Needle Drop strip moves the deck's channel fader in Syndicate, from where it is (Relative) or straight to where you
  touch (Jump), and Shift + the strip seeks (#609, #729). Settings › Controller switches the fader (on by default) and
  picks the mode; switched off, the strip seeks with or without Shift. Relative needs Syndicate's Volume feedback, which
  the panel's subscription list names.
- Shift + the Auto Loop knob moves the loop (#470). A plain press of Slip steps the deck layer 1 → 2 → 3 → 4, as
  Shift + Slip does; Syndicate has no slip mode (#420).
- VINYL switches what the jog does on a playing deck: bend the tempo or seek (#540).
- Shift + Sync turns sync off (#478), and Shift + the browse knob zooms the waveform (#479).
- Pads past Syndicate's eight hot cues send nothing and stay dark (#311).
- Missing Syndicate subscriptions are a list, each with what it breaks. BarRamp joins it while the jog display is on
  (#261, #258). Demo mode no longer warns about subscriptions (#246).

The LC6000's lights:

- The platter ring and pads light in the deck's and cues' exact colors, with no firmware change (Settings › Decks ›
  Exact colors on the LC6000, on by default); Light brightness sets how bright (#530, #531, #532). The ring's beat
  pulse is smooth (#533).
- During pitch pickup the pitch arrows show which way to move the fader (#475). The dark buttons are lit: dim when
  idle, full while held (#476). Censor shows reverse, and the deck select button flashes (#477).
- A deck layer change sends only the lights that differ, so quick layer steps keep up (#554).

Other displays:

- Display feed: DeckBridge can send the deck in front to a display on your local network, unencrypted to the one
  address you set (Settings › Syndicate › Display feed, off by default) (#616, #617). Settings checks the host and port
  and says when it's sending, or why not, including when macOS blocks local network access (#618). It follows the demo
  controller too (#625).

Reliability:

- A controller or jog display port that stops taking MIDI no longer freezes DeckBridge; its sends are dropped until it
  answers again (#552). The jog display no longer stalls the app for seconds after a deck switch mid-upload (#422).
- A quick LC6000 power cycle is noticed: the LEDs repaint and the jog display comes back without a restart (#429). The
  LEDs light at launch (#426).
- Syndicate's host can be a name, such as studio-mac.local, looked up off the main thread (#84), and a failed OSC
  sender is rebuilt on Apply (#109).

In the lab, not in this release's reach:

- A 7-inch Wi-Fi deck panel beside the controller shows the deck in front from the display feed. It's a project on our
  desk, with no kit or firmware to download.
- On a reflashed display chip, the jog display draws the deck itself. That firmware isn't part of the DeckBridge app
  and isn't offered for download, and DeckBridge never includes or distributes Denon's firmware. With it, the app
  recovers the drawn display after a power cycle (#604).

Groundwork, inactive for the LC6000:

- Mixer support (faders, EQ, filter, cue/mute/solo and VU meters) works once a controller profile has a mixer (#207).
- Profiles may leave out the needle strip, jog, pitch fader or browse knob, and gain Shift done in hardware, Shift pads
  on their own channels and an LED color table (#341, #342, #226, #197).
- Captures gain deck layers, the Shift offset, unplug handling, and an LED test that stays off until it's checked on
  hardware (#217, #229, #187). Draft profiles can come from a controller's MIDI docs alone, as for the Pioneer DDJ-400
  and DDJ-FLX4 (#280).

## 1.0.2

- The panel and Diagnostics name **every** Syndicate subscription that's off and what it breaks, e.g. "TempoSlider/TempoSliderEnabled is off: the pitch fader can jump" (#211).
- Diagnostics log: filter, hide streaming values, deck and direction filters, 20,000-line history, pause, copy visible and save (#218).
- Help add a controller: a guided capture of any MIDI controller, then save it or email it to us. Nothing is sent unless you choose to (#186, #188).
- Groundwork for more controllers in profiles: encoder formats, relative jogs, LED levels, 7-bit faders, 1–16 pads and pad channels (#193–#196, #204, #224, #225). The LC6000 behaves as before.

## 1.0.1

A new look that matches getdeckbridge.app (#171).

- Geist and Geist Mono type, pill buttons, cards, and status words in normal case.
- The panel, Diagnostics and the setup guide are redesigned. The panel is a little taller.
- Settings is in four tabs: Controller, Decks, Syndicate, General, with ⌘1–4. A refused Apply opens the tab and the field
  that needs fixing, and VoiceOver says why.
- A tall Settings tab scrolls, with Apply pinned at the bottom.
- Status chips and segments meet AA contrast in light and dark, and at increased contrast.
- Fix: a MIDI device named "Controller" no longer counts as the controller light.

## 1.0

The first release: a Mac menu-bar app that plays Untitled Audio Syndicate from a Denon LC6000 PRIME over OSC, with
LED feedback. It replaces the Python `lc6000-bridge` command-line tool.

### Controller

- Transport, loops, beat jumps, Key Lock, Slip, Censor (hold, or latched with Shift), Pitch Bend and the browser.
- Pads in Hot Cue, Roll and Loop modes.
- The 14-bit jog wheel bends the phase while playing and seeks while paused; the Needle Drop strip seeks.
- The 14-bit pitch fader at full resolution, with pickup so the tempo never jumps; Shift + Key Lock resets it.
- Four decks from one unit: the bridge follows the LC6000's deck layers.

### LEDs

- Play, Cue, Sync, Master and the loop LEDs follow Syndicate. Play blinks while a quantized start is pending.
- Pads show hot cues in Syndicate's cue colors; a held pad lights brighter.
- The platter ring shows the active deck's color, following Syndicate's cue palette or your own colors.
- Optional beat pulse on the ring, and a choice of dim or off for Syndicate's LEDs while feedback is stale.

### App

- A panel with status lights (CONTROLLER, FEEDBACK, TEMPO) and plain-words help when the LEDs are dark.
- A warning when Syndicate's OSC feedback subscriptions are off (FEEDBACK ● NO DECK DATA), or when one an LED needs is
  missing.
- Settings: deck, MIDI devices, channel, layers, a second controller, LEDs, OSC host and ports, feedback listening,
  deck colors, appearance (Match macOS, Dark or Light), mapping import and export, and start at login.
- Diagnostics: MIDI Monitor, LED Sweep and OSC Log.
- A setup guide for Syndicate, and a demo controller that runs without hardware.
- Recovery: unplug, replug, sleep, a restarted Syndicate and quitting all release held controls and repaint the LEDs.
- Syndicate's look, in its own dark and light theme tokens, with every text color at WCAG AA.

### Not possible yet

- Scratching (Syndicate has no scratch or scrub OSC route), the platter's center display (undocumented SysEx) and
  Slicer mode (unmapped).
