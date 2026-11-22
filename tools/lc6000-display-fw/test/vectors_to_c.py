#!/usr/bin/env python3
"""Turns the shared message vectors (vectors/messages.json, #456) into a C header for the vectors walk test.
Usage: vectors_to_c.py messages.json > vectors.h. Fails on an empty file, or an entry with no bytes."""
import json, sys

KINDS = {"capability": 0, "capability_answer": 1, "begin": 2, "end": 3, "deck": 4, "state": 5, "beat": 6, "needle": 7, "text": 8,
         "tempo": 9, "meter": 10, "time": 11, "phase": 12}


def c_bytes(hex_text):
    values = [int(b, 16) for b in hex_text.split()]
    if not values:
        raise SystemExit("an entry has no bytes")
    return "{" + ", ".join(f"0x{v:02X}" for v in values) + "}", len(values)


LOOKS = {"normal": 0, "red": 1, "white": 2}
EXPECT = ["drawn", "deck", "flags", "stale", "beat", "needle", "tempo", "phase", "time", "text_heard", "look"]


def sequences(data):
    """The sequence cases (#569) as C: each step's time and message (NULL: a tick only), and the expected state, a
    bit per expectation the case makes."""
    out = ["// Generated from vectors/messages.json by test/vectors_to_c.py --sequences. Don't edit.", ""]
    rows = []
    for case in data["sequences"]["cases"]:
        steps = ", ".join("{ %d, %s }" % (s["at_ms"], json.dumps(s["send"]) if "send" in s else "0") for s in case["steps"])
        expect = case["expect"]
        unknown = set(expect) - set(EXPECT)
        if unknown:
            raise SystemExit(f"{case['name']!r}: expectations the C walker doesn't know: {sorted(unknown)}")
        mask = sum(1 << EXPECT.index(k) for k in expect)
        def value(key):
            v = expect.get(key)
            if key == "look":
                return LOOKS[v] if v is not None else 0
            if key in ("needle",):
                return -1 if v is None else v
            if key == "time":
                return "-1, -1" if v is None else f"{v[0]}, {v[1]}"
            return int(v) if v is not None else 0
        fields = ", ".join(str(value(k)) for k in EXPECT)
        rows.append(f'    {{ {json.dumps(case["name"], ensure_ascii=True)}, {len(case["steps"])}, {{ {steps} }}, {mask}, {fields} }},')
    out += ["static const seq_case seq_cases[] = {", *rows, "};"]
    print("\n".join(out))


def main():
    data = json.load(open(sys.argv[1]))
    if "--sequences" in sys.argv:
        return sequences(data)
    out = ["// Generated from vectors/messages.json by test/vectors_to_c.py. Don't edit.", ""]
    valid, invalid = data.get("messages", []), data.get("invalid", [])
    if not valid or not invalid:
        raise SystemExit("the vectors file has no messages or no invalid entries")
    rows = []
    for m in valid:
        kind = m["kind"]
        if kind not in KINDS:
            raise SystemExit(f"unknown kind {kind!r} in {m['name']!r}")
        f = m["fields"]
        color = f.get("color", [0, 0, 0])
        body, n = c_bytes(m["bytes"])
        codes = [int(b, 16) for b in f.get("codes", "").split()]
        text = "{" + ", ".join(f"0x{c:02X}" for c in codes) + "}" if codes else "{0}"
        rows.append(f'    {{ {json.dumps(m["name"], ensure_ascii=True)}, {KINDS[kind]}, {int(m.get("direction", "host") == "unit")}, '
                    f'{f.get("version", 0)}, {f.get("number", 0)}, {{ {color[0]}, {color[1]}, {color[2]} }}, '
                    f'{f.get("player", 0)}, {f.get("flags", 0)}, {f.get("beat", 0)}, {f.get("angle", 0)}, '
                    f'{f.get("level", 0)}, {f.get("peak", 0)}, '
                    f'{f.get("field", 0)}, {len(codes)}, {text}, {f.get("tenths", 0)}, {f.get("offset", 0)}, '
                    f'{f.get("elapsed", 0)}, {f.get("length", 0)}, {n}, {body} }},')
    out += ["static const vector valid_vectors[] = {", *rows, "};", ""]
    rows = []
    for m in invalid:
        body, n = c_bytes(m["bytes"])
        rows.append(f'    {{ {json.dumps(m["name"], ensure_ascii=True)}, {int(m.get("direction", "host") == "unit")}, {n}, {body} }},')
    out += ["static const bad_vector invalid_vectors[] = {", *rows, "};"]
    print("\n".join(out))


if __name__ == "__main__":
    main()
