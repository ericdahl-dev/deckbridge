#!/usr/bin/env python3
"""Generates the drawn display's protocol tables (#569) from vectors/messages.json's "protocol": the one description.

    python3 vectors/gen_protocol.py           writes src/protocol.h and the Kit's DrawnDisplayProtocol.swift
    python3 vectors/gen_protocol.py --check   fails if either is out of date (make test runs this)
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(FW))
C_OUT = os.path.join(FW, "src", "protocol.h")
SWIFT_OUT = os.path.join(REPO, "Packages", "ControllerBridgeKit", "Sources", "ControllerBridgeCore",
                         "DrawnDisplayProtocol.swift")
NOTE = "Generated from tools/lc6000-display-fw/vectors/messages.json by vectors/gen_protocol.py (#569). Don't edit."


def camel(name):
    head, *rest = name.split("_")
    return head + "".join(word.capitalize() for word in rest)


def hex_bytes(text):
    return [int(b, 16) for b in text.split()]


def c_header(p):
    lines = [f"// {NOTE}", "#ifndef DFW_PROTOCOL_H", "#define DFW_PROTOCOL_H", ""]
    lines.append("/// The host's header, then our command byte; the unit's replies start with the reply header.")
    lines.append("#define DFW_HEADER { " + ", ".join(f"0x{b:02X}" for b in hex_bytes(p["header"])) + " }")
    lines.append("#define DFW_REPLY_HEADER { " + ", ".join(f"0x{b:02X}" for b in hex_bytes(p["reply_header"])) + " }")
    lines.append(f"#define DFW_COMMAND 0x{p['command']:02X}")
    lines.append(f"#define DFW_PROTOCOL_VERSION {p['version']}")
    lines.append("")
    lines.append("/// Each op's number, and its one length counting the op (0: framed by len, as text is).")
    for op in p["ops"]:
        lines.append(f"#define DFW_OP_{op['name'].upper()} 0x{op['op']:02X}")
    for op in p["ops"]:
        length = 0 if op["length"] == "framed" else op["length"]
        lines.append(f"#define DFW_OP_{op['name'].upper()}_LENGTH {length}")
    lines.append("")
    for name, value in p["caps"].items():
        lines.append(f"#define DFW_{name.upper()} {value}")
    lines.append("")
    lines.append("/// The state message's flag bits.")
    for name, bit in p["flags"].items():
        lines.append(f"#define DFW_FLAG_{name.upper()} 0x{1 << bit:02X}")
    lines.append("")
    lines.append(f"#define DFW_PHASE_UNKNOWN_VALUE ({p['phase_unknown']})")
    for name, value in p["timing"].items():
        suffix = "u" if name.endswith("_ms") else ""
        lines.append(f"#define DFW_{name.upper()} {value}{suffix}")
    lines += ["", "#endif", ""]
    return "\n".join(lines)


def swift(p):
    lines = [f"// {NOTE}", "", "/// The drawn display's protocol, as vectors/messages.json describes it once.",
             "public enum DrawnDisplayProtocol {"]
    lines.append("    public enum Op: UInt8, CaseIterable, Sendable {")
    for op in p["ops"]:
        lines.append(f"        case {camel(op['name'])} = 0x{op['op']:02X}")
    lines.append("    }")
    lines.append("")
    lines.append("    /// An op's one length, counting the op; nil for text (framed by len) and for an op this version doesn't take.")
    lines.append("    public static func length(_ op: UInt8) -> Int? {")
    lines.append("        switch op {")
    for op in p["ops"]:
        if op["length"] != "framed":
            lines.append(f"        case 0x{op['op']:02X}: {op['length']}")
    lines.append("        default: nil")
    lines.append("        }")
    lines.append("    }")
    lines.append("")
    lines.append("    public static let header: [UInt8] = [" + ", ".join(f"0x{b:02X}" for b in hex_bytes(p["header"])) + "]")
    lines.append("    public static let replyHeader: [UInt8] = [" + ", ".join(f"0x{b:02X}" for b in hex_bytes(p["reply_header"])) + "]")
    lines.append(f"    public static let command = 0x{p['command']:02X}")
    lines.append(f"    public static let version = {p['version']}")
    for name, value in p["caps"].items():
        lines.append(f"    public static let {camel(name)} = {value}")
    lines.append("    /// The state message's flag bits, by name.")
    lines.append("    public static let flagBits: [String: Int] = [" + ", ".join(f'"{k}": {v}' for k, v in p["flags"].items()) + "]")
    lines.append(f"    public static let phaseUnknown = {p['phase_unknown']}")
    for name, value in p["timing"].items():
        lines.append(f"    public static let {camel(name)} = {value}")
    lines += ["}", ""]
    return "\n".join(lines)


def main():
    with open(os.path.join(HERE, "messages.json")) as f:
        p = json.load(f)["protocol"]
    outputs = {C_OUT: c_header(p), SWIFT_OUT: swift(p)}
    if "--check" in sys.argv:
        stale = [path for path, text in outputs.items() if not os.path.exists(path) or open(path).read() != text]
        for path in stale:
            print(f"out of date: {os.path.relpath(path, REPO)} (run python3 tools/lc6000-display-fw/vectors/gen_protocol.py)")
        sys.exit(1 if stale else 0)
    for path, text in outputs.items():
        with open(path, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
