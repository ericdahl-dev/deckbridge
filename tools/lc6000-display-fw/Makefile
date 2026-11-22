# The drawn jog display's firmware code (#455, #457), built natively for its tests. `make test` builds and runs them.
CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -pedantic -O1 -g
SAN := -fsanitize=address,undefined -fno-omit-frame-pointer
BUILD := build
SRC := $(wildcard src/*.c)
TESTS := $(wildcard test/test_*.c)

.PHONY: test clean tables
test: $(BUILD)/tests $(BUILD)/band_table_gen $(BUILD)/ring_table_gen $(BUILD)/upper-pin
	$(BUILD)/tests
	@# Block B's header, Python's and C's pinned together (#572).
	python3 -I arm/test/test_upper_header.py $(BUILD)/upper-pin
	sh test/check_symbols.sh $(BUILD)/freestanding
	@# The protocol's tables (#569) must be what vectors/messages.json describes now.
	python3 -I vectors/gen_protocol.py --check
	@# The generated tables (#558) must be what their generators write now, byte for byte.
	$(BUILD)/band_table_gen > $(BUILD)/band_table.c
	cmp src/band_table.c $(BUILD)/band_table.c || { echo "src/band_table.c is stale: make tables" >&2; exit 1; }
	$(BUILD)/ring_table_gen > $(BUILD)/ring_table.c
	cmp src/ring_table.c $(BUILD)/ring_table.c || { echo "src/ring_table.c is stale: make tables" >&2; exit 1; }
	@# The picture's shared numbers (#571), for C and for Swift, must be what layout/layout.json says now.
	python3 -I layout/gen_layout.py layout/layout.json $(BUILD)/layout_generated.h $(BUILD)/JogLayout.generated.swift
	cmp src/layout_generated.h $(BUILD)/layout_generated.h || { echo "src/layout_generated.h is stale: make layout" >&2; exit 1; }
	cmp $(SWIFT_LAYOUT) $(BUILD)/JogLayout.generated.swift || { echo "$(SWIFT_LAYOUT) is stale: make layout" >&2; exit 1; }

# The tables B walks instead of working out geometry that never changes (#558), from the same code it ran before.
# Built for the host with the chip's float rules (no contraction into fused multiply-adds, as arm-none-eabi-gcc's
# -std=c99), so each entry is what the chip computed.
GEN_CFLAGS := -std=c99 -Wall -Wextra -Werror -pedantic -O1 -ffp-contract=off
$(BUILD)/band_table_gen: gen/band_table_gen.c src/band_geometry.h src/dfw.h
	@mkdir -p $(BUILD)
	$(CC) $(GEN_CFLAGS) -Isrc -o $@ gen/band_table_gen.c

$(BUILD)/ring_table_gen: gen/ring_table_gen.c src/ring_geometry.h src/band_geometry.h src/dfw.h
	@mkdir -p $(BUILD)
	$(CC) $(GEN_CFLAGS) -Isrc -o $@ gen/ring_table_gen.c

# The picture's shared numbers (#571): one table, layout/layout.json, for the C here and the Swift renderer.
SWIFT_LAYOUT := ../../Packages/ControllerBridgeKit/Sources/ControllerBridgeCore/JogLayout.generated.swift
.PHONY: layout
layout:
	python3 -I layout/gen_layout.py layout/layout.json src/layout_generated.h $(SWIFT_LAYOUT)

tables: $(BUILD)/band_table_gen $(BUILD)/ring_table_gen
	$(BUILD)/band_table_gen > src/band_table.c
	$(BUILD)/ring_table_gen > src/ring_table.c

# The shared message vectors (#456), as a C header for the vectors walk.
$(BUILD)/vectors.h: vectors/messages.json test/vectors_to_c.py
	@mkdir -p $(BUILD)
	python3 -I test/vectors_to_c.py $< > $@

# The sequence cases (#569), as C for the sequence walk.
$(BUILD)/sequences.h: vectors/messages.json test/vectors_to_c.py
	@mkdir -p $(BUILD)
	python3 -I test/vectors_to_c.py $< --sequences > $@

$(BUILD)/tests: $(SRC) $(TESTS) test/harness.c test/harness.h test/layer_record.c test/layer_record.h test/present.c test/present.h $(wildcard src/*.h) $(BUILD)/vectors.h $(BUILD)/sequences.h
	$(CC) $(CFLAGS) $(SAN) -Isrc -Itest -I$(BUILD) -o $@ $(SRC) $(TESTS) test/harness.c test/layer_record.c test/present.c test/view.c test/messages.c -lm

$(BUILD)/upper-pin: arm/test/upper_pin.c arm/upper.c arm/upper_build.c arm/upper.h arm/upper_build.h arm/upper_crc.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SAN) -Iarm -o $@ arm/test/upper_pin.c arm/upper.c arm/upper_build.c

clean:
	rm -rf $(BUILD)

# The hook into the stock wd image (#467): its portable logic, tested natively (`make arm-test`).
ARM_TESTS := $(wildcard arm/test/test_*.c)
.PHONY: arm-test
# The block tests' test double (#573): block A with an empty drawing table (ARM_DRAW=stub) that never reads block B
# (ARM_UPPER_PROVEN=0), so it answers the capability ask with no B. The default `make arm` is the flashed build.
arm-test: $(BUILD)/hook-tests $(BUILD)/frame-dump
	$(BUILD)/hook-tests
	sh arm/check_symbols.sh $(BUILD)/freestanding-arm
	$(MAKE) ARM_BUILD=$(BUILD)/arm-stub ARM_DRAW=stub ARM_UPPER_PROVEN=0 $(BUILD)/arm-stub/block.bin $(BUILD)/arm-stub/upper.bin
	ARM_BUILD=$(BUILD)/arm-stub $(PYTHON) -I arm/test/test_block.py

# The block tests need the `unicorn` package, as CI pins it (pip install unicorn==2.1.4):
# `make arm-test PYTHON=path/to/venv/python`. Without it the tests fail at the import; nothing is skipped.
PYTHON ?= python3

$(BUILD)/hook-tests: $(SRC) arm/hook.c arm/hook.h arm/upper.c arm/upper.h arm/upper_build.c arm/upper_build.h arm/upper_crc.h $(ARM_TESTS) test/harness.c test/harness.h $(wildcard src/*.h)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(SAN) -Isrc -Itest -Iarm -o $@ $(SRC) arm/hook.c arm/upper.c arm/upper_build.c $(ARM_TESTS) test/harness.c test/view.c

include arm/arm.mk

# The native frame for a list of messages (#515), which the block tests compare with the emulated chip's.
$(BUILD)/frame-dump: $(SRC) test/frame_dump.c test/present.c test/present.h $(wildcard src/*.h)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -Isrc -Itest -o $@ $(SRC) test/frame_dump.c test/present.c
