# DeckBridge may send a display feed to devices other than Syndicate, and never reads it back

2026-11-20. ADR 0003 says DeckBridge talks to Syndicate over OSC only. The deck panel (#490) needs the deck in front, which only DeckBridge knows, so DeckBridge also sends a **display feed**: plain OSC over UDP to one host and port the DJ sets, off by default (#616). That is the one exception to "OSC only to Syndicate". DeckBridge only sends it: it opens no listener for the feed and acts on nothing a display sends back. The panel is display-only (#490, Out of Scope). Rejected: Syndicate Net, an unknown protocol, and having the panel read Syndicate's feedback itself, which doesn't know the LC6000's deck layer.

## The contract

Every address is under `/DeckBridge/Display/` and carries exactly one value, of the OSC type below. Only changes are sent. A full snapshot of every address goes out when the deck in front changes and each time the feed's destination opens. Turning the feed on or a new host or port sends nothing until the destination opens, then sends the snapshot once (#617); the 2-second keepalive below goes out regardless, so if the destination opened before the setting came, the snapshot still arrives within 2 s. The first snapshot after that waits until Syndicate has answered for the deck in front (its cue palette, unless DeckBridge's own deck colors are on, and whether the deck is loaded, with its track if it is), for at most a second, so a display never starts on a default color or an empty deck.

| Address | Type | Value |
|---|---|---|
| `deck` | `i` | The deck in front, 1-4 |
| `color` | `i` | Its deck color as `0xRRGGBB`, the ring's and the app badge's |
| `loaded` | `i` | 1 with a track loaded. **0 is the empty state**: every other field below is then `""`, 0 or, for `phase`, -1 |
| `title` | `s` | The track's title |
| `artist` | `s` | The track's artist |
| `key` | `s` | The track's key, in Settings' key notation (traditional or Camelot), as the jog display writes it |
| `bpm` | `f` | The deck's live BPM, else the track's, to 2 decimals; 0 unknown |
| `tempo` | `f` | The change from the track's BPM in percent, (live / track - 1) × 100, to 2 decimals; 0 when the track's BPM is unknown |
| `playing` | `i` | 0 or 1 |
| `cue` | `i` | 1 while the deck's CUE button is held |
| `sync` | `i` | 0 or 1 |
| `master` | `i` | 1 when the deck is Syndicate's tempo master (synced, its tempo slider enabled), as the Master LED shows it |
| `loop` | `i` | 0 or 1 |
| `loopLength` | `f` | The loop's length in beats, fractions too (0.5, 0.25 …), unrounded; 0 with no loop |
| `beat` | `i` | Syndicate's master clock beat, 1-4, the same whichever deck is in front, as the jog ring shows it; 0 once the clock has been quiet for over 2 s |
| `clockBpm` | `f` | The BPM of the master clock `beat` follows (Syndicate's Header/BPM), to 2 decimals, so a display can time beats itself whichever deck is in front (#674). **0 is quiet**: whenever `beat` is 0, before Syndicate has given a master BPM, and in the empty state. Coming from 0 it goes in the same bundle as the clock's first beat |
| `elapsed` | `i` | Whole seconds into the track, counted down from the exact time as the drawn display does |
| `remaining` | `i` | Whole seconds left: the whole length less `elapsed`; 0 with no known length |
| `progress` | `f` | Through the track, 0-1 |
| `phase` | `f` | Against the master, 0-1: 0.5 in phase, below behind, above ahead (a half beat at the ends), by the drawn display's phase rule. **-1 is unknown** (the deck stopped, or no offset since it loaded): the one value outside its range |
| `level` | `f` | The deck's mixer meter, 0-1, on the drawn meter's dB scale (-36 to +16 dB) and ballistics |
| `goodbye` | `i` | 1: DeckBridge is quitting or the feed was turned off; nothing more follows until a snapshot. A display shows its own idle look (#651). |

`bpm`, `tempo`, `clockBpm`, `progress`, `phase` and `level` can follow Syndicate's feedback rate, so they go out together, in one slot about 30 times a second, the latest value winning; nothing is queued. A full snapshot also goes out every 2 seconds as a keepalive, so a message lost on Wi-Fi or dropped while DeckBridge's sender was behind is fixed within 2 s. While the feed is on, DeckBridge asks Syndicate for its Meter and PhaseOffset feedback.

**Datagrams.** Each update's changes go as one OSC bundle in one UDP datagram (time tag "immediately"), so a full snapshot is one datagram, not one per address (#636). One datagram per address came to about 111 a second with a deck playing (measured at the Coordinator; 73 on the wire), each snapshot a burst of 20, while a panel drains a few datagrams a frame. A bundle is at most 1200 bytes; a bigger one is split into several, in order. Title, artist and key are cut to at most 255 UTF-8 bytes, at a character boundary, so 1200 holds for every bundle. The fast fields share one slot, so a playing deck sends about 30 datagrams a second. **A display must accept both a single message and a bundle of messages**, reading each message in a bundle as if it came alone.

**A display must ignore an address it doesn't know**, and a message whose type isn't the one above. That way a newer DeckBridge can add addresses without breaking an older display.

`tools/deck-panel/feed/examples.json` holds worked examples of deck states and the messages sent for them. DeckBridge's tests and the panel core's tests both walk it.

## Over the USB cable (#667)

2026-11-21, by the owner's decisions on #667. The same feed can also go over the USB cable to a deck panel plugged into this Mac, so a panel works with no Wi-Fi set up. DeckBridge stays in the middle: Syndicate never talks to the panel. Everything above holds unchanged: the addresses, the bundles, the 1200-byte ceiling, the snapshot and keepalive rules, and send-only.

- **Its own switch.** Settings' "Send over the USB cable" is off by default and apart from the Wi-Fi switch. Either, both or neither may be on; each destination gets its own snapshot when it opens, and its own goodbye.
- **Framing.** Each OSC packet (a message or a bundle) goes as one SLIP frame (RFC 1055, as OSC 1.1 has it for serial): END (`0xC0`) before and after, `0xC0` in the packet sent as `0xDB 0xDC` and `0xDB` as `0xDB 0xDD`. `tools/deck-panel/feed/slip.json` holds worked examples, walked by both sides' tests.
- **The port.** The panel's USB bridge (WCH CH340, `1a86:7522`), found by its USB IDs, not its name. 921600 baud, 8N1. DeckBridge opens it only while the switch is on, exclusively (`TIOCEXCL`), and lets go when the switch goes off or the panel is unplugged. The port opening is the destination opening.
- **On the panel.** The cable also carries the panel's text: its logs go panel to Mac, and a `version` question (#695) comes Mac to panel outside any frame. Bytes outside a frame are text. A frame with no byte for 100 ms is dropped as cut. A feed heard on the cable shows the deck even off Wi-Fi, in setup mode too. Hold-to-reset still counts only on the waiting screen, never while a deck shows: to set up Wi-Fi with the cable's deck up, turn the cable feed off or unplug, then hold.
- **Not for speed.** The frame ledger (#662) starts at the panel, so it can't show the network's share of the lag. The cable is for setup, not for a faster screen.
