#!/usr/bin/env python3
"""No print or log call in the panel's board code takes a password (#622): the home Wi-Fi's password and the setup
network's must never reach serial. Finds Serial.print/println/printf/write, log_x and ESP_LOGx calls whose
arguments, strings and comments aside, name anything with "password" in it.
Run: python3 -I tools/deck-panel/check_secret_logs.py   (exits 1 and lists file:line on a hit)
Tested by test_secret_logs.py."""
import os, re, sys

CALL = re.compile(r"\b(?:Serial\.(?:print|println|printf|write)|log_[a-z]|ESP_LOG[A-Z])\s*\(")
SECRET = re.compile(r"password", re.IGNORECASE)


def strip(code):
    """Blanks string and char literals and comments, keeping newlines so line numbers hold."""
    out, i, n = [], 0, len(code)
    while i < n:
        c = code[i]
        if code.startswith("//", i):
            j = code.find("\n", i)
            i = n if j < 0 else j
        elif code.startswith("/*", i):
            j = code.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * code.count("\n", i, j))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            out.append(" ")
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def find(source):
    """Line numbers (1-based) of calls that take a password."""
    code = strip(source)
    hits = []
    for m in CALL.finditer(code):
        depth, j = 1, m.end()
        while j < len(code) and depth:
            depth += {"(": 1, ")": -1}.get(code[j], 0)
            j += 1
        if SECRET.search(code[m.end():j]):
            hits.append(code.count("\n", 0, m.start()) + 1)
    return hits


def check(directory):
    """(path, line) for every hit under directory."""
    hits = []
    for root, _, files in os.walk(directory):
        for name in sorted(files):
            if name.endswith((".c", ".cpp", ".h")):
                path = os.path.join(root, name)
                with open(path, encoding="utf-8", errors="replace") as f:
                    hits += [(path, line) for line in find(f.read())]
    return hits


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    found = check(os.path.join(here, "src"))
    for path, line in found:
        print("%s:%d: a print or log call takes a password" % (os.path.relpath(path, here), line))
    sys.exit(1 if found else 0)
