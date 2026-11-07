# Phase 4: process-management foundation

## Goal

Phase 4 turns the Phase 2 process-record prototype into a usable, bounded
process-management policy layer for the POSIX environment. It defines process
identity, parent/child ownership, lifecycle transitions, exit status, wait and
reap behavior, and per-process descriptor state.

This is intentionally a metadata milestone. It does not claim to create
independent seL4 execution contexts yet.

## Process identity and lifecycle

`src/posix/process_manager.zig` composes the generation-checked registry in
`src/core/process.zig` with a monotonic user-visible PID namespace.

- The statically composed bootstrap task is PID 1.
- New process records receive increasing PIDs; PIDs are not recycled during
  the lifetime of the manager.
- Internal handles contain a slot and generation. Reaping invalidates the old
  handle before the slot can be reused.
- Each child records its parent handle. A parent can wait only for a direct
  child.
- State transitions are explicit: starting -> running -> exited or failed.
- `wait` returns `WouldBlock` while a child is still active, returns its exit
  status after termination, then reaps the record.
- An exited parent cannot be reaped while it still has active children; callers
  must reap descendants first.

The table is statically bounded at 32 processes. Exhaustion and duplicate
Microkit domain IDs are returned as errors rather than silently overwriting
records.

## Per-process file descriptors

Every process record owns an independent fixed-size descriptor table. The
Phase 4 `spawn` metadata operation copies the parent's descriptor entries by
value, matching the initial descriptor-inheritance model. Closing an entry in
the child does not modify the parent's descriptor table.

The bootstrap POSIX service now stores its standard descriptors in the process
manager and obtains PID 1 from the same record. The Phase 3 syscall numbers and
wire format are unchanged.

## Runtime boundary

The current Microkit system still statically composes one bootstrap client and
one passive POSIX service. The process manager's `spawn` reserves a process
record only. It does not:

- create or destroy seL4 TCB, CNode, VSpace, Frame, or Scheduling Context objects;
- install endpoint or frame capabilities into a new CSpace;
- allocate and map a private address space or build a user stack;
- load ELF segments, apply relocations, or enter a new executable;
- authenticate a caller PID over the POSIX PP channel; or
- expose `fork`, `execve`, or `waitpid` as public syscalls.

Consequently, the runtime `getpid` path still reports the single statically
composed bootstrap process. The process-manager API and tests establish the
policy contract that a later kernel-object authority service and process-aware
IPC protocol can implement.

## Validation

`make test` runs the core, POSIX ABI, descriptor, ELF load-plan, and process
manager tests. Coverage includes PID assignment, descriptor-table isolation,
wait blocking, exit status, reaping and stale-handle rejection, nested child
reaping, failed-child status, duplicate domains, and bounded capacity.

`make build` links all three Microkit Protection Domains. `make smoke-test`
boots QEMU and verifies the memory-service RPC plus the process-manager-backed
bootstrap POSIX syscall path.

The Phase 4 workflow also removes an unnecessary libc dependency from Zig's
freestanding external-symbol declarations. These functions are supplied by
the already-linked Microkit/C shim objects; they are not calls into libc.
