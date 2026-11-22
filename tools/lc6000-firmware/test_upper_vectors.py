"""The shared block B vectors (#751): synthetic blocks sealed by upper_header.py. build_upper_dfu.py must refuse the
same ones the Firmware Updater refuses, and put a sound one's exact bytes at 0x08080000, as the updater writes them.
Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import json, os, struct, unittest

import build_upper_dfu
import dfupatch

HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    with open(os.path.join(HERE, "upper_vectors.json"), encoding="utf-8") as f:
        return json.load(f)


class UpperVectorTests(unittest.TestCase):
    def test_the_kit_refuses_exactly_the_vectors_marked_refused(self):
        vectors = load()
        self.assertGreaterEqual(len(vectors["cases"]), 4)
        for case in vectors["cases"]:
            block = bytes.fromhex(case["block_hex"])
            with self.subTest(case["name"]):
                if case["refused"]:
                    with self.assertRaises(dfupatch.Refused):
                        build_upper_dfu.check_block(block)
                else:
                    build_upper_dfu.check_block(block)

    def test_a_sound_blocks_dfu_holds_its_bytes_at_the_shared_address(self):
        vectors = load()
        sound = next(c for c in vectors["cases"] if not c["refused"])
        block = bytes.fromhex(sound["block_hex"])
        data = build_upper_dfu.dfuse(block)
        # DfuSe: an 11-byte prefix, a 274-byte target prefix, then the element's address and size, then its bytes.
        address, size = struct.unpack_from("<II", data, 11 + 274)
        self.assertEqual(address, int(vectors["address"], 16))
        self.assertEqual(data[11 + 274 + 8:11 + 274 + 8 + size], block)


if __name__ == "__main__":
    unittest.main()
