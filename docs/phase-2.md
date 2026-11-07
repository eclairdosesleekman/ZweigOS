# Phase 2: core service foundations

## Goal

Phase 2 moves beyond the single-domain banner from Phase 1 and establishes a
small multi-domain system:

- a normal client Protection Domain;
- a passive memory-service Protection Domain;
- a Microkit protected-procedure-call (PP) channel between them;
- a 1 MiB, 4 KiB-page arena mapped only into the memory service;
- a contiguous page-run allocator with generation-checked lease tokens;
- typed service handles, process metadata, MCS profile validation, and ELF64
  image validation in Zig.

The QEMU smoke test makes a real RPC round trip: reserve four pages, query the
remaining page count, release the lease, and verify that the full arena is
available again.

## Build and run

The Phase 1 dependencies remain pinned:

- seL4 Microkit SDK 2.4.0, `x86_64_generic/debug`
- Zig 0.17.1
- QEMU `qemu-system-x86_64`

```sh
export MICROKIT_SDK=/absolute/path/to/microkit-sdk-2.4.0
make check
make test
make build
make run
# or run a bounded QEMU boot assertion:
make smoke-test
```

## Runtime architecture

```text
           zweig_init (active client PD)
           priority 99, budget 1 ms / 10 ms
                      |
                      | Microkit PP channel 0
                      | Scheduling Context donation
                      v
        memory_manager (passive server PD)
             priority 100, passive
                      |
                      v
             memory_pool (1 MiB)
             mapped at 0x40000000
             only in memory_manager
```

The client endpoint is statically installed by the Microkit system description.
The client-side Zig `capability.Table` is a least-privilege policy wrapper for
that installed endpoint: it grants this component the right to call the memory
service. It is not a CSpace allocator and does not mint, copy, or revoke kernel
capabilities.

The PP message uses a stable operation label and one request word. The C
adapter translates Microkit's `MessageInfo` and message-register API into a
fixed-width C ABI; service policy and allocation logic remain in Zig. The
server returns a two-word reply containing a status code and a 64-bit value.

## Memory arena

The memory service owns a 1 MiB Microkit memory region, divided into 256
4 KiB pages. Microkit does not guarantee that an automatically placed memory
region is physically contiguous; this allocator manages contiguous runs in
the region's virtual mapping only. Its Zig allocator:

- finds contiguous free page runs;
- zeros pages before leasing them;
- returns opaque 64-bit lease tokens;
- rejects stale or duplicate releases using a generation counter;
- reports free-page counts.

The region is mapped only into the memory-manager PD. The client receives a
lease token, not a pointer to the arena. This is an initial service-owned arena
allocator, **not yet a general-purpose physical-memory manager**: Phase 2 does
not retype Untyped memory into Frame capabilities, transfer those capabilities,
or map client-owned pages into another VSpace. Those steps require an explicit
seL4 object-allocation and CSpace authority design and are deferred.

## Other Zig core modules

| Module | Responsibility | Current boundary |
| --- | --- | --- |
| `protocol.zig` | fixed-width RPC operation and status IDs | one-word requests / two-word replies |
| `capability.zig` | typed service-handle table and rights checks | wraps statically installed Microkit channels |
| `process.zig` | generation-checked process metadata | does not create/destroy TCBs |
| `scheduling.zig` | validates priority, budget, and period | Microkit creates Scheduling Contexts at composition time |
| `elf64.zig` | validates ELF64 little-endian x86-64 headers and PT_LOAD ranges | does not map segments or start a thread |
| `page_allocator.zig` | contiguous 4 KiB arena page allocator | manages only the mapped service arena |

Run the native unit tests with `make test`.

## MCS behavior

The client PD is assigned a 1,000 microsecond budget over a 10,000
microsecond period. The memory server is passive; for PP calls, it executes
using the caller's donated Scheduling Context. This makes request execution
accountable to the client budget. It does not, by itself, establish a hard
real-time guarantee.

## Explicitly deferred

- dynamic process creation, TCB/CSpace/VSpace creation and teardown;
- runtime Untyped retype into seL4 Frame, Endpoint, TCB, and Scheduling Context
  objects;
- page-capability transfer and demand mapping into client address spaces;
- ELF PT_LOAD mapping, relocations, dynamic linking, and entry-point startup;
- pthreads, POSIX syscalls, musl, VFS, networking, and device drivers;
- fault recovery and service restart supervision.

Those require runtime object authority and lifecycle mechanisms beyond the
static Protection Domains and channels introduced here.
