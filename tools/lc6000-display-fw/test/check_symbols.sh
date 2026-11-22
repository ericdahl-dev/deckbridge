#!/bin/sh
# The firmware sources build freestanding and need nothing from libc but the four functions GCC's freestanding mode
# expects (memcpy, memmove, memset, memcmp): no allocation, no stdio, no libm (#455). Apple clang spells memset as
# bzero. Apple clang fortifies memcpy into __memcpy_chk by default, which the Arm build never does, so fortify is
# off. Builds src/*.c without sanitizers and lists what they leave undefined between them.
set -eu
out=${1:-build/freestanding}
mkdir -p "$out"
for source in src/*.c; do
    ${CC:-cc} -std=c99 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding -fno-stack-protector -D_FORTIFY_SOURCE=0 \
        -c "$source" -o "$out/$(basename "$source" .c).o"
done
# What one of our objects needs and none of them defines.
nm "$out"/*.o | awk '$1 == "U" { print $2 } NF == 3 && $2 ~ /^[A-Z]$/ && $2 != "U" { print "+" $3 }' |
    sed 's/^\(+*\)_/\1/' | sort -u > "$out/symbols"
bad=""
for symbol in $(grep -v '^+' "$out/symbols"); do
    grep -qx "+$symbol" "$out/symbols" && continue
    case "$symbol" in
        memcpy|memmove|memset|memcmp|bzero) ;;
        *) bad="$bad $symbol" ;;
    esac
done
# The protocol reaches the drawing only through its table (#501), so it links without draw.c: the hook block can't.
for symbol in $(nm -u "$out/dfw.o" | awk '{print $NF}' | sed 's/^_//'); do
    case "$symbol" in
        dfw_draw*) bad="$bad $symbol(dfw.o)" ;;
    esac
done
if [ -n "$bad" ]; then
    echo "not allowed in firmware sources:$bad" >&2
    exit 1
fi
echo "freestanding: only memcpy, memmove, memset and memcmp"
