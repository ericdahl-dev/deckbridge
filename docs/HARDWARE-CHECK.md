# Hardware check before a release

About 15 minutes on a real Denon LC6000 PRIME and Syndicate, run on the build you're about to ship. Each line is one
check: do the action, then confirm the expected result. If any line fails, file an issue and don't ship.

## Before you start

- Quit djay Pro, Engine DJ and any other DJ app, then power-cycle the LC6000.
- Syndicate is set up as in the README's [Set up Syndicate](../README.md#set-up-syndicate), with every subscription on.
- Load tracks with hot cues on decks 1 and 2. Leave decks 3 and 4 empty for now.
- The Mac is plugged in. You'll put it to sleep once.

## 1. Connect and feedback

| # | Do | Expect |
|---|---|---|
| 1.1 | Launch the app with the LC6000 plugged in | Panel: CONTROLLER ● CONNECTED, FEEDBACK ● LIVE. The LEDs light up |
| 1.2 | Open the panel | Deck shows "Following controller layers"; badge 1 is selected |

## 2. Transport (layer 1, deck 1)

| # | Do | Expect |
|---|---|---|
| 2.1 | Press Play | Deck 1 plays; Play LED lit |
| 2.2 | Press Play with quantize on in Syndicate | Play LED blinks until the start lands, then stays lit |
| 2.3 | Pause, then hold Cue | Deck 1 previews from the cue point while held, and returns on release; Cue LED follows Syndicate |
| 2.4 | Press Sync, then Master | Sync and Master LEDs follow Syndicate; the panel shows TEMPO ● MASTER when deck 1 leads |
| 2.5 | Loop In, Loop Out, then Auto Loop; turn the Auto Loop knob | A loop is set and toggled; the knob halves or doubles it; loop LEDs follow |
| 2.6 | Beat Jump ◀ and ▶ | Jumps one beat each way |
| 2.7 | Param ◀ and ▶ | Skips one beat each way |
| 2.8 | Hold Pitch Bend − then + | Tempo nudges while held and returns on release |
| 2.9 | Hold Censor | Plays in reverse while held, forward on release |
| 2.10 | Key Lock, then Slip | Syndicate's key lock and slip toggle; both LEDs show their state |
| 2.11 | Turn and press the Browse knob, then Back, Forward and Track ◀ ▶ | The browser moves, loads to deck 1 and goes back |

## 3. Shift functions

| # | Do | Expect |
|---|---|---|
| 3.1 | Hold Shift | Shift LED lit while held |
| 3.2 | Shift + Beat Jump ◀ ▶ | Jumps a bar each way |
| 3.3 | Shift + Censor, twice | First press latches reverse on, the second turns it off |
| 3.4 | Move the pitch fader off center, then Shift + Key Lock | Tempo resets to 0; the fader does nothing until it reaches the center |
| 3.5 | Shift + Browse press | Enter in Syndicate's browser |
| 3.6 | Shift + Pitch Bend − / + | Key lock turns on (its LED lights), and the deck's key goes down or up a semitone per press; the tempo doesn't change |

## 4. Pads

| # | Do | Expect |
|---|---|---|
| 4.1 | Hot Cue mode | Mode LED lit; pads show deck 1's hot cues in Syndicate's cue colors |
| 4.2 | Hold a hot cue pad | Plays from that cue while held; the pad lights brighter |
| 4.3 | Roll mode; hold each pad | Slip loop rolls from 1/32 up to 4 beats while held; the track resumes where it would have been |
| 4.4 | Loop mode; press a pad | Sets that cue loop |
| 4.5 | Slicer mode | Nothing happens (unmapped) |

## 5. Jog, pitch and needle drop

| # | Do | Expect |
|---|---|---|
| 5.1 | Turn the jog while deck 1 plays | Phase bends while turning, and stops about 80 ms after the wheel stops |
| 5.2 | Turn the jog while deck 1 is paused | Seeks through the track |
| 5.3 | Move the pitch fader slowly over its full range | Tempo follows smoothly, in fine steps; the top is slower |
| 5.4 | Touch and slide on the Needle Drop strip | Deck 1's channel fader in Syndicate follows the slide; the track doesn't move |
| 5.5 | Hold Shift, touch and slide on the Needle Drop strip | Seeks to that point while touched |

