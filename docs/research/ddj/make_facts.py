# Writes ddj-400.facts.json and ddj-flx4.facts.json (#280): the facts we read from the sources, a source per key.
# Values are our own reading of each message; nothing is copied from Pioneer's document or Mixxx's files.
#   python3 docs/research/ddj/make_facts.py
import json, os

LIST = "DDJ-FLX4 MIDI list v1.0"   # docs/research/controllers.md, section 4.2, for the archived copy
M400 = "Mixxx Pioneer-DDJ-400.midi.xml @dc4bf99"

def facts(model):
    # (dotted key, value, where the FLX4 list says it, the Mixxx control that agrees for the DDJ-400)
    rows = [
        ("midi.channel", 1, "p.1: deck 1's buttons on channel 1 (status 90)", "play on 0x90"),
        ("midi.layers", [{"channel": 1, "deck": 1, "pad_channel": 8, "shifted_pad_channel": 9},
                         {"channel": 2, "deck": 2, "pad_channel": 10, "shifted_pad_channel": 11}],
         "p.1: decks 1 and 2 on channels 1 and 2; pp.3-5: pads on 8 and 10, with Shift on 9 and 11", "pads on 0x97-0x9A"),
        ("midi.encoder_format", "offset_64", "p.1: the jog sends the change, up from 0x41 clockwise, down from 0x3F", "jogTurn"),
        ("notes.play", 0x0B, "p.1: PLAY/PAUSE, note 0x0B", "play 0x90 0x0B"),
        ("notes.cue", 0x0C, "p.1: CUE, note 0x0C", "cue_default 0x90 0x0C"),
        ("notes.sync", 0x58, "p.2: BEAT SYNC, note 0x58 (sent on release, footnote 3)", "syncPressed 0x90 0x58"),
        ("notes.loop_in", 0x10, "p.1: LOOP IN, note 0x10", "loop_in 0x90 0x10"),
        ("notes.loop_out", 0x11, "p.1: LOOP OUT, note 0x11", "loop_out 0x90 0x11"),
        ("notes.shift", 0x3F, "p.1: SHIFT, note 0x3F", "shiftPressed 0x90 0x3F"),
        ("notes.platter_touch", 0x36, "p.1: jog top touch, note 0x36", "jogTouch 0x90 0x36"),
        ("notes.shifted.cue", 0x48, "p.1: CUE with Shift, note 0x48", "start_play 0x90 0x48"),
        ("notes.shifted.sync", 0x60, "p.2: BEAT SYNC with Shift, note 0x60", "cycleTempoRange 0x90 0x60"),
        ("notes.shifted.loop_in", 0x4C, "p.1: LOOP IN with Shift, note 0x4C", "toggleLoopAdjustIn 0x90 0x4C"),
        ("notes.shifted.loop_out", 0x4E, "p.1: LOOP OUT with Shift, note 0x4E", "toggleLoopAdjustOut 0x90 0x4E"),
        ("notes.pads", list(range(8)), "p.3: HOT CUE mode pads 1-8, notes 0x00-0x07", "hotcue_1..8_activate 0x97 0x00-0x07"),
        ("pads.channel", 8, "p.3: deck 1's pads on channel 8", "0x97"),
        ("pads.shifted_channel", 9, "p.3: deck 1's pads with Shift on channel 9", "0x98"),
        ("jog.relative_cc", 0x22, "p.1: platter top with vinyl mode on, CC 0x22; p.5: vinyl mode defaults on", "jogTurn 0xB0 0x22"),
        ("jog.relative_edge_cc", 0x21, "p.1: wheel side, CC 0x21", "jogTurn 0xB0 0x21"),
        ("pitch.bits", 14, "p.2: TEMPO, an MSB/LSB pair", "tempoSliderMSB/LSB"),
        ("pitch.msb_cc", 0x00, "p.2: TEMPO MSB, CC 0x00", "tempoSliderMSB 0xB0 0x00"),
        ("pitch.lsb_cc", 0x20, "p.2: TEMPO LSB, CC 0x20", "tempoSliderLSB 0xB0 0x20"),
        ("mixer.volume", {"bits": 14, "msb_cc": 0x13, "lsb_cc": 0x33}, "p.2: CH FADER, CC 0x13/0x33", "volume 0xB0 0x13/0x33"),
        ("mixer.trim", {"bits": 14, "msb_cc": 0x04, "lsb_cc": 0x24}, "p.2: TRIM, CC 0x04/0x24", "pregain 0xB0 0x04/0x24"),
        ("mixer.eq_high", {"bits": 14, "msb_cc": 0x07, "lsb_cc": 0x27}, "p.2: EQ HI, CC 0x07/0x27", "parameter3 0xB0 0x07/0x27"),
        ("mixer.eq_mid", {"bits": 14, "msb_cc": 0x0B, "lsb_cc": 0x2B}, "p.2: EQ MID, CC 0x0B/0x2B", "parameter2 0xB0 0x0B/0x2B"),
        ("mixer.eq_low", {"bits": 14, "msb_cc": 0x0F, "lsb_cc": 0x2F}, "p.2: EQ LOW, CC 0x0F/0x2F", "parameter1 0xB0 0x0F/0x2F"),
        ("mixer.cue_note", 0x54, "p.2: headphone CUE, note 0x54", "pfl 0x90 0x54"),
        ("mixer.meter.cc", 0x02, "p.2: CH LEVEL METER out, CC 0x02 on the deck's channel", "VU out 0xB0 0x02 (script)"),
        ("mixer.meter.steps", [0, 0x26, 0x41, 0x57, 0x65, 0x77],
         "p.2: lights from the bottom, five bands from 0x26, 0x41, 0x57, 0x65 and 0x77", None),
    ]
    if model == "400":
        rows.append(("notes.shifted.play", 0x47, None, "reverseroll 0x90 0x47 (the FLX4 list has 0x0E)"))
    else:
        rows.append(("notes.shifted.play", 0x0E, "p.1: PLAY/PAUSE with Shift, note 0x0E", None))
    mapping, sources = {}, {}
    def put(path, value):
        node = mapping
        *parents, last = path.split(".")
        for p in parents: node = node.setdefault(p, {})
        node[last] = value
    for key, value, page, mixxx in rows:
        put(key, value)
        if model == "400":
            where = (f"{LIST} {page}, for the FLX4; " if page else "") + (f"{M400}: {mixxx}" if mixxx else "the DDJ-400 has no list of its own")
        else:
            where = f"{LIST} {page}" if page else f"{M400}: {mixxx}"
        leaves = [(f"{key}.{k}", v) for k, v in value.items()] if isinstance(value, dict) else [(key, value)]
        for leaf, _ in leaves: sources[f"mapping.{leaf}"] = where
    return {"mapping": mapping, "sources": sources}

here = os.path.dirname(os.path.abspath(__file__))
for model, name in (("400", "ddj-400"), ("flx4", "ddj-flx4")):
    with open(os.path.join(here, f"{name}.facts.json"), "w") as f:
        json.dump(facts(model), f, indent=2)
        f.write("\n")
