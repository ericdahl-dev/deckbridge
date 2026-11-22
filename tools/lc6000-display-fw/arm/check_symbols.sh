#!/bin/sh
# The hook's portable C (#467) builds freestanding and calls nothing outside our sources but memcpy, memmove, memset
# and memcmp. In particular no allocator: the one stock malloc goes through hook_stock.malloc, a pointer, never a
# symbol (#466). The chip-only sources (adapter.c, libc_min.c) are checked by the Arm link, which has no libc.
set -eu
out=${1:-build/freestanding-arm}
mkdir -p "$out"
bad=""
for source in arm/hook.c arm/upper.c; do
    object="$out/$(basename "$source" .c).o"
    ${CC:-cc} -std=c99 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding -fno-stack-protector -Isrc -Iarm \
        -c "$source" -o "$object"
    for symbol in $(nm -u "$object" | awk '{print $NF}' | sed 's/^_//'); do
        case "$symbol" in
            memcpy|memmove|memset|memcmp|bzero|dfw_*|upper_*) ;;
            *) bad="$bad $symbol($source)" ;;
        esac
    done
done
if [ -n "$bad" ]; then
    echo "not allowed in the hook:$bad" >&2
    exit 1
fi
echo "hook: no allocator, only memcpy, memmove, memset, memcmp, dfw_* and upper_*"
