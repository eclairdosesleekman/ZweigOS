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

- Active bootstrap and passive memory-manager Protection Domains.
- A Microkit protected-procedure-call channel with Scheduling Context donation.
- A 1 MiB memory-service arena, page leases, and generation-checked allocation/release RPC.
- Zig foundations for service capabilities, process metadata, MCS profiles, and ELF64 validation.

### Phase 3: POSIX environment foundation

- A passive POSIX syscall service connected to the bootstrap task over a second PP channel.
- A shared I/O page for copying write buffers across address spaces.
- A stable Zweig syscall-number ABI and C syscall veneers for `read`, `write`, `close`, and `getpid`.
- Bootstrap standard-descriptor state and a bounded ELF64 load plan with a guarded stack layout.

Phase 3 is an initial syscall path, not full POSIX or a musl port. The current service supports console output, a bootstrap PID, descriptor validation/close, and `EAGAIN` for stdin.

### Phase 4: process-management foundation

- A bounded process table with monotonic PIDs and generation-checked internal handles.
- Parent/child relationships, starting/running/exited/failed transitions, and exit status.
- Wait/reap semantics, including descendant-before-parent cleanup.
- A distinct descriptor table per process, copied by value during metadata spawn.

Phase 4 adds process-management policy, not dynamic seL4 process creation. Its `spawn` operation reserves metadata only; TCB/CNode/VSpace/Scheduling Context creation and multi-process syscall routing are still future work. See [docs/phase-4.md](docs/phase-4.md).

### Phase 5: ELF image staging and initial process stack

- Materialize static x86-64 `ET_EXEC` `PT_LOAD` segments into a page-aligned caller-owned staging arena.
- Copy file bytes, zero BSS, and emit page-rounded mapping descriptors with R/W/X permissions.
- Reject writable-executable segments, page-level mapping collisions, kernel/non-user virtual ranges, and unsupported `ET_DYN` images.
- Construct an ABI-shaped initial stack with `argc`, `argv`, `envp`, `AT_PAGESZ`, `AT_ENTRY`, and `AT_NULL`.
- Enforce a non-mapped guard page below the stack and bounded argument/environment counts.
- Fix Zig 0.17 module-root boundaries in the Microkit server build targets.

Phase 5 stages bytes and returns a mapping manifest; it does not create seL4 Frame capabilities, map a new VSpace, perform relocations, or enter an executable. Those require the dynamic object-authority and TCB lifecycle work planned after this milestone. See [docs/phase-5.md](docs/phase-5.md).

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

Run the bounded unit tests, Microkit image build, and QEMU bootstrap smoke test with:

```sh
make smoke-test
```

## Repository layout

- `src/` — Zig components, C ABI adapters, and core modules.
- `src/memory_manager/` — passive memory service.
- `src/posix/` — syscall service, ABI, descriptor table, process manager, ELF planning and staging.
- `src/core/` — shared IPC protocol, allocator, handles, process/scheduling metadata, and ELF validation.
- `include/zweig/` — C-facing syscall headers.
- `system/` — Microkit system description.
- `docs/` — milestone-specific design and build notes.
- `.github/workflows/` — toolchain build and QEMU smoke tests.

The seL4 kernel is consumed as an upstream dependency through the Microkit SDK; Zweig OS does not fork or modify the kernel.
