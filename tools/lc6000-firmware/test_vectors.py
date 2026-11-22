"""The shared patch vectors (#693): synthetic images, the patch to apply, and the SHA-256 of the patched image as
dfupatch makes it. The Firmware Updater's Swift port is tested against the same file, so the two must agree.
Synthetic only: no vendor bytes. Run from the repo root: python3 -I -m unittest discover tools/lc6000-firmware"""
import hashlib, json, os, struct, unittest

import dfupatch
from test_dfupatch import dfuse_file

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 0x08008000


def element(recipe):
    """The synthetic image a recipe describes: a repeated fill, planted bytes, then the chip's trailer."""
    size = int(recipe["size"], 16)
    fill = bytes.fromhex(recipe["fill"])
    body = bytearray((fill * (size // len(fill) + 1))[:size])
    for plant in recipe.get("plant", []):
        at = int(plant["at"], 16) - BASE
        raw = bytes.fromhex(plant["hex"])
        body[at:at + len(raw)] = raw
    if recipe["chip"] == "wd":
        covered = size - 20
        struct.pack_into("<4sII", body, size - 32, b"\x00\x00\x05\x00", 0xDEADBEEF, covered)
        struct.pack_into("<I", body, covered, dfupatch.stm32_crc(bytes(body[:covered])))
    body[size - 16:] = b"EndOfFlashToken\x00"
    return bytes(body)


def patch_text(recipe):
    if "patch_file" in recipe:
        with open(os.path.join(HERE, recipe["patch_file"]), encoding="utf-8") as f:
            return f.read()
    return recipe["patch"]


def load():
    with open(os.path.join(HERE, "vectors.json"), encoding="utf-8") as f:
        return json.load(f)


class VectorTests(unittest.TestCase):
    def test_each_vector_is_dfupatchs_output(self):
        vectors = load()
        self.assertGreaterEqual(len(vectors), 4)
        for recipe in vectors:
            with self.subTest(recipe["name"]):
                data = dfuse_file(element(recipe))
                if recipe["sha256"] is None:
                    with self.assertRaises(dfupatch.Refused):
                        dfupatch.patch(data, patch_text(recipe))
                    continue
                out = dfupatch.parse(dfupatch.patch(data, patch_text(recipe))).element
                self.assertEqual(hashlib.sha256(out).hexdigest(), recipe["sha256"])

    def test_the_catalog_patches_each_have_a_vector(self):
        files = {r.get("patch_file") for r in load()}
        self.assertIn("patches/wd-00.50-show-slot-16.patch", files)
        self.assertIn("patches/tp-00.31-no-deck-select-on-hello.patch", files)


if __name__ == "__main__":
    unittest.main()
