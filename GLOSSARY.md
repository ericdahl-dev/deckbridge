# DeckBridge

DeckBridge plays Syndicate from a DJ controller: it reads the controller's MIDI, drives Syndicate over OSC, and lights the controller (and, on the LC6000 PRIME, its jog display) from Syndicate's feedback.

## Language

### Syndicate and the bridge

**Syndicate**:
The DJ app DeckBridge drives. DeckBridge is independent of it and talks to it only over OSC.

**Feedback**:
The OSC messages Syndicate sends about its state (playing, cues, BPM, track info), which light the controller.
_Avoid_: updates, status messages

**Subscription**:
One kind of feedback the user turns on in Syndicate's settings; without it, that state never arrives.

**Resend**:
Asking Syndicate to send all its feedback again, so the controller can be painted from scratch.
_Avoid_: refresh, sync

**Dropout**:
Syndicate's feedback going quiet while it was live; the controller's lights stop being trusted until it returns.
_Avoid_: disconnect, timeout

**Deck**:
One of Syndicate's four players, numbered 1–4.
_Avoid_: channel, side

**Deck layer**:
One of a controller's own decks on shared hardware, each on its own MIDI channel; the LC6000 has four.
_Avoid_: bank, page

**Coordinator**:
The one owner of every controller, deck layer and Syndicate's feedback; everything that reaches the bridge goes through it.

**Pickup**:
A fader or knob waiting to meet Syndicate's value before it takes over, so it never jumps.
_Avoid_: soft takeover, catch

**Demo controller**:
A built-in, scripted controller that drives the bridge with no hardware.

**LED sweep**:
A Diagnostics run that lights every pad and button through its values, to check what the controller shows.

### Controllers

**Controller profile**:
The data that describes one controller model to DeckBridge: its notes, CCs, LEDs and layers.
_Avoid_: mapping file, preset

**Profile key**:
One optional setting in a controller profile; left out, it takes the LC6000's value.

**Pad mode**:
What the pads do: Hot Cue, Roll, Loop or Slicer.

**Needle strip**:
The hardware: the LC6000's touch strip for jumping to a place in the track.
_Avoid_: needle (that's the jog display's), needle drop

**Platter ring**:
The LED ring around the LC6000's jog wheel, lit in the deck's color.
_Avoid_: jog ring, ring (that's the jog display's)

**Palette slot**:
One of Syndicate's cue colors, by number; a deck's color is a palette slot.
_Avoid_: slot (that's the jog display's), color index

### Capture

**Capture**:
A guided recording of what one controller sends, step by step, made to draft its controller profile.
_Avoid_: recording, learn

**Capture file**:
The file a capture saves: the controller's name and ports, each step's raw MIDI and the noise. It's sent only if the owner emails it.

**Prompt**:
One instruction in a capture, such as "Press and release Play on deck 1".

**Step**:
One prompt as recorded: confirmed with what arrived, or skipped.

**Noise**:
MIDI a controller sends on its own (a heartbeat, the clock), learned while hands are off and never credited to a step.
_Avoid_: junk, chatter

**Tail**:
A message left over from the step before (a late release, a jog still spinning), kept in the file but credited to nothing.

**Inferred**:
Facts worked out from a capture file's raw MIDI (which control, how it encodes, its Shift layer), the same way for the app's capture and the web capture.

**Player type**:
What a deck has loaded, as Syndicate reports it: a track, an OSC clip, or nothing.

### Jog display

**Jog display**:
The LC6000 PRIME's round screen in the middle of the jog wheel, which DeckBridge draws on.
_Avoid_: jog screen, platter display

**WD port**:
The jog display's own USB MIDI port, separate from the controls'.

**Hello**:
The message that puts the jog display under DeckBridge's control; **goodbye** hands it back to the unit.

**Slot**:
One of the jog display's two image stores; an upload goes into the one not being shown, then that slot is shown.
_Avoid_: buffer, page

**Upload**:
Sending one image of the deck in front into a slot.

**Deck in front**:
The deck the jog display shows: the controller's active deck layer, or the deck the preview follows.
_Avoid_: front deck, current deck

**Master clock**:
Syndicate's beat counter for the whole set, the same for every deck.

**Ring**:
The jog display's four beat sections, lit by the master clock's beat on every deck.
_Avoid_: beat ring, platter ring (that's the LEDs')

**Needle**:
The jog display's hand, showing where the deck is in its own bar.
_Avoid_: pointer

**Preview**:
What a deck's jog display would show, drawn by DeckBridge for Diagnostics, for every deck, whether or not anything is sent.
_Avoid_: simulator image, mock

**Drawn display**:
The jog display drawing its own picture from small messages DeckBridge sends (the deck, its texts, its state, the beat, the needle, the time, the meter, the phase), once our display firmware is on the unit and has answered DeckBridge's ask; otherwise DeckBridge uploads images.
_Avoid_: custom mode, chip mode

**Panel**:
The jog display's whole screen in drawn mode, which our picture covers: the round frame in its middle, black around it but for the progress ring.
_Avoid_: screen (not the menu-bar panel, the controller's top panel, or the deck panel)

**Block A**:
Our small part of the drawn display's firmware, inside Denon's own: it takes DeckBridge's messages, answers its ask, and hands drawing to block B only once block B has checked out.
_Avoid_: hook, patch

**Block B**:
The drawn display's drawing, kept in the display's spare flash beside Denon's firmware; block A and block B must come from the same build, or the display stays silent.
_Avoid_: upper block

### LC6000 firmware updates

**Display chip**:
The LC6000's chip that runs the jog display: Denon's firmware, with DeckBridge's display firmware (block A, and block B once installed) when the owner has put it there. The firmware updater backs it up and updates it.
_Avoid_: WD chip, jog display chip

**Top panel chip**:
The LC6000's chip that runs the controls on its top, such as the pads and the deck select. Always "top panel chip" in full, never "top panel" alone (see **Panel**). DeckBridge's top panel firmware is one small change to Denon's.
_Avoid_: TP chip, top panel (alone), main chip

**Update mode**:
A chip restarted into ST's own bootloader (USB 0483:DF11), where it can be read and written over USB and runs nothing else. Entering it writes nothing; a power cycle ends it. The updater works on one chip in update mode at a time.
_Avoid_: DFU mode, bootloader mode, flash mode

### Deck display

**Display feed**:
DeckBridge's OSC stream of the deck in front, for a display other than the jog display: one value per address under `/DeckBridge/Display/`, sent to the host and port the DJ sets, never read back (ADR 0011).
_Avoid_: display OSC, panel feed

**Deck panel**:
The Wi-Fi display by the controller that shows the display feed: an ESP32 7" screen running our firmware from `tools/deck-panel/`. "The panel" in the display feed's tickets.
_Avoid_: Panel alone (that's the jog display's drawn screen), ESP32 display
