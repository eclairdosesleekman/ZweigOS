# SPDX-License-Identifier: BSD-2-Clause

ZIG ?= zig
QEMU ?= qemu-system-x86_64

ZIG_VERSION := 0.17.1
MICROKIT_VERSION := 2.4.0
MICROKIT_BOARD ?= x86_64_generic
MICROKIT_CONFIG ?= debug
MICROKIT_SDK ?=

BUILD_DIR ?= build
BOARD_DIR := $(MICROKIT_SDK)/board/$(MICROKIT_BOARD)/$(MICROKIT_CONFIG)
MICROKIT_TOOL := $(MICROKIT_SDK)/bin/microkit
MICROKIT_LIB := $(BOARD_DIR)/lib/libmicrokit.a
MICROKIT_LINKER_SCRIPT := $(BOARD_DIR)/lib/microkit.ld
SEL4_KERNEL := $(BOARD_DIR)/elf/sel4_32.elf

APP_ELF := $(BUILD_DIR)/zweig_init.elf
SYSTEM_IMAGE := $(BUILD_DIR)/loader.img
REPORT_FILE := $(BUILD_DIR)/report.txt

QEMU_ARGS = -cpu qemu64,+fsgsbase,+pdpe1gb,+xsaveopt,+xsave \
	-m 1G \
	-display none \
	-serial stdio \
	-monitor none \
	-no-reboot \
	-no-shutdown \
	-kernel "$(SEL4_KERNEL)" \
	-initrd "$(SYSTEM_IMAGE)"

.PHONY: all check build run smoke-test clean

all: build

check:
	@command -v "$(ZIG)" >/dev/null 2>&1 || { echo "error: Zig is required (expected $(ZIG_VERSION))" >&2; exit 1; }
	@test "$$($(ZIG) version)" = "$(ZIG_VERSION)" || { echo "error: expected Zig $(ZIG_VERSION), found $$($(ZIG) version)" >&2; exit 1; }
	@test "$(MICROKIT_CONFIG)" = "debug" || { echo "error: Phase 1 requires MICROKIT_CONFIG=debug for the debug console" >&2; exit 1; }
	@test -n "$(MICROKIT_SDK)" || { echo "error: set MICROKIT_SDK to the Microkit $(MICROKIT_VERSION) SDK directory" >&2; exit 1; }
	@test -x "$(MICROKIT_TOOL)" || { echo "error: Microkit tool not found: $(MICROKIT_TOOL)" >&2; exit 1; }
	@test -f "$(MICROKIT_LIB)" || { echo "error: Microkit library not found: $(MICROKIT_LIB)" >&2; exit 1; }
	@test -f "$(MICROKIT_LINKER_SCRIPT)" || { echo "error: Microkit linker script not found: $(MICROKIT_LINKER_SCRIPT)" >&2; exit 1; }
	@test -f "$(SEL4_KERNEL)" || { echo "error: x86-64 QEMU kernel image not found: $(SEL4_KERNEL)" >&2; exit 1; }
	@"$(ZIG)" fmt --check src/init.zig

$(BUILD_DIR):
	mkdir -p "$@"

$(APP_ELF): src/init.zig Makefile | $(BUILD_DIR)
	"$(ZIG)" build-exe src/init.zig \
		-target x86_64-linux-gnu \
		-O Debug \
		-fno-entry \
		-fno-PIE \
		-fno-stack-protector \
		-L"$(BOARD_DIR)/lib" \
		-lmicrokit \
		-T"$(MICROKIT_LINKER_SCRIPT)" \
		-femit-bin="$@"

$(SYSTEM_IMAGE): system/zweig.system $(APP_ELF) | $(BUILD_DIR)
	"$(MICROKIT_TOOL)" system/zweig.system \
		--search-path "$(BUILD_DIR)" \
		--board "$(MICROKIT_BOARD)" \
		--config "$(MICROKIT_CONFIG)" \
		-o "$(SYSTEM_IMAGE)" \
		-r "$(REPORT_FILE)"

build: check $(SYSTEM_IMAGE)

run: check build
	@command -v "$(QEMU)" >/dev/null 2>&1 || { echo "error: QEMU is required ($(QEMU))" >&2; exit 1; }
	"$(QEMU)" $(QEMU_ARGS)

smoke-test: check build
	@command -v "$(QEMU)" >/dev/null 2>&1 || { echo "error: QEMU is required ($(QEMU))" >&2; exit 1; }
	@echo "Booting Zweig OS in QEMU (the VM is stopped after 10 seconds)..."
	@set +e; timeout --signal=TERM 10s "$(QEMU)" $(QEMU_ARGS) >"$(BUILD_DIR)/qemu.log" 2>&1; status=$$?; set -e; \
		cat "$(BUILD_DIR)/qemu.log"; \
		if [ "$$status" -ne 0 ] && [ "$$status" -ne 124 ]; then \
			echo "error: QEMU exited with status $$status" >&2; exit "$$status"; \
		fi; \
		grep -Fq "Hello from Zweig OS!" "$(BUILD_DIR)/qemu.log" || { \
			echo "error: expected boot banner was not found in QEMU output" >&2; exit 1; \
		}

clean:
	rm -rf "$(BUILD_DIR)"
