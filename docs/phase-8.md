# Phase 8: static execution slot and x86-64 TCB handoff

## Goal

Phase 8 crosses the boundary from process lifecycle metadata to a real seL4
thread operation. The system description statically provisions one worker
Protection Domain and grants its TCB capability to the passive POSIX
supervisor. The supervisor can suspend that TCB, install an x86-64 user
register context, and resume it through the seL4 API.

This is deliberately a single static execution slot. It proves the TCB handoff
path without claiming dynamic TCB/CNode/VSpace creation or arbitrary Phase 5
ELF execution.

## Static resources and authority

`system/zweig.system` now provisions:

- one `process_slot` Protection Domain with its own statically assigned
  Scheduling Context;
- a shared 4 KiB status page mapped into `process_slot` and `posix_server`;
- a separate 16 KiB RW stack mapped only into `process_slot`;
- an extra TCB capability in `posix_server`'s CSpace (slot 1), targeting the
  worker; and
- a self-TCB capability in `process_slot`'s CSpace (slot 1), used only to
  self-suspend after its payload completes.

The supervisor receives no Untyped, CNode, or VSpace control capability. Its
authority is limited to the predeclared worker TCB.

## TCB handoff

The new Zweig syscall `RUN_SLOT = 5` performs the following synchronous path:

1. The worker's Microkit `init` entry writes its trusted payload entry point
   and an aligned code-page address into the shared status page.
2. The bootstrap calls `zweig_run_slot()`, which reaches the POSIX service
   using the existing protected-procedure-call channel.
3. The POSIX service validates the entry point and fixed stack range using
   `x86_64_context.build`.
4. Its C adapter converts SDF CSpace slot 1 to a CPtr, suspends the worker,
   and invokes `seL4_TCB_WriteRegisters` with the RIP, RSP, RFLAGS, and the
   remaining zeroed x86-64 register state. The invocation resumes the worker.
5. The worker enters its assembly shim on the dedicated stack, calls the
   built-in Zig payload, writes a completion marker, and self-suspends.
6. The higher-priority worker returns control to the passive supervisor, which
   checks the run counter and completion marker before replying to the caller.

The worker priority is above the POSIX supervisor, so the resumed worker
executes and parks before the protected call completes. Repeated calls install
a fresh register context into the same statically provisioned TCB.

## Context validation

`src/posix/x86_64_context.zig` builds the initial RIP/RSP/RFLAGS tuple and
rejects:

- entries outside the executable mapping or user address range;
- non-page-aligned, overflowing, or empty mappings;
- W+X code/stack mappings;
- non-readable or non-executable code;
- stacks without RW and non-executable permission; and
- unaligned or out-of-range stack pointers.

The initial RFLAGS value is `0x202` (reserved bit 1 and IF). The C adapter
writes the complete generated `seL4_UserContext` with all unspecified
registers zero.

## Validation

The unified test suite includes x86-64 context construction and negative tests
for bad code permissions, invalid RIP/RSP, W+X, and address overflow.

The QEMU smoke test now checks for
`Zweig Phase 8: seL4 TCB execution slot PASS`. That banner is emitted only
after the worker's code has run on the separately provisioned TCB and the
supervisor has observed the worker's completion marker.

## Explicit boundaries

Phase 8 does not:

- create a TCB, CNode, VSpace, Frame, or Scheduling Context dynamically;
- load Phase 5 ELF bytes into the worker's address space;
- map arbitrary ELF PT_LOAD regions or change a worker VSpace;
- give the worker its own dynamically constructed CSpace;
- provide a process-specific syscall endpoint, fault endpoint, or FD routing;
- expose working `fork`, `spawn`, or `execve` for arbitrary binaries; or
- turn multiple process records into multiple kernel TCBs.

The worker payload is built into `zweig_slot.elf`. The purpose of this phase
is to establish and test the real TCB register-write/resume operation under
Microkit's static-resource model. Dynamic object creation and ELF mapping
remain later work.