## 6. Layers 1-4

| # | Do | Expect |
|---|---|---|
| 6.1 | Shift + deck select to layer 2, press Play | Deck 2 plays; the panel shows deck 2; every LED repaints from deck 2 |
| 6.2 | Move the pitch fader on layer 2 | Deck 2's tempo doesn't jump: it waits until the fader meets deck 2's tempo (pickup) |
| 6.3 | Hold a pad on layer 2, then switch to layer 1 | The held pad is released on deck 2 |
| 6.4 | Step through layers 3 and 4 | Each drives its own deck; with no track loaded the ring stays off |
| 6.5 | Settings: turn Follow controller layers off, pick deck 3 | Every layer drives deck 3; turn it back on after |

## 7. LEDs, ring and colors

| # | Do | Expect |
|---|---|---|
| 7.1 | Layer 1, then layer 2, with tracks loaded | The platter ring shows each deck's color, the same as its badge in the panel |
| 7.2 | Settings › Decks: Use Syndicate's deck colors on; change cue palette slot 3 in Syndicate | Deck 2's badge and ring change to the new color right away |
| 7.3 | Turn Use Syndicate's deck colors off; pick a custom deck 1 color | The badge, the preview and the ring use your color |
| 7.4 | Vivid ring colors (once #156 is in the build): switch Vivid / Exact | Vivid looks saturated, with no washed-out white; Exact is the plain mapping; it repaints at once |
| 7.5 | Settings: turn Controller LEDs off, then on | All LEDs go dark, then repaint |
| 7.6 | Diagnostics › LED Sweep | Pads and ring step through the 64 colors, then each button lights in turn |

## 8. Subscriptions warning

| # | Do | Expect |
|---|---|---|
| 8.1 | In Syndicate, turn off every OSC FEEDBACK subscription, then quit and relaunch the app | FEEDBACK ● NO DECK DATA in orange; the help lists the subscriptions to turn on, with Setup guide |
| 8.2 | Turn them all back on | FEEDBACK ● LIVE within a few seconds; the LEDs come back |
| 8.3 | Turn off only Cues, with a track loaded; wait about 15 s | FEEDBACK stays LIVE; help says hot cue pad colors need the Cues subscription. Turn it back on |
| 8.4 | Eject every track (empty decks), wait about 15 s | Plain LIVE: no warning |

## 9. Unplug, sleep and quit

| # | Do | Expect |
|---|---|---|
| 9.1 | Hold a pad, then unplug the USB cable | The deck stops the held action; CONTROLLER ● UNPLUGGED |
| 9.2 | Plug it back in | CONNECTED; the LEDs repaint from Syndicate's state |
| 9.3 | Quit Syndicate, wait 15 s | FEEDBACK ● DROPPED; Syndicate's LEDs go idle; the panel shows the last dropout time |
| 9.4 | Relaunch Syndicate | FEEDBACK ● LIVE again; the LEDs catch up without touching anything |
| 9.5 | Hold Censor, then put the Mac to sleep and wake it | Reverse was released; the controller works again after wake |
| 9.6 | Quit from the panel while feedback is live | It asks first; Cancel keeps it running |
| 9.7 | Press ⌘Q with the panel open | Quits without asking |

## 10. Settings, Diagnostics and demo

| # | Do | Expect |
|---|---|---|
| 10.1 | Settings: type an empty host, click Apply | The problem is listed in plain words; nothing changes |
| 10.2 | Settings: Appearance Light, then Dark, then Match macOS | Every window follows; text stays readable |
| 10.3 | Settings › Mapping: Export, then Import the same file | It's accepted; the Mapping section names it; Reset to default goes back |
| 10.4 | Settings: Start at login on, log out and in | The app starts; turn it off after |
| 10.5 | Diagnostics › MIDI Monitor, move every control | Each message shows a mapping name, not UNMAPPED |
| 10.6 | Diagnostics › OSC Log | What goes to Syndicate and what comes back both show |
| 10.7 | Panel: Demo controller on | A scripted controller drives a simulated Syndicate; nothing goes to the network but the display feed, if it's on (the deck panel follows the demo); relaunch turns it off |
| 10.8 | Panel: Setup guide | The steps show the live status lights; the button reads "Done: feedback live" |
