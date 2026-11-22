# Pioneer DDJ-400 and DDJ-FLX4: drafts from the docs (#280)

These drafts come from the docs alone, before any owner's capture (#282). Every value is our own reading of two
sources, and each key cites where it came from. No text or file is copied from either source.

- **The FLX4's official MIDI list:** "DDJ-FLX4 List of MIDI messages", Ver 1.0. Its archived copy is linked in
  `docs/research/controllers.md`, section 4.2. The DDJ-400 has no list of its own, so this list stands in for it
  wherever the two agree.
- **Mixxx's mappings:** `Pioneer-DDJ-400.midi.xml` and `Pioneer-DDJ-FLX4.midi.xml`, pinned at commit `dc4bf99`.

| File | What it is |
|---|---|
| `make_facts.py` | Writes both facts files from one table, so the facts the two share stay identical. |
| `ddj-400.facts.json`, `ddj-flx4.facts.json` | The facts, as a partial profile with a `sources` entry per key. |

To draft a profile from them:

```sh
python3 docs/research/ddj/make_facts.py
scripts/capture_to_profile --device "DDJ-400" --docs docs/research/ddj/ddj-400.facts.json --out drafts/
```

The `DraftPioneerFactsTests` suite checks every facts file: each must draft with no import problems, and every key
must have a source.

## What the drafts set

Both drafts set these keys. Each draft has 42 TODOs, no disagreements and no import problems.

| Area | Keys |
|---|---|
| Decks | Channels 1 and 2 (`midi.layers`); pads on channels 8 and 10, and with Shift held on 9 and 11 |
| Transport | Play 0x0B, Cue 0x0C, Sync 0x58, Loop In 0x10, Loop Out 0x11, Shift 0x3F |
| Shift (done in hardware) | Cue 0x48, Sync 0x60, Loop In 0x4C, Loop Out 0x4E, and Play (see below) |
| Pads | Hot Cue mode, notes 0x00–0x07 |
| Jog | Relative CC 0x22 on the top (vinyl mode on, the default), 0x21 on the edge, offset-64; touch note 0x36 |
| Tempo | 14-bit, CC 0x00/0x20 |
| Mixer | Fader 0x13/0x33, trim 0x04/0x24, EQ high, mid and low 0x07/0x27, 0x0B/0x2B and 0x0F/0x2F; headphone cue note 0x54; VU meter out on CC 0x02 in five levels |

## How the two differ

Mixxx's two mappings share 193 of the DDJ-400's 199 input messages, and all 110 LED outputs.

The table compares Mixxx's two mappings. Where the FLX4's official list says the same, it's noted.

| Message | DDJ-400 (Mixxx) | DDJ-FLX4 (Mixxx) |
|---|---|---|
| Play/Pause with Shift | Note 0x47 | Note 0x0E (also in the list, p.1) |
| Beat FX channel select, channel 2 | Note 0x11 on channel 5 | Note 0x11 on channel 6 |
| Beat FX channel select, master | Note 0x14 on channel 5 | None |
| Headphone level | CC 0x0D/0x2D on channel 7 | None |
| Beat FX on/off on channel 6 | None | Notes 0x47, and 0x43 with Shift |
| Pad mode buttons | None | Notes 0x1B, 0x1E, 0x20 and 0x22, and with Shift 0x69, 0x6B, 0x6D and 0x6F (also in the list, p.3) |
| Pad modes | Hot Cue, Beat Loop, Beat Jump, Sampler | Those four, plus Pad FX1, Pad FX2, Keyboard and Key Shift (also in the list, pp.3–5) |

Only Play/Pause with Shift is a key the drafts set, so it's the one value that differs between the two files.

## What today's profile keys can't express

Each of these has its own ticket. Until one is solved, its controls are left out of the drafts.

- **#368:** the browse, load and filter controls are on channel 7, not the deck's channel.
- **#369:** the crossfader.
- **#370:** Pioneer's pad modes and their note ranges, which don't match Roll and Slicer.
- **#371:** the track-loaded LED, which is on channel 16.
- **#372:** vinyl mode, and the jog while Shift is held.
- **#373:** what only the owner can settle: ticks per platter turn, tempo direction, Sync on release, VU bands,
  pad LED levels.
- **#199:** Mixxx's SysEx keep-alive.
