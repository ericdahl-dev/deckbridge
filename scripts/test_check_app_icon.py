#!/usr/bin/env python3
"""Tests for scripts/check_app_icon.py: an app's icon set has every macOS size, and the built app carries its icon (#733).
Run: python3 -I scripts/test_check_app_icon.py"""
import json, os, plistlib, struct, subprocess, sys, tempfile, unittest, zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_app_icon

SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def png(path, px):
    """A plain px-by-px PNG, enough for a size check."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"\x00\x00\x00\x00" * px for _ in range(px))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", px, px, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def iconset(root, sizes=SIZES, wrong=None):
    """An AppIcon.appiconset holding `sizes`; `wrong` = (size, scale) drawn at the wrong pixel size."""
    d = os.path.join(root, "AppIcon.appiconset")
    os.makedirs(d)
    images = []
    for size, scale in sizes:
        name = f"icon_{size}x{size}@{scale}x.png"
        png(os.path.join(d, name), size * scale // (2 if (size, scale) == wrong else 1))
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(d, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f)
    return d


class IconSetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_a_set_missing_512_at_2x_names_the_missing_size(self):
        d = iconset(self.tmp.name, sizes=SIZES[:-1])
        self.assertEqual(check_app_icon.iconset_problems(d), ["missing 512x512@2x"])

    def test_a_listed_png_not_on_disk_is_named(self):
        d = iconset(self.tmp.name)
        os.remove(os.path.join(d, "icon_32x32@1x.png"))
        self.assertEqual(check_app_icon.iconset_problems(d), ["no file icon_32x32@1x.png for 32x32@1x"])

    def test_a_png_at_the_wrong_pixel_size_is_named(self):
        d = iconset(self.tmp.name, wrong=(128, 2))
        self.assertEqual(check_app_icon.iconset_problems(d), ["icon_128x128@2x.png is 128 px, needs 256"])

    def test_a_folder_with_no_icon_set_says_so(self):
        d = os.path.join(self.tmp.name, "AppIcon.appiconset")
        self.assertEqual(check_app_icon.iconset_problems(d), [f"no icon set at {d}"])

    def test_a_full_set_has_no_problems(self):
        self.assertEqual(check_app_icon.iconset_problems(iconset(self.tmp.name)), [])


def app(root, info, resources=()):
    """A bare Name.app with this Info.plist and these empty files in Resources."""
    contents = os.path.join(root, "Name.app", "Contents")
    os.makedirs(os.path.join(contents, "Resources"))
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleName": "Name", **info}, f)
    for name in resources:
        open(os.path.join(contents, "Resources", name), "wb").close()
    return os.path.join(root, "Name.app")


class AppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_an_app_whose_info_plist_names_no_icon_fails(self):
        self.assertEqual(check_app_icon.app_problems(app(self.tmp.name, {})), ["Info.plist names no icon"])

    def test_an_app_naming_an_icon_file_it_lacks_fails(self):
        a = app(self.tmp.name, {"CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"}, ["Assets.car"])
        self.assertEqual(check_app_icon.app_problems(a), ["no Resources/AppIcon.icns"])

    def test_an_app_naming_an_icon_with_no_asset_catalog_fails(self):
        a = app(self.tmp.name, {"CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"}, ["AppIcon.icns"])
        self.assertEqual(check_app_icon.app_problems(a), ["no Resources/Assets.car"])

    def test_an_app_with_its_icon_file_and_catalog_passes(self):
        a = app(self.tmp.name, {"CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"},
                ["AppIcon.icns", "Assets.car"])
        self.assertEqual(check_app_icon.app_problems(a), [])


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_check(self, *args):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_app_icon.py")
        return subprocess.run([sys.executable, "-I", script, *args], capture_output=True, text=True)

    def test_a_problem_in_either_fails_and_is_printed(self):
        d = iconset(self.tmp.name, sizes=SIZES[1:])
        r = self.run_check("--iconset", d, "--app", app(self.tmp.name, {}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing 16x16@1x", r.stderr)
        self.assertIn("Info.plist names no icon", r.stderr)

    def test_a_full_set_and_an_app_with_its_icon_pass(self):
        a = app(self.tmp.name, {"CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon"},
                ["AppIcon.icns", "Assets.car"])
        r = self.run_check("--iconset", iconset(self.tmp.name), "--app", a)
        self.assertEqual((r.returncode, r.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()
