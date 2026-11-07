# Zweig OS

Zweig OS is an experimental general-purpose operating system built on the seL4 microkernel, with Zig as the primary language for new user-space services.

The long-term goals are a capability-oriented system, predictable resource isolation using seL4 MCS, and a practical POSIX environment for desktop and server workloads. The project is being developed incrementally; it is not yet a POSIX-compatible or daily-driver operating system.

## Phase 1: bootable foundation

Phase 1 establishes the smallest native execution path:

- seL4 on the `x86_64_generic` Microkit platform.
- A statically composed Microkit Protection Domain.
- A freestanding Zig program exporting the Microkit C ABI entry points.
- A reproducible QEMU boot and serial debug-console smoke test.

The initial Protection Domain is assigned a 1 ms budget per 10 ms period. This demonstrates the MCS configuration surface; it is not a claim of a verified real-time system.

## Toolchain

The initial toolchain is pinned to:

- [seL4 Microkit 2.4.0](https://docs.sel4.systems/releases/microkit)
- [Zig 0.17.1](https://ziglang.org/download/)
- QEMU with `qemu-system-x86_64`

The Microkit SDK must include `board/x86_64_generic/debug`.

## Build and run

Set `MICROKIT_SDK` to the extracted Microkit SDK directory, then run:

```sh
export MICROKIT_SDK=/path/to/microkit-sdk-2.4.0
make check
make build
make run
```

The QEMU command boots the SDK's `sel4_32.elf` kernel image with the Microkit-generated `build/loader.img`. The 32-bit kernel ELF is intentional: Microkit's x86-64 QEMU boot flow uses this image while the Protection Domain itself is 64-bit.

A successful boot prints `Hello from Zweig OS!` to the Microkit debug console. The debug configuration is used because this first milestone uses `microkit_dbg_puts` as a bring-up console; it is not yet a general-purpose UART driver.

Run the automated boot check with:

```sh
make smoke-test
```

## Repository layout

- `src/` — Zig Protection Domain code.
- `system/` — Microkit system description.
- `docs/` — milestone-specific design and build notes.
- `.github/workflows/` — pinned-toolchain build and QEMU smoke test.

See [docs/phase-1.md](docs/phase-1.md) for implementation details and current limitations.

## Scope and status

This repository currently contains the Phase 1 bring-up only. It does not yet implement dynamic processes, virtual memory management, a POSIX syscall layer, libc, filesystems, networking, or a desktop environment. Those belong to later milestones and will be introduced as separate, testable components.

The seL4 kernel is consumed as an upstream dependency through the Microkit SDK; Zweig OS does not fork or modify the kernel in this phase.
