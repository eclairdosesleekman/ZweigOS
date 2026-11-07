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
MEMORY_ELF := $(BUILD_DIR)/zweig_memory.elf
POSIX_ELF := $(BUILD_DIR)/zweig_posix.elf
SYSTEM_IMAGE := $(BUILD_DIR)/loader.img
REPORT_FILE := $(BUILD_DIR)/report.txt

CLIENT_SHIM_OBJ := $(BUILD_DIR)/microkit_client_shim.o
SERVER_SHIM_OBJ := $(BUILD_DIR)/microkit_server_shim.o
POSIX_CLIENT_OBJ := $(BUILD_DIR)/posix_client.o
POSIX_SERVER_SHIM_OBJ := $(BUILD_DIR)/posix_server_shim.o

CORE_SOURCES := \
	src/core/protocol.zig \
	src/core/page_allocator.zig \
	src/core/capability.zig \
	src/core/process.zig \
	src/core/scheduling.zig \
	src/core/elf64.zig \
	src/core/tests.zig

POSIX_SOURCES := \
	src/posix/abi.zig \
	src/posix/fd_table.zig \
	src/posix/load_plan.zig \
	src/posix/process_manager.zig \
	src/posix/service.zig \
	src/posix/server.zig \
	src/posix/tests.zig

ZIG_SOURCES := src/init.zig src/memory_manager/main.zig src/tests.zig $(CORE_SOURCES) $(POSIX_SOURCES)

QEMU_ARGS = -cpu qemu64,+fsgsbase,+pdpe1gb,+xsaveopt,+xsave \
	-m 1G \
	-display none \
	-serial stdio \
	-monitor none \
	-no-reboot \
	-no-shutdown \
	-kernel "$(SEL4_KERNEL)" \
	-initrd "$(SYSTEM_IMAGE)"

.PHONY: all toolchain-check check test build run smoke-test clean

all: build

toolchain-check:
	@command -v "$(ZIG)" >/dev/null 2>&1 || { echo "error: Zig is required (expected $(ZIG_VERSION))" >&2; exit 1; }
	@test "$$($(ZIG) version)" = "$(ZIG_VERSION)" || { echo "error: expected Zig $(ZIG_VERSION), found $$($(ZIG) version)" >&2; exit 1; }
	@"$(ZIG)" fmt --check $(ZIG_SOURCES)

check: toolchain-check
	@test "$(MICROKIT_CONFIG)" = "debug" || { echo "error: Phase 4 currently requires MICROKIT_CONFIG=debug for the debug console" >&2; exit 1; }
	@test -n "$(MICROKIT_SDK)" || { echo "error: set MICROKIT_SDK to the Microkit $(MICROKIT_VERSION) SDK directory" >&2; exit 1; }
	@test -x "$(MICROKIT_TOOL)" || { echo "error: Microkit tool not found: $(MICROKIT_TOOL)" >&2; exit 1; }
	@test -f "$(MICROKIT_LIB)" || { echo "error: Microkit library not found: $(MICROKIT_LIB)" >&2; exit 1; }
	@test -f "$(MICROKIT_LINKER_SCRIPT)" || { echo "error: Microkit linker script not found: $(MICROKIT_LINKER_SCRIPT)" >&2; exit 1; }
	@test -f "$(SEL4_KERNEL)" || { echo "error: x86-64 QEMU kernel image not found: $(SEL4_KERNEL)" >&2; exit 1; }

$(BUILD_DIR)/.dir:
	mkdir -p "$(BUILD_DIR)"
	touch "$@"

$(CLIENT_SHIM_OBJ): src/microkit_client_shim.c | $(BUILD_DIR)/.dir
	"$(ZIG)" cc -target x86_64-freestanding -std=gnu11 -ffreestanding -fno-stack-protector -I"$(BOARD_DIR)/include" -c "$<" -o "$@"

$(SERVER_SHIM_OBJ): src/microkit_server_shim.c | $(BUILD_DIR)/.dir
	"$(ZIG)" cc -target x86_64-freestanding -std=gnu11 -ffreestanding -fno-stack-protector -I"$(BOARD_DIR)/include" -c "$<" -o "$@"

$(POSIX_CLIENT_OBJ): src/posix/client.c include/zweig/syscall.h include/zweig/unistd.h | $(BUILD_DIR)/.dir
	"$(ZIG)" cc -target x86_64-freestanding -std=gnu11 -ffreestanding -fno-stack-protector -Iinclude -I"$(BOARD_DIR)/include" -c "$<" -o "$@"

