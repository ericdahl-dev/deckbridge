# The owner's Debug app: replacing and relaunching it

The owner runs a Debug build from `~/Applications/DeckBridge-Debug/ControllerBridge.app`. Only the CoS replaces or
relaunches it; other agents build and never launch.

## Recipe

```sh
app=~/Applications/DeckBridge-Debug/ControllerBridge.app
osascript -e 'quit app id "dev.ericdahl.ControllerBridge"'      # its quit releases what the LC6000 holds
while pgrep -qf "$app/Contents/MacOS/ControllerBridge"; do sleep 0.5; done
rm -rf "$app" && cp -Rp build/Build/Products/Debug/ControllerBridge.app "$app"
logs=~/Library/Logs/DeckBridge-launch && mkdir -p "$logs"
open --stdout "$logs/stdout.log" --stderr "$logs/stderr.log" "$app"
sleep 10; pgrep -lf "$app/Contents/MacOS/ControllerBridge" || echo "DeckBridge is not running"
```

Build with `-scheme ControllerBridge` (scheme 0 is appstore-frames).

## Why

- **stdout to a file, never a pipe (#653).** The app's log also prints to stdout, for the smoke script. From an agent's
  tool shell, `open` can hand the app the shell's pipe; once the command returns, nothing reads it, and the first
  flush of the log (a few hundred ms in) used to kill the app with SIGPIPE and no crash report:
  `exited due to SIGPIPE | sent by ControllerBridge, ran for 408ms` in launchd's log. The app now ignores SIGPIPE,
  but a file keeps the log and keeps an older build safe too.
- **Wait for the old process to go.** Its quit sends the releases to Syndicate and the LC6000; replacing the bundle
  under it, or a second instance, clashes on the OSC ports and gives the LC6000 two hosts.
- **Check it's alive after 10 s.** A launch that dies early leaves nothing on screen to say so. If it's gone, look at
  launchd's reason: `/usr/bin/log show --last 2m --predicate 'process == "launchd" AND eventMessage CONTAINS "ControllerBridge"'`.

## Starting a deck for a timed run

Use `scripts/syndicate_deck` ([syndicate-deck.md](syndicate-deck.md)), then check that the deck is playing before the clock starts.
