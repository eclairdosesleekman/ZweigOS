# Phase 3: POSIX environment foundation

## Goal

Phase 3 introduces the first syscall path visible to C code while preserving
seL4's user-space service architecture. A third Protection Domain implements
a small POSIX-facing service; the bootstrap domain calls it over a second
Microkit protected-procedure-call (PP) channel.

This milestone demonstrates the ABI boundary and a real cross-domain
`write(2)` path. It is deliberately not advertised as full POSIX compliance.

## Build and run

Pinned dependencies remain seL4 Microkit SDK 2.4.0, Zig 0.17.1, and QEMU
`qemu-system-x86_64`.

```sh
export MICROKIT_SDK=/absolute/path/to/microkit-sdk-2.4.0
make check
make test
make build
make run
# run the bounded memory + POSIX syscall smoke test
make smoke-test
```

The build now fixes a Phase 2 Makefile regression: the Zig version check must
use shell command substitution (`$$($(ZIG) version)`), not a Make variable
reference.

## Architecture

```text
zweig_init (bootstrap client PD)
  |
  | PP channel 0
  +---------------------------> memory_manager (passive PD)
  |
  | PP channel 1
  +---------------------------> posix_server (passive PD)
                                   |
                                   +-- file descriptor table
                                   +-- syscall dispatch
                                   +-- Microkit debug-console output

shared posix_io_buffer (4 KiB)
  mapped at 0x41000000 into zweig_init and posix_server
```

Both servers are passive. During each PP call they execute using the
client's donated Scheduling Context, so request execution is charged to the
caller. The bootstrap PD has priority 99 and a 1 ms budget per 10 ms period.

The shared buffer is mapped only into the bootstrap client and POSIX service.
The client copies output bytes into that page before the syscall. The server
reads the shared page; it never dereferences a pointer in the client's VSpace.

The shared page and descriptor table are single-client/single-thread scaffolding.
Before enabling multiple client threads, use per-thread buffers or add
serialization. Before enabling multiple processes, move descriptor tables
into per-process state.

## Zweig System ABI

The initial stable syscall numbers are defined in
`include/zweig/syscall.h` and `src/posix/abi.zig`:

| Number | Call | Phase 3 behavior |
| ---: | --- | --- |
| 1 | `read` | stdin returns `-EAGAIN`; other descriptors return `-EBADF` |
| 2 | `write` | fd 1/2 writes at most 4 KiB to the debug console |
| 3 | `close` | closes a known descriptor in the bootstrap table |
| 4 | `getpid` | returns the bootstrap task's static PID (1) |

The raw ABI returns a non-negative result on success and `-errno` on
failure. C veneers in `include/zweig/unistd.h` and
`src/posix/client.c` expose `zweig_read`, `zweig_write`,
`zweig_close`, and `zweig_getpid`.

These veneers are not yet the POSIX libc contract: they return raw negative
errno values and do not set thread-local `errno`. The next libc integration
step will add the musl syscall backend, TLS/errno, process/thread identity,
and the complete ABI required by the selected musl version.

## ELF64 load planning

`src/posix/load_plan.zig` takes an image accepted by the Phase 2 ELF64
validator and builds a bounded plan of up to 16 PT_LOAD segments, including
file and virtual ranges and R/W/X flags. It also defines an initial 8 MiB
stack layout with a 4 KiB guard region.

The plan is validated metadata only. Phase 3 does not retype Untyped memory
into Frame capabilities, map segments into a new VSpace, construct argc/argv
and auxv, apply relocations, or transfer control to an executable entry point.

## Validation

- `make test` runs the Phase 2 core tests and Phase 3 ABI, descriptor-table,
  and ELF load-plan tests.
- `make smoke-test` boots QEMU and requires both the Phase 2 memory-RPC
  success banner and the Phase 3 POSIX syscall success banner.
- GitHub Actions performs the same tests and emulator smoke test.

## Explicitly deferred

- Full POSIX API coverage, musl port, TLS, `errno`, and `pthread`.
- `fork`, `execve`, dynamic PID allocation, process groups, and signals.
- Filesystem-backed `open`, `stat`, directory operations, and persistent FDs.
- TTY input, terminal line discipline, `ioctl`, and real stdin reads.
- `mmap`, `brk`, demand paging, Frame-capability allocation/transfer, and
  per-process VSpace mapping.
- ELF segment mapping, relocations, shared-library loading, and execution.
- Async I/O, multiple simultaneous POSIX clients, and per-thread request buffers.

Phase 3 therefore provides the syscall transport and a small initial ABI
surface; subsequent phases must supply the process, memory, filesystem, and
libc contracts before ordinary POSIX applications can be ported.
