# Starting a deck for a timed run: `scripts/syndicate_deck`

Before any timed run on the hardware (a deck panel perf run, a jog display check), start the deck with this tool, then
check that it is playing. On 2026-11-20 a 5-minute run was lost to a paused deck (#680).

```sh
scripts/syndicate_deck play 1 --cue 1   # deck 1 from hot cue 1
scripts/syndicate_deck play 1           # deck 1 from where it is
scripts/syndicate_deck pause 1
scripts/syndicate_deck toggle 1         # the Play button: playing stops, stopped plays
```

Add `--host` and `--port` to aim elsewhere. Otherwise Syndicate's host and port come from DeckBridge's settings
(Settings › Syndicate), else Syndicate's defaults, 127.0.0.1:9090. The first run builds the tool, about a minute.

## What it sends

The tool sends DeckBridge's own messages for the same buttons, encoded by the Kit's OSC code. Its tests compare them
with what the app's Bridge sends.

| Command | OSC to Syndicate | As in the app |
|---|---|---|
| `play <deck> --cue <n>` | `/Syndicate/Deck/<deck>/HotCue <n> 1`, then `<n> 0`, then `Playing 1` | the hot cue pad's press and release, then Play with Cue held |
| `play <deck>` | `/Syndicate/Deck/<deck>/Playing 1` | Play with Cue held (#360) |
| `pause <deck>` | `/Syndicate/Deck/<deck>/Playing 0` | the cue module's stop |
| `toggle <deck>` | `/Syndicate/Deck/<deck>/PlayPause 1` | the Play button |

`play` and `pause` set the state rather than toggling it. So a second `pause` never starts a deck, and a second
`play` never stops one. On the owner's Mac the hot cue alone starts a paused deck. `Playing 1` makes sure of it.

## What it never does

- It never talks to the LC6000. It sends OSC to Syndicate only and links no MIDI code.
- It never changes DeckBridge's settings. It reads them from the app's container
  (`~/Library/Containers/dev.ericdahl.ControllerBridge/…/dev.ericdahl.ControllerBridge.plist`, key `settings.v1`)
  and never writes them.
- It never shares DeckBridge's feedback port, so it can't take Syndicate's feedback away from the app.

## Checking the deck is playing

- **DeckBridge not running:** the tool listens on the feedback port for 1 s and prints `deck 1: playing` or
  `deck 1: stopped`. If no feedback comes, it says it can't tell.
- **DeckBridge running:** it holds that port, so the tool prints that it can't tell. Check one of these instead:
  - DeckBridge's debug log or its display-feed trace: the deck's `Playing` feedback from Syndicate;
  - the deck panel's perf line (`crowpanel-perf`, every 5 s): with a deck playing, about 30 feed datagrams a second
    and 20+ frames a second; paused, about 3 datagrams and 2 frames a second.

Exit status: 0 once sent, whether or not it could tell. 1 if the send failed. 2 for a usage error, when nothing is sent.
