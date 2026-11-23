# DeckBridge

DeckBridge is a native macOS menu-bar app that lets you play Syndicate, the DJ and performance software by Untitled Audio Syndicate Ltd., from a Denon LC6000 PRIME controller. It reads the controller's MIDI over USB, converts it, sends it to Syndicate's OSC input, and lights the controller from Syndicate's OSC feedback.

- Website: https://getdeckbridge.app/
- Support: https://getdeckbridge.app/support/
- Privacy: https://getdeckbridge.app/privacy/
- Contact: deckbridge@ericdahl.dev

## Why it exists

Syndicate's own MIDI mapping (version 0.3.7) can't handle the LC6000's 14-bit jog wheel or its 14-bit pitch fader, and it gives LED feedback only to the DDJ-FLX4 and FLX10 (Syndicate User Guide 0.3.7, section 13.9: https://untitledaudiosyndicate.com/user-guide/index.html#c13-9). DeckBridge fills that gap: the LC6000 talks MIDI to DeckBridge, and DeckBridge talks OSC to Syndicate.

```
LC6000 PRIME --USB MIDI-->  DeckBridge  --OSC, port 9090-->           Syndicate
LC6000 PRIME <--MIDI LEDs-- DeckBridge  <--OSC feedback, port 9096--  Syndicate
```

## Features

- **Full-resolution jog and pitch:** the 14-bit jog wheel and pitch fader reach Syndicate at full resolution. Pickup on the pitch fader keeps the tempo from jumping.
- **Four decks from one controller:** DeckBridge follows the LC6000's own deck layers (Shift + deck select), so one unit drives decks 1 to 4.
- **Deck colors:** deck colors follow Syndicate's palette live, and the jog ring lights in the deck's color.
- **Shift functions:** the LC6000's printed Shift functions work.
- **LEDs:** Play, Cue, Sync and the pads light from Syndicate's state. Hot cues show Syndicate's cue colors.
- **Safe recovery:** unplugging the controller, sleeping the Mac or quitting releases every held control first. Plugging back in repaints the LEDs.
- **Diagnostics:** a MIDI monitor, an LED sweep and an OSC log show what comes in and what goes out.
- **Demo controller:** try DeckBridge without hardware. A scripted controller plays against a simulated session.
- **A second controller:** a second LC6000 can drive another deck.
- **Syndicate on another Mac:** DeckBridge can reach Syndicate over the local network.
- **New in v1.1:**
  - The jog display: the jog-wheel display shows the deck's track, key and BPM, with Syndicate's master clock around the ring and the deck's own bar in the needle.
  - Transpose: Shift + Pitch Bend − / + transposes the deck a semitone, turning its key lock on first.
  - CDJ-style cue: PLAY while CUE is held keeps the deck playing; Shift + CUE goes back to the cue point and stops. Shift + a hot cue pad jumps there at once.
  - Channel fader: Needle Drop moves the deck's channel fader in Syndicate, from where it is (Relative) or straight to where you touch (Jump) (Settings › Controller, on by default).
  - Exact colors: the platter ring and pads light in the deck's and cues' exact colors, with no firmware change (Settings › Decks › Exact colors on the LC6000, on by default); Light brightness sets how bright.
  - Key display: Settings › Controller › Key display (with the jog display on) writes keys as Syndicate does, traditional or Camelot.
  - Display feed: DeckBridge can send the deck in front to a display on your local network, unencrypted to the one address you set (Settings › Syndicate › Display feed, off by default).

## Requirements

- macOS 26 or later.
- Syndicate, with OSC input enabled.
- A Denon LC6000 PRIME connected over USB. The LC6000 PRIME is the only controller supported today.

DeckBridge does not need djay Pro or Engine DJ. It works with Syndicate only.

## Setup in brief

Four settings in Syndicate, once. DeckBridge opens a setup guide with the same steps on first launch.

