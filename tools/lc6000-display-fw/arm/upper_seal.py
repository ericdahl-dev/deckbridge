#!/usr/bin/env python3
"""Seal block B (#501): fill in its header's length and CRC after the link, as upper_header.py describes them (#572).

  python3 -I arm/upper_seal.py upper.bin

Standard library only."""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))  # -I leaves this folder off sys.path
import upper_header  # noqa: E402


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, "rb") as f:
        try:
            sealed = upper_header.seal(f.read())
        except upper_header.Refused as refused:
            raise SystemExit(f"upper_seal: {refused}")
    with open(path, "wb") as f:
        f.write(sealed)
    print(f"block B: {len(sealed)} of {upper_header.LIMIT} bytes used")
