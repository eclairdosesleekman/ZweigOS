# Phase 6: process object authority and resource planning

## Goal

Phase 6 defines the policy boundary between a process record and the kernel
objects that a future runtime process manager will need. It consumes the
Phase 5 ELF mapping manifest and turns it into a bounded resource reservation
plan. A separate authority ledger controls which process identity may use or
delegate each reserved object.

This is a user-space authority model, not a dynamic seL4 object allocator.

## Object authority ledger

`src/core/object_authority.zig` implements a fixed-capacity table with:

- 64 object reservations and 128 capability records;
- generation-checked object and capability IDs;
- process-bound capability holders;
- object-specific rights for frame regions, endpoints, notifications, TCBs,
  CNodes, VSpaces, Scheduling Contexts, and Untyped regions;
- rights attenuation on delegation; and
- descendant revocation followed by explicit object release.

A `reserveBatch` request is validated in full and capacity is checked before
any table slot is changed. This makes a process's resource reservation
all-or-nothing at the metadata layer.

A delegated capability refers to the same object reservation as its parent.
Its rights must be a subset of the parent's rights, and its recorded holder
must match the process identity supplied to `lookup`, `grant`, or
`revokeDescendants`. Revocation walks the bounded delegation tree, invalidates
all descendants, and leaves the supplied parent capability intact. The owner
can destroy an object only through its root capability and only after all
delegated capabilities have been revoked.

The `frame_region` object kind preserves the Phase 5 mapping's virtual
address, staging-arena offset, page count, and R/W/X flags. W+X frame regions
are rejected.

## Process resource plan

`src/posix/process_resources.zig` validates one `image_loader.LoadedImage`
and emits an atomic batch containing:

1. one VSpace reservation;
2. one CNode reservation;
3. one TCB reservation;
4. one Scheduling Context reservation; and
5. one frame-region reservation per ELF or initial-stack mapping.

Before producing the batch, the planner checks that mappings are page-aligned,
inside the user address range, non-overlapping, and non-W+X. It verifies that
the ELF entry point lies in an executable mapping, the initial stack pointer
lies in a writable non-executable mapping, and the total staged frame pages fit
the supplied quota. The MCS Scheduling Context profile is validated by the
existing scheduling policy module.

Calling `Plan.reserve` sends the request list to the authority table's atomic
batch reservation method. It returns reservation and root-capability handles
for subsequent object-service work.

## Runtime boundary

Phase 6 does not:

- mint real seL4 capabilities or allocate CSpace slots;
- retype Untyped memory into Frame, TCB, CNode, VSpace, or Scheduling Context
  kernel objects;
- map the staged frame regions into a VSpace;
- install a TCB register context or start execution at the ELF entry point;
- create a process-owned CSpace in the kernel;
- add multi-process caller authentication to the POSIX PP channel; or
- expose `spawn`/`execve` as working process-creation syscalls.

The object and capability tables are bounded policy metadata. The reservation
batch is therefore not proof that the corresponding kernel objects exist.
Dynamic object creation, CSpace construction, VSpace mapping, TCB setup, and
safe teardown remain follow-on runtime integration work.

## Validation

The unified `make test` suite covers object-kind rights, owner isolation,
rights attenuation, multi-level delegation, descendant revocation, stale
generation rejection, release ordering, atomic batch failure, and W+X
rejection. Process-resource tests verify the object request set produced from
ELF and stack mappings, successful atomic reservation, entry/stack coverage,
mapping overlap, W+X, scheduling profile validity, and page quotas.

The Phase 6 GitHub Actions workflow runs Zig formatting, the full unit test
suite, all three Microkit Protection Domain builds, Microkit system
composition, and the existing QEMU bootstrap smoke test. The QEMU smoke test
continues to validate the existing static bootstrap; it does not execute a
dynamically staged user ELF image.
