#!/bin/sh
# Regenerates the deck panel's fonts (#621) in src/fonts/ from the app's Geist files (App/Fonts/, OFL).
# Needs Node (npx). Run from anywhere: ./tools/deck-panel/fonts/make_fonts.sh
#
# Ranges: printable ASCII, Latin-1 Supplement, Latin Extended-A and "…", the same as lib/font_fallback: change both.
# 4 bpp, uncompressed (LVGL is built without LV_USE_FONT_COMPRESSED). Paths are relative, so the header each file
# carries names no one's home folder.
set -eu

cd "$(dirname "$0")/../../.."  # the repo root

CONV="npx --yes lv_font_conv@1.5.3"
RANGES="0x20-0x7E,0xA0-0x17F,0x2026"
# Geist has no glyph for these in the ranges; LVGL would draw a box, so each gets its base letter (source=>code
# point): soft hyphen as "-", ĔĕĬĭŎŏ without the breve, ĸ as k, Ŀŀ as Ll, ŉ as n, ſ as s.
ALIASES="0x2D=>0xAD,0x45=>0x114,0x65=>0x115,0x49=>0x12C,0x69=>0x12D,0x4F=>0x14E,0x6F=>0x14F,0x6B=>0x138,0x4C=>0x13F,0x6C=>0x140,0x6E=>0x149,0x73=>0x17F"
# Geist Mono also lacks Ĳĳ: I and i.
MONO_ALIASES="$ALIASES,0x49=>0x132,0x69=>0x133"
OUT=tools/deck-panel/src/fonts

# font file, size, LVGL name, aliases
make_font() {
    $CONV --font "App/Fonts/$1" -r "$RANGES" -r "$4" --size "$2" --bpp 4 --no-compress \
        --format lvgl --lv-include lvgl.h --lv-font-name "$3" -o "$OUT/$3.c"
}

make_font Geist-SemiBold.ttf      36 geist_semibold_36      "$ALIASES"       # title, waiting headline
make_font Geist-Regular.ttf       24 geist_regular_24       "$ALIASES"       # artist, names, lamps, waiting detail
make_font GeistMono-Medium.ttf    32 geist_mono_medium_32   "$MONO_ALIASES"  # key, BPM, tempo
make_font GeistMono-SemiBold.ttf  64 geist_mono_semibold_64 "$MONO_ALIASES"  # deck number, elapsed, remaining

cp App/Fonts/Geist-OFL.txt "$OUT/Geist-OFL.txt"
