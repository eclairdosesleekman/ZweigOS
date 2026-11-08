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

### Phase 6: process object authority and resource planning

- Add a bounded, generation-checked authority ledger for frame regions, endpoints, notifications, TCBs, CNodes, VSpaces, Scheduling Contexts, and Untyped regions.
- Bind every root/delegated capability to a process identity and enforce type-specific rights, rights attenuation, and caller ownership.
- Support descendant revocation and safe object release only after delegated capabilities have been revoked.
- Convert Phase 5 ELF/stack mappings into an atomic per-process reservation batch for a VSpace, CNode, TCB, Scheduling Context, and frame regions.
- Validate executable-entry and writable-stack coverage, page alignment, non-overlap, W^X, scheduling profiles, and frame-page quotas before reservation.

Phase 6 adds a tested authority policy and resource plan, not dynamic seL4 object creation. The ledger does not mint capabilities, allocate CSpace slots, retype Untyped memory, map a VSpace, or start a TCB. See [docs/phase-6.md](docs/phase-6.md).

### Phase 7: transactional process lifecycle

- Coordinate Phase 4 process records, Phase 6 ELF resource plans, and the capability authority ledger through explicit prepare, commit, abort, exit, and reap transitions.
- Reserve each process's VSpace, CNode, TCB, Scheduling Context, and frame-region metadata before the process can be marked running.
- Roll back reserved capabilities when a prepared launch is aborted; make the failed process waitable by its parent.
- On reap, verify direct parent/child ownership, revoke delegated descendants, destroy every root reservation, and then remove the process record.
- Track per-resource cleanup progress so a failed teardown can be retried without re-destroying already released resources.

Phase 7 is a transactional user-space lifecycle coordinator. Committing a launch updates the process policy state only; it does not resume a seL4 TCB or execute the staged ELF. See [docs/phase-7.md](docs/phase-7.md).

### Phase 8: static execution slot and x86-64 TCB handoff

- Statically provision one worker Protection Domain with its own Scheduling Context, shared status page, and dedicated RW stack.
- Share only the worker's TCB capability with the POSIX supervisor through Microkit SDF CSpace slot 1.
- Add the `RUN_SLOT` syscall, suspend the worker, write a validated x86-64 user register context with `seL4_TCB_WriteRegisters`, and resume it.
- Run a built-in worker payload on the separate TCB, record completion in shared memory, and self-suspend for the next invocation.
- Validate RIP/RSP, mapping permissions, user address bounds, alignment, overflow, and W^X before installing the context.

Phase 8 verifies a real TCB register handoff through one statically provisioned slot. It does not create kernel objects dynamically or execute arbitrary Phase 5 ELF images. See [docs/phase-8.md](docs/phase-8.md).

### Phase 9: W^X staging for the static execution slot

- Add a one-page executable image region with a supervisor-only RW mapping and a worker-only RX mapping.
- Add the `EXEC_SLOT` syscall and `zweig_exec_slot` veneer to copy a bounded flat x86-64 image through the shared I/O page.
- Enter the staged image through a trusted assembly shim, capture its RAX return value, record completion, and self-suspend the same static worker TCB.
- Verify image bounds and replacement by executing two different payloads on the same worker TCB.

Phase 9 executes caller-supplied flat machine code in a pre-mapped slot. It does not parse ELF, create dynamic kernel objects, or build arbitrary process address spaces. See [docs/phase-9.md](docs/phase-9.md).

### Phase 10 (in progress): dynamic kernel object management foundation

- Add a bounded CSpace slot-window allocator with generation-checked leases.
- Add a conservative Untyped pool planner that requires successful parent-cap Revoke before reuse.
- Add a transactional object-manager prototype and an SDK-bound C ABI shim for Retype and CNode operations.

This is an implementation slice, **not Phase 10 completion**. The current Microkit SDF does not hand an Untyped capability to the existing memory-manager PD, so live object creation is not yet wired into the running system. See [docs/phase-10-implementation-notes.md](docs/phase-10-implementation-notes.md) for supported object kinds, remaining integration work, and validation status.

### Phase 11 (in progress): dynamic process and static ELF foundation

- Add an initial x86-64 address-space policy for the RW/NX stack, unmapped guard page, and private IPC-buffer page.
- Complete the static ELF64 initial stack with `AT_PHDR`, `AT_PHENT`, and `AT_PHNUM`; reject `PT_INTERP` and retain the `ET_EXEC`-only policy.
- Extend each process resource plan with its VSpace, CNode, TCB, MCS Scheduling Context, process syscall/fault Endpoints, IPC-buffer Frame, and ELF/stack Frame regions.
- Add a request-ID-idempotent dynamic process transaction coordinator with a typed runtime adapter, Badge-before-Resume ordering, suspend/exit, and unmap/destroy-before-reap cleanup.
- Test mock processes with independent VSpace/Frame handles and rollback after an injected mapping failure.

This is a Phase 11 foundation, **not Phase 11 completion**. The runtime adapter is currently exercised by host mocks; trusted Untyped/ASID/SchedControl handoff and real seL4 VSpace/page-table/Frame-map/MCS TCB operations are still required before dynamic ELF processes can run in QEMU. See [docs/phase-11-implementation-notes.md](docs/phase-11-implementation-notes.md).

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
- `src/posix/` — syscall service, ABI, descriptor table, process manager, ELF planning, staging, process resource planning, lifecycle coordination, and x86-64 TCB handoff.
- `src/core/` — shared IPC protocol, allocator, handles, process/scheduling metadata, ELF validation, and object authority.
- `include/zweig/` — C-facing syscall headers.
- `system/` — Microkit system description.
- `docs/` — milestone-specific design and build notes.
- `.github/workflows/` — toolchain build and QEMU smoke tests.

The seL4 kernel is consumed as an upstream dependency through the Microkit SDK; Zweig OS does not fork or modify the kernel.
