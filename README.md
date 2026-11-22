# DeckBridge

A Mac menu-bar app that lets you use a **Denon LC6000 PRIME** with **[Syndicate](https://untitledaudiosyndicate.com)** by Untitled Audio Syndicate Ltd. through Syndicate's OSC API, with LED feedback.

Syndicate's own MIDI mapping (0.3.7) can't handle the LC6000's 14-bit jog wheel or its 14-bit pitch fader, and it gives LED feedback only to the DDJ-FLX4 and FLX10 ([Syndicate User Guide 0.3.7, section 13.9](https://untitledaudiosyndicate.com/user-guide/index.html#c13-9): 14-bit CC pairs and generic MIDI LED feedback are listed as not supported). The app reads the LC6000's MIDI, converts it, and sends it to Syndicate's fixed OSC addresses. It also listens to Syndicate's OSC feedback to light the controller.

```
LC6000 ──USB MIDI──▶  DeckBridge  ──OSC :9090──▶ Syndicate
LC6000 ◀──MIDI LEDs──  DeckBridge  ◀──OSC feedback :9096── Syndicate
```

## What it does

| LC6000 | Syndicate (`/Syndicate/Deck/{n}/…`) |
|---|---|
| Pitch fader (14-bit CC 8 + 40) | `TempoSlider` −1…+1 at full resolution, with pickup so the tempo never jumps |
| Jog while playing | `PhaseBend` ±1, released 80 ms after the wheel stops. With VINYL on, it seeks instead, as the paused jog does |
| VINYL | Toggles the playing jog between bending (off, the default) and seeking (on), per deck layer. Its light is full while seeking is on |
| Jog while paused | `WaveformSeek`, using the track length from feedback, with the deck's `Quantize` at None (1) while seeking so Syndicate doesn't snap it to the grid, then Use Global (0) 300 ms after the last move. Falls back to `BeatSkip` |
| Needle Drop strip, while touched | Moves the deck's channel fader in Syndicate (`Mixer/CHn/Volume`, n the deck), on by default (#609, #729). Relative moves it from where it is by how far the finger travels, and needs Syndicate's `Volume` feedback; Jump sends it straight to the finger. Settings › Controller switches it and picks the mode; switched off, the strip seeks with or without Shift |
| Shift + Needle Drop strip, while touched | `WaveformSeek` (needle drop). On a paused deck, the deck's `Quantize` is None while touched, then Use Global |
| Play / Cue / Sync / Master | `PlayPause` / `Cue` (hold) / `TempoSync` / `TempoMaster` |
| Pads in Hot Cue mode | `HotCue n 1/0` (press and hold) |
| Shift + pad in Hot Cue mode, deck stopped | Goes to that cue without playing, at once: `Quantize 1` (None), then a silent `WaveformSeek` to the cue, then `Quantize 0` (Use Global). The first press on each cue (per track) taps `Cue n` and pauses it on `Playing 1` instead, with a short blip, to learn where the cue is. Syndicate doesn't report a deck's own quantize, so a deck set to its own quantize is reset to Use Global. On a playing deck it's a hot cue |
| Pads in Roll mode | `SlipLoop/ThirtySecond … Four` (hold) |
| Pads in Loop mode | `SetCueLoop n` |
| Loop In / Loop Out / Auto Loop, and the Auto Loop knob | `LoopIn` / `LoopOut` / `Loop`. Turning the knob halves or doubles the loop; Shift + turn is Loop Move: each click moves the loop by its own length (`LoopMoveBeat`) |
| Beat Jump ◀ ▶ (Shift for a bar) | `SkipBeatBack` / `SkipBeatForward` (`SkipBar…` with Shift) |
| Censor (hold; Shift + Censor latches) | `Reverse` 1/0 while held; with Shift, each press turns `Reverse` on or off |
| Key Lock | `PitchPreserve` |
| Deck select (printed Slip) | Steps the bridge to the next deck layer (#420); nothing goes to Syndicate. Shift + deck select steps the unit's own layer, and the bridge follows. |
| Shift + Sync (OFF) | Turns sync off: `TempoSync` 1 only while the deck is synced (Syndicate's `Sync` feedback); nothing otherwise, so it never turns sync on |
| Shift + Key Lock (pitch reset) | `TempoSlider` 0.0, then the fader waits to meet 0.0. Nothing while the tempo slider is disabled (a synced follower) |
| Pitch Bend − / + (hold) | `PhaseMinus` / `PhasePlus` 1/0, nudging the tempo while held |
| Shift + Pitch Bend − / + | Transposes the deck down or up a semitone (`PitchDown` / `PitchUp`, once per press). It turns the deck's key lock (P) on first, since Syndicate transposes only with it on |
| Param ◀ ▶ | `BeatSkip ∓1` |
| Browse knob turn and press (Shift for Enter), Back, Forward, Track ◀ ▶ | `Browser/Up`, `Browser/Down`, `Browser/L{deck}`, `Back`, `Enter` |
| Shift + browse knob turn (ZOOM) | Zooms the deck in front's waveform, one step per click: `WaveformZoomIn` 1 clockwise, `WaveformZoomOut` 1 counter-clockwise |

**LEDs:**
- Play, Cue, Sync and Master follow Syndicate's state. Play blinks while a quantized start is pending.
- Key Lock, Shift and the pad-mode buttons show the bridge's own state. Censor is lit while Reverse is on, held or latched with Shift.
- The pitch arrows by the fader show pickup: while the fader waits to meet Syndicate's tempo, the arrow pointing the way to move it is lit, and both go out when it catches. No arrow is lit while the deck's tempo slider is disabled (a synced follower) or no track is loaded.
- Buttons with no state of their own are lit dim so the panel reads in the dark, and full while held: Beat Jump, Track ◀ ▶, Pitch Bend − / +, Param ◀ ▶, the browse knob's ring and the deck select button. Vinyl is lit the same way, and also full while its seek mode is on.
- Pads show your hot cues in Syndicate's cue colors, and each pad mode in its own color. On the LC6000 they're exact, through Denon's own color message (with **Exact colors on the LC6000** off, they're quantized to its 64-color table). A held pad lights brighter.
- The platter ring lights when a track is loaded, in its deck's color, the same as the deck's badge in the app, so switching layers changes it. On the LC6000 it shows the exact color through Denon's own color message; turn off **Exact colors on the LC6000** in **Settings › Decks** to go back to the 64-color table. Deck colors follow Syndicate's cue palette (slots 1, 3, 5 and 7, under CUE COLORS) as you change it, or set your own under **Settings › Decks**. It can also pulse on Syndicate's master clock, on each beat or on the downbeat: with exact colors, full on the beat and easing down until the next one, never dark.
- **Light brightness** (**Settings › Decks**, with exact colors on) dims the pads and the platter ring together, from 10% to 100%, for a dark room.

**Recovery:**
- Unplugging the LC6000, sleeping the Mac, switching layers or quitting releases every held control first, including a held Pitch Bend or a latched Reverse.
- Plugging the controller back in repaints its LEDs.
- If Syndicate restarts, the bridge asks it to send its state again.

**Not possible:**
- Scratching: Syndicate has no scratch or scrub OSC route.
- Slicer mode: it is unmapped.

**Jog display** (the LC6000's round screen in the platter, #165):
- It shows the deck in front: its number in the deck's color, the title and artist, key and BPM, and the master beat around the edge. Turn it on or off in **Settings › Controller › Show the deck on the jog display**.
- **Key display** writes the key as Syndicate sends it (**Traditional**, the default, such as `C#m`) or as its Camelot code (**Camelot**, `12A`). Syndicate always sends the traditional name, whatever its own key setting, so pick the one that matches it. The jog display and the Diagnostics preview change at once.
- On Denon's own firmware (**Firmware: Denon**, the default) DeckBridge uploads a picture of each deck.
- **Firmware: Custom** is only for a unit flashed with DeckBridge's display firmware, an experiment that isn't part of the release. Such a unit answers DeckBridge and draws the screen itself from small messages: the needle, the beat, the time left with a warning near the end, the level meter, and the deck's phase against the master. It shows our logo with the deck's number when Syndicate stops answering. A unit that doesn't answer gets pictures, as on Denon's firmware.
- **Diagnostics › Jog display** previews every deck's screen, drawn or pictures, as the unit would show it.

## Install

DeckBridge is in public beta on TestFlight: join at **[testflight.apple.com/join/HWcpqqpz](https://testflight.apple.com/join/HWcpqqpz)**, then install it from the TestFlight app (macOS 26 or later). The Mac App Store release is coming. It lives in the menu bar and has no Dock icon. On first launch it opens a short setup guide for Syndicate.

## Set up Syndicate

1. **Settings → OSC:** turn **OSC INPUT ENABLED** on. The listen port defaults to 9090.
2. **Settings → OSC FEEDBACK:** set DEST IP to the bridge's computer (`127.0.0.1` if it's the same one) and PORT to `9096`.
3. **Settings → OSC FEEDBACK → SUBSCRIPTIONS:** Turn on these subscriptions: Playing, PlayPending, Loaded and TrackInfo, Position/Progress, TempoSlider and TempoSliderEnabled, Cues, BPM and Sync, Loop and Volume.
4. **Settings → MIDI:** turn your controller's MIDI input **off** (for example, Denon LC6000 PRIME). Otherwise Syndicate's own mapping and the bridge would both react to every button.

Quit djay Pro, Engine DJ or any other app using your controller first, and power-cycle your controller if one was open: they can switch its MIDI mode until it restarts.

The **Setup guide** button in the panel, and **Setup Guide…** in Settings, show the same steps. The guide shows the panel's status lights as you go, and its button reads **Done: feedback live** once Syndicate answers.

## Four decks from one LC6000

The LC6000 has four deck layers: **Shift + deck select** steps through them, and the bridge follows. A plain press of the deck select button (printed **Slip**), with no Shift, steps them too (#420); that moves only the bridge, not the unit's own layer. Layer N drives Syndicate deck N, so one unit plays all four decks. On its own the LC6000 keeps every control on MIDI channel 1 and only signals the layer; the bridge sends those controls to the active layer's deck. (Another DJ app can switch it to one channel per layer until it restarts; the bridge follows that too, but quit those apps first.)

- **Switching layers:** anything held on the old layer is released on its deck, and the LEDs repaint from the new deck's state.
- **Pitch fader:** all layers share the one fader, so on the new layer it waits until it meets that deck's tempo (pickup), and the tempo doesn't jump.
- **The panel:** it shows the active deck with "Following controller layers" instead of the deck picker, since the hardware picks the deck.
- **Turning it off:** turn off **Follow controller layers** in Settings to drive one deck, chosen in the panel or Settings, from every layer.

## The menu-bar panel

Click the menu-bar icon (a jog wheel) to open the panel:
- **Header:** the controller's name and what last happened to it, such as an unplug.
- **Deck picker:** four badges, 1–4. A click switches the deck at once. A controller following its own layers (the LC6000's default) shows the active layer's deck with "Following controller layers" instead: the controller picks the deck.
- **Status lights:**
  - **CONTROLLER:** NOT CONNECTED (none yet since launch), CONNECTED, UNPLUGGED, MIDI ERROR or WAITING.
  - **FEEDBACK:** LIVE once Syndicate answers.
  - **TEMPO:** MASTER when this deck leads the tempo.
- **Why no LEDs?:** says in plain words what to fix when something is wrong, with a **Copy details** button for the raw error.
- **Settings…** and **Diagnostics…**
- **Demo controller:** runs a scripted controller against a simulated Syndicate, so you can see the bridge work without hardware. Nothing goes to the network, and it's off again at the next launch.
- **Quit:** asks first while feedback is live, because quitting stops the controller.

If the bridge itself can't start, the header says **Bridge stopped** with the reason: MIDI, Syndicate's address or the controller profiles. The help says how to fix it.

## Settings

Open **Settings…** from the menu.

- **Controller:** the Syndicate **Deck** (1–4), the **MIDI input** and **MIDI output**, and the **Channel**.
  - **Layers:** with **Follow controller layers** on (the default for the LC6000), the controller picks the deck itself. See [Four decks from one LC6000](#four-decks-from-one-lc6000).
  - **Deck:** a click applies at once, as in the panel.
  - Automatic picks the first connected device that a controller profile matches.
  - **Channel:** "From the profile" uses the profile's channel (1 for the LC6000).
  - **Add controller** drives a second LC6000 on another deck. Both share Syndicate's one feedback stream.
  - To use two controllers on one device, tell them apart by channel.
- **LEDs:** turn them off to run without lights.
- **OSC:** Syndicate's host and port. The default is this Mac (`127.0.0.1`), port 9090. The host must be an IP address, such as `192.168.1.20` for Syndicate on another Mac (System Settings › Network shows it).
- **Feedback:** the port Syndicate sends feedback to (default 9096) and where the app listens.
  - **This Mac only** is the default.
  - **All networks** is for Syndicate on another Mac. macOS asks once for permission to use the local network.
- **Mapping:** import, export or reset the mapping. See [Mapping overrides](#mapping-overrides).
- **Start at login:** off by default.
- **Setup Guide…** reopens the Syndicate setup steps.

Settings are checked before they're saved. A bad port, an empty host, or two controllers on the same device and channel are listed in plain words, and nothing changes until you fix them.

## Check the mapping on your unit (do this first)

The numbers come from Denon's *LC6000 PRIME MIDI Specification v1.0* and were checked on a real unit. A few are still PROVISIONAL: they're listed in [`Packages/ControllerBridgeKit/README.md`](Packages/ControllerBridgeKit/README.md#the-default-mapping). Open **Diagnostics…** from the menu to check them:

- **MIDI Monitor** shows every incoming message with its mapping name, or `UNMAPPED`. Move every control. Anything UNMAPPED needs a mapping entry.
- **LED Sweep** steps the pads and ring through all 64 color values, then lights each button note in turn.
- **OSC Log** shows what goes to Syndicate and what comes back.

Things to look for:
- **Jog feel:** `jog.seek_seconds_per_rev` and `jog.beats_per_rev` set how far one platter turn seeks or skips while paused.
- **Pitch direction:** the fader's top is slower, as on a real unit. If yours works the wrong way, set `pitch.invert` to `true`.
- **Colors:** the color velocity is 2 bits each of red, green and blue (`0b00RRGGBB`), confirmed on a unit. LED Sweep shows it on yours.
- **Channel:** the spec only documents channel 1. Pick another in Settings if your unit uses one.

## Mapping overrides

To fix a PROVISIONAL value for your unit without a new build, use the **Mapping** section in Settings:

1. Choose **Export…** to save the mapping in use as a profile file.
2. Edit the values you need. The file only needs the keys you change.
3. Choose **Import…** to load it.

The import is merged over the bundled LC6000 profile and checked first. Deck, Channel and the OSC addresses come from Settings, so a file's values for them aren't applied (and Export leaves them out). Unknown keys, wrong types, out-of-range numbers and duplicate assignments are all listed at once, and a rejected file leaves the working mapping as it was. An accepted import releases anything held, then repaints the LEDs. The app keeps the imported file and loads it at every launch. The Mapping section shows which mapping is in use. **Reset to default** goes back to the bundled profile.

## Development

All the bridge logic is in a Swift package, `Packages/ControllerBridgeKit`, which builds and tests in the terminal. `App/` holds the menu-bar app, the CoreMIDI and UDP adapters, and the SwiftUI windows. The Xcode project is generated from `project.yml` and isn't committed.

```sh
(cd Packages/ControllerBridgeKit && swift test)
brew install xcodegen && xcodegen generate
xcodebuild -project ControllerBridge.xcodeproj -scheme ControllerBridge -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
scripts/smoke.sh   # a virtual LC6000 and a fake Syndicate check Play out and the Play LED back; CI requires it too
```

Build Release for the smoke check: an ad-hoc Debug build leaves out the hardened runtime. Quit Syndicate and the app itself first, because the smoke check needs UDP 9090 and 9096. With no real LC6000 attached, the check runs the app on automatic devices beside a virtual "… WD" port, as on a real unit (#143). A real controller can stay plugged in: then the check pins the app to its own virtual device instead and says the automatic case was skipped. It puts your saved settings back afterwards. CI always runs the automatic case.

**CI uses an older Xcode than you may have locally.** GitHub's standard macOS runner builds with Xcode 26.x (Swift 6.2), while development has been on Xcode 27.2. The two compilers can disagree. Once, Xcode 26.6's Release optimizer crashed on code that 27.2 built fine (#65). If **App build** fails with a `swift-frontend` stack dump, find the function named in `gh run view <id> --log-failed`, then simplify or split it.

Releases are a version tag on `main`. See [`docs/DEVELOPING.md`](docs/DEVELOPING.md#releasing-to-testflight) for the workflow, its secrets and the one-time setup.

### Look and fonts

The app follows Syndicate's flat style (#34) in its dark and light themes. The colors are Syndicate's own tokens, from its user guide's CSS (#127), and `ControllerBridgePresentation` tests every text color against WCAG AA in both themes. **Settings › Appearance** picks Match macOS, Dark or Light. The app bundles [Geist and Geist Mono](https://github.com/vercel/geist-font) 1.9.2, the site's fonts (#171), under the [SIL Open Font License 1.1](https://openfontlicense.org): Geist for UI text, Geist Mono for labels and numbers. The license file ships in the app, in `Contents/Resources/Fonts/` (`App/Fonts/` in the repo), and the release preflight fails if a font or the license is missing.

For PR screenshots, a Debug build can render the panel without a screen: `ControllerBridge.app/Contents/MacOS/ControllerBridge --render-snapshots snaps`. It prints where the PNGs went (inside the sandbox container). Release builds leave this out.

### History

Before the app there was a Python command-line bridge (`lc6000-bridge`). It was removed in #30, once the app matched it. The parity audit on #30 maps each of its tests to the Swift test that replaced it, and its code is in the git history before that PR.
