# App Review notes

Paste this into App Store Connect's App Review Information › Notes, for the Mac App Store and for TestFlight's Beta
App Review. Every label below is the app's own (checked against main after #176, #186, #188, #200, #258 and #262).
`scripts/test_app_review.py` pins each quoted label to the string the app shows (#29).

---

DeckBridge is a menu-bar app (no Dock icon) that bridges a Denon LC6000 PRIME DJ controller's MIDI to the Syndicate DJ app over OSC. Reviewers won't have either, so the app has a built-in demo that needs no hardware and no other software.

1. Click the DeckBridge icon (a jog wheel) in the menu bar to open its panel.
2. Click "Demo controller: Off" (under the status lights) to turn the demo on. Within a second the panel shows Demo ● Controller, Controller ● Connected and Feedback ● Live.
3. Click "Diagnostics…" to watch the simulated controller's MIDI messages and the OSC the app exchanges with a simulated Syndicate. The demo presses Play, moves the pitch fader and turns the jog wheel, then starts again about every 8 seconds.
4. In Diagnostics, click the "Jog display" tab. It previews what the LC6000's jog screen shows for the demo deck: a made-up track, "Demo Track", with its key and BPM, and a needle that turns with the bar while the demo plays. It's a preview only; nothing is sent to any device.
5. Click "Settings…" to see the four tabs: Controller, Decks, Syndicate and General.
6. On the Controller tab, with the demo still on, open the "Controller" menu and choose "Controller not found?". The capture window opens with "Demo controller" chosen; click Start. Each step asks for one control; the demo controller answers about a second later, and the window shows what it detected (such as "CC 17 + 49 on ch 1, 14-bit, absolute"). Click Next for each step, or Redo or Skip. The first step listens for 5 seconds before Next is available. The last page lists what the file holds and offers Save… and "Email to DeckBridge"; email opens a new message in the reviewer's own mail app, and nothing is sent unless they send it.
7. Click "Demo controller: On" to turn the demo off.

The demo sends nothing to the network, unless the display feed to a deck panel is turned on in Settings (off by default), and is off at every launch. The app has no accounts and no sign-in, and collects no data. Start at login is off by default.

Syndicate and the Denon LC6000 PRIME are named only to describe compatibility. DeckBridge isn't affiliated with or endorsed by Untitled Audio Syndicate Ltd. or Denon DJ.

Support: deckbridge@ericdahl.dev · https://getdeckbridge.app/support