1. **Settings → OSC:** turn OSC input on. The listen port is 9090.
2. **Settings → OSC Feedback:** set DEST IP to 127.0.0.1 (or this Mac's address if Syndicate runs on another Mac) and PORT to 9096.
3. **Settings → OSC Feedback → Subscriptions:** turn on Playing, PlayPending, Loaded and TrackInfo, Position/Progress, TempoSlider/TempoSliderEnabled, Cues, BPM/Sync, Loop and Volume.
4. **Settings → MIDI:** turn the LC6000 PRIME's MIDI input off in Syndicate, so Syndicate's own mapping and DeckBridge don't both react to every button.

Quit djay Pro, Engine DJ or any other app using the controller first, and power-cycle the controller if one was open. When it's working, the DeckBridge panel shows CONTROLLER CONNECTED and FEEDBACK LIVE.

Full steps: https://getdeckbridge.app/support/

<!-- FAQ:START: provisional; the final FAQ copy will be synced here later. Keep every Q&A between these markers. -->
## In the lab

Not in your hands yet: projects on our own desk.

- **A drawn jog display:** on our own LC6000, a reflashed display chip draws the deck itself: its number in the deck color, title and artist, key and BPM, the beat ring, phase against the master, the last minute's warning and the channel meter, live from DeckBridge. This needs custom firmware that is not part of the DeckBridge app and is not offered for download, and DeckBridge never includes or distributes Denon's firmware. On the LC6000's own firmware, DeckBridge shows the deck on the jog display as described above: leave Settings › Controller › Firmware on Denon.
- **A deck panel:** a 7-inch Wi-Fi display beside the controller shows the deck in front (track, key, BPM, tempo, time left, beat, phase and level) from DeckBridge's display feed. The feed is in DeckBridge, off by default, and sends unencrypted to the one address you set on your local network. The panel is a project on our desk: there's no kit or firmware to download.

## FAQ

### Does DeckBridge need djay Pro or Engine DJ?

No. DeckBridge works with Syndicate only. Quit djay Pro, Engine DJ or any other app using the controller first, and power-cycle the controller if one was open.

### Which controllers are supported?

Only the Denon LC6000 PRIME, today. To help add yours, DeckBridge's Help add it… (in the panel) or Controller not found? (in Settings) records what your controller sends, and you choose whether to email the file: https://getdeckbridge.app/support/#add-controller

### The controller works, but the LEDs stay dark.

DeckBridge lights the controller from Syndicate's OSC feedback. Check that OSC Feedback is set to DEST IP 127.0.0.1 and PORT 9096, and that every listed subscription is on. The panel's "Why no LEDs?" line says which part is missing.

### How do I switch between decks 1 to 4?

Use the LC6000's own deck layers: Shift + deck select. DeckBridge follows the layer, releases anything held on the old deck and repaints the lights. To drive one fixed deck instead, turn off Follow controller layers in Settings and pick the deck in the panel.

### Nothing happens when I press buttons.

Quit any other DJ app that was using the LC6000 PRIME, then power-cycle the controller: some apps switch its MIDI mode until it restarts. Then check Diagnostics › MIDI Monitor: each button press should show up there.

### Can Syndicate run on another Mac?

Yes. Set the Syndicate host in DeckBridge's Settings to that Mac's IP address, and set Listen on to All networks. macOS asks once for local-network permission; allow it, or no feedback arrives.

### Can I try it without a controller?

Yes. Turn on the demo controller in the panel. A scripted controller plays against a simulated session. Nothing goes to the network unless you turn on the display feed, and then only unencrypted to the one address you set on your local network.

### Does DeckBridge collect any data?

No. The DeckBridge app collects no data: no account, no analytics, no tracking. This website counts visits with PostHog, without cookies.
<!-- FAQ:END -->

## Status and availability

- **Version 1.1.0** is in beta on TestFlight now. Join the beta: https://testflight.apple.com/join/HWcpqqpz
- **Mac App Store:** coming soon.
- **Price:** free.

## Privacy

DeckBridge collects no data. There is no account, no analytics and no tracking. It sends OSC messages to Syndicate, on this Mac by default or on your local network if you set it up that way. If you turn on the display feed, it also sends the deck in front's state, including track title and artist, unencrypted to the one address you set on your local network. This website counts visits with PostHog, without cookies: an anonymous hash that changes every day, and it does not keep your IP address. Details: https://getdeckbridge.app/privacy/

## Contact

Email deckbridge@ericdahl.dev. If you can, include what the DeckBridge panel shows and the Copy details text.

## Trademarks

DeckBridge is an independent app. It is not made by, affiliated with or endorsed by Untitled Audio Syndicate Ltd. or Denon DJ. Syndicate is a separate app by Untitled Audio Syndicate Ltd.. Denon DJ and LC6000 PRIME are trademarks of their owners.