$(POSIX_SERVER_SHIM_OBJ): src/posix/server_shim.c | $(BUILD_DIR)/.dir
	"$(ZIG)" cc -target x86_64-freestanding -std=gnu11 -ffreestanding -fno-stack-protector -I"$(BOARD_DIR)/include" -c "$<" -o "$@"

$(APP_ELF): src/init.zig $(CORE_SOURCES) $(POSIX_SOURCES) $(CLIENT_SHIM_OBJ) $(POSIX_CLIENT_OBJ) Makefile
	"$(ZIG)" build-exe src/init.zig "$(CLIENT_SHIM_OBJ)" "$(POSIX_CLIENT_OBJ)" \
		-target x86_64-freestanding \
		-O Debug \
		-fentry=_start --force_undefined _start \
		-fno-PIE \
		-fno-stack-protector \
		-L"$(BOARD_DIR)/lib" \
		-lmicrokit \
		-T"$(MICROKIT_LINKER_SCRIPT)" \
		-femit-bin="$@"

$(MEMORY_ELF): src/memory_manager/main.zig src/core/protocol.zig src/core/page_allocator.zig $(SERVER_SHIM_OBJ) Makefile
	"$(ZIG)" build-exe src/memory_manager/main.zig "$(SERVER_SHIM_OBJ)" \
		-target x86_64-freestanding \
		-O Debug \
		-fentry=_start --force_undefined _start \
		-fno-PIE \
		-fno-stack-protector \
		-L"$(BOARD_DIR)/lib" \
		-lmicrokit \
		-T"$(MICROKIT_LINKER_SCRIPT)" \
		-femit-bin="$@"

$(POSIX_ELF): src/posix/server.zig $(POSIX_SOURCES) $(POSIX_SERVER_SHIM_OBJ) Makefile
	"$(ZIG)" build-exe src/posix/server.zig "$(POSIX_SERVER_SHIM_OBJ)" \
		-target x86_64-freestanding \
		-O Debug \
		-fentry=_start --force_undefined _start \
		-fno-PIE \
		-fno-stack-protector \
		-L"$(BOARD_DIR)/lib" \
		-lmicrokit \
		-T"$(MICROKIT_LINKER_SCRIPT)" \
		-femit-bin="$@"

$(SYSTEM_IMAGE): system/zweig.system $(APP_ELF) $(MEMORY_ELF) $(POSIX_ELF) | $(BUILD_DIR)/.dir
	"$(MICROKIT_TOOL)" system/zweig.system \
		--search-path "$(BUILD_DIR)" \
		--board "$(MICROKIT_BOARD)" \
		--config "$(MICROKIT_CONFIG)" \
		-o "$(SYSTEM_IMAGE)" \
		-r "$(REPORT_FILE)"

test: toolchain-check
	"$(ZIG)" test src/tests.zig -O Debug

build: check $(SYSTEM_IMAGE)

run: check build
	@command -v "$(QEMU)" >/dev/null 2>&1 || { echo "error: QEMU is required ($(QEMU))" >&2; exit 1; }
	"$(QEMU)" $(QEMU_ARGS)

smoke-test: check test build
	@command -v "$(QEMU)" >/dev/null 2>&1 || { echo "error: QEMU is required ($(QEMU))" >&2; exit 1; }
	@echo "Booting Zweig OS in QEMU (the VM is stopped after 10 seconds)..."
	@set +e; timeout --signal=TERM 10s "$(QEMU)" $(QEMU_ARGS) >"$(BUILD_DIR)/qemu.log" 2>&1; status=$$?; set -e; \
		cat "$(BUILD_DIR)/qemu.log"; \
		if [ "$$status" -ne 0 ] && [ "$$status" -ne 124 ]; then \
			echo "error: QEMU exited with status $$status" >&2; exit "$$status"; \
		fi; \
		grep -Fq "Zweig Phase 2: memory RPC PASS" "$(BUILD_DIR)/qemu.log" || { \
			echo "error: memory RPC smoke-test banner was not found" >&2; exit 1; \
		}; \
		grep -Fq "Zweig Phase 4: process-aware POSIX syscall PASS" "$(BUILD_DIR)/qemu.log" || { \
			echo "error: Phase 4 process-aware POSIX smoke-test banner was not found" >&2; exit 1; \
		}

clean:
	rm -rf "$(BUILD_DIR)"
