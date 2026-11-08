# Phase 11 implementation notes

## Status

**Implementation foundation only — Phase 11 acceptance is not complete.**

This PR adds the policy, staging, resource-plan, and runtime-transaction interfaces for dynamic static-ELF processes. It does not yet create a real independent seL4 VSpace/ASID or bind a real MCS Scheduling Context to a dynamically created TCB in QEMU.

## Implemented in this slice

### ELF validation and initial stack

- Retain ELF program-header table metadata in the pure load plan.
- Reject `PT_INTERP` and `ET_DYN`; support remains static ELF64 `ET_EXEC` for x86-64.
- Copy each `PT_LOAD` file image into the page-aligned staging arena and zero the rest of the mapping, including BSS.
- Copy the program-header table into the initial process stack and publish `AT_PHDR`, `AT_PHENT`, and `AT_PHNUM` alongside `AT_PAGESZ`, `AT_ENTRY`, and `AT_NULL`.
- Preserve bounded `argv` and `envp` vectors and 16-byte initial stack alignment.

The staging arena is still only a source of bytes. It is not a process VSpace and is never returned as a CPtr or treated as a mapped Frame.

### Address-space policy

`src/posix/address_space.zig` centralizes the initial 4 KiB x86-64 layout and validates page alignment, canonical user range, range overflow, permissions, W+X, and mapping overlap.

The initial policy reserves a downward-growing RW/NX stack, an unmapped guard page, and a private IPC-buffer page below the guard with a separating page. The process resource planner verifies that ELF/stack mappings do not collide with those reservations.

### Per-process resource plan

Each plan reserves metadata for:

1. VSpace root;
2. CNode;
3. TCB;
4. MCS Scheduling Context;
5. process syscall Endpoint;
6. Fault Endpoint;
7. private IPC-buffer Frame;
8. one Frame-region request for each staged ELF/stack mapping.

The fixed seven requests plus at most 17 image mappings fit the common 24-entry atomic Authority Ledger batch. Frame-page quotas include the IPC-buffer page. The CSpace entries remain Zweig handles and rights records, not exported CPtrs.

### Dynamic process transaction coordinator

`src/posix/dynamic_process.zig` composes the existing Process Manager, Phase 7 lifecycle coordinator, Authority Ledger, ELF loader, and resource planner through a typed `RuntimeOps` boundary.

Spawn order is:

1. validate parent, request ID, ELF image, stack, and resource plan;
2. allocate generation-checked process metadata and reserve the Authority Ledger batch;
3. ask the runtime adapter to materialize the process objects;
4. map each staged Frame and the private IPC buffer;
5. configure CSpace/VSpace, fault endpoint, MCS scheduling context, and initial registers;
6. publish the process-specific Endpoint Badge;
7. commit process state and Resume the TCB.

The adapter must make materialization all-or-nothing. Cleanup unpublishes the Badge, unmaps all ELF/stack/IPC Frames, destroys kernel objects, and only then releases the Authority Ledger reservations. The process manager records request IDs with an input digest so duplicate requests are idempotent and conflicting reuse is rejected.

Exit suspends the TCB and revokes the Badge. Reap unmaps/destroys the runtime resources before the lifecycle coordinator releases capability metadata and removes the child record. If unmap or destroy fails, cleanup progress is retained for retry.

## Validation coverage

The host tests cover:

- address-space overflow, W+X, collision, and guard/IPC layout;
- complete initial stack and auxiliary-vector metadata;
- rejection of `ET_DYN` and `PT_INTERP`;
- atomic resource planning including IPC/fault/syscall resources;
- two mock processes with distinct VSpace handles and distinct Frame handles at the same virtual address;
- request-ID replay and conflicting reuse;
- rollback after an injected Frame-mapping failure;
- process exit, wait/reap, and Authority Ledger cleanup.

Existing QEMU smoke tests continue to exercise the static Phase 2/4/8/9 system. They are regression coverage only; this slice does not emit `Zweig Phase 11: dynamic ELF process PASS`.

## Required follow-up before Phase 11 acceptance

The current system description and Phase 10 runtime do not yet provide the actual runtime authority and kernel mechanisms needed by `RuntimeOps`. In particular, a trusted bootstrap must hand a dedicated Resource Manager only bounded Untyped, ASIDControl/ASIDPool, SchedControl, and required CNode authority. The seL4 backend still needs SDK-verified operations for:

- VSpace root, ASID pool, and x86-64 page-table object creation;
- Frame map/unmap with per-page R/W/X enforcement and complete teardown;
- MCS Scheduling Context configure/bind/unbind;
- MCS TCB CSpace/VSpace/IPC-buffer/fault-endpoint configuration, register write, suspend, and resume;
- safe capability delegation and revocation connected to the actual CSpace locations and Authority Ledger.

After that integration, add the QEMU `process` profile that starts at least two real static ELF binaries in independent VSpaces, verifies same-VA/different-Frame isolation and permissions, validates argv/envp/auxv and exit status, injects a process fault without stopping its peer, and confirms all objects are reclaimed after wait/reap. Only that live integration test may emit the Phase 11 PASS banner.
