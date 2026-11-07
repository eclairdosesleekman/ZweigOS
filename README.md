# Zweig OS

Zweig OS is an experimental general-purpose operating system built on the seL4 microkernel, with Zig as the primary language for new user-space services.

The long-term goals are a capability-oriented system, predictable resource isolation using seL4 MCS, and a practical POSIX environment for desktop and server workloads. The project is being developed incrementally; it is not yet a POSIX-compatible or daily-driver operating system.

## Milestones

### Phase 1: bootable foundation

- seL4 on the `x86_64_generic` Microkit platform.
- A statically composed Microkit Protection Domain.
- A freestanding Zig component exporting the Microkit C ABI entry points.
- QEMU boot and debug-console smoke test.

### Phase 2: core service foundations

- Two statically composed Protection Domains connected by a Microkit protected-procedure-call channel.
- A passive Zig memory service backed by a 1 MiB, 4 KiB-page arena.
- A generation-checked contiguous page allocator and allocation/release RPC.
- Zig foundations for typed service handles, process metadata, MCS profile validation, and ELF64 validation.

Phase 2 does not yet create dynamic seL4 processes or retype Untyped memory into Frame capabilities. See [docs/phase-2.md](docs/phase-2.md) for the exact boundaries.

## Toolchain

- [seL4 Microkit 2.4.0](https://docs.sel4.systems/releases/microkit)
- [Zig 0.17.1](https://ziglang.org/download/)
- QEMU with `qemu-system-x86_64`

The Microkit SDK must include `board/x86_64_generic/debug`.

## Build and run

```sh
export MICROKIT_SDK=/path/to/microkit-sdk-2.4.0
make check
make test
make build
make run
```

The QEMU command boots the SDK's `sel4_32.elf` kernel image with the Microkit-generated `build/loader.img`. The 32-bit kernel ELF is intentional for Microkit's x86-64 QEMU boot flow; the Protection Domains are 64-bit.

Run the bounded boot and IPC assertion with:

```sh
make smoke-test
```

## Repository layout

- `src/` — Zig components, C ABI adapters, and core modules.
- `src/memory_manager/` — passive memory service.
- `src/core/` — protocol, allocator, handles, process/scheduling metadata, ELF validation, and tests.
- `system/` — Microkit system description.
- `docs/` — milestone-specific design and build notes.
- `.github/workflows/` — toolchain build and QEMU smoke tests.

The seL4 kernel is consumed as an upstream dependency through the Microkit SDK; Zweig OS does not fork or modify the kernel.
