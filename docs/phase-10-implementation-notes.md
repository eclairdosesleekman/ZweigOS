# Phase 10 implementation notes

## Status

**Implementation slice only — Phase 10 is not complete.**

This change adds the first reusable policy and C ABI layers for dynamic kernel-object management. It does not yet expose Untyped authority to a running Zweig Protection Domain, configure a new TCB/VSpace, or prove live kernel-object allocation under QEMU.

The scope follows the Phase 10 design: keep the existing Object Authority policy separate from the kernel backend, reserve resources before invoking the kernel, and quarantine resources when rollback cannot be proven safe.

## Added modules

### CSpace slot allocator

\`src/kernel/cspace_allocator.zig\` adds a bounded, contiguous slot-window allocator with:

- owner-checked leases and monotonically changing lease generations;
- all-or-nothing reservation of contiguous slots;
- explicit \`reserved\`, \`installed\`, \`deleted\`, and \`quarantined\` states;
- CPtr calculation local to the configured CSpace;
- release only for unused reservations or slots whose cap deletion has succeeded.

It deliberately does not discover free slots from the kernel or create a new CSpace. The caller must configure a window known to be empty and owned by the manager.

### Untyped pool planner

\`src/kernel/untyped_pool.zig\` registers Untyped roots supplied by trusted bootstrap code. It validates physical alignment and size arithmetic, distinguishes normal from device memory, and permits only Frame allocation from device Untyped memory.

A root has at most one active lease. It is not returned to the free pool after child-cap deletion alone. The caller must first successfully invoke \`CNode_Revoke\` on the parent Untyped capability and then call \`confirmRevokedAndReclaim\`. If the kernel state is uncertain, the root can be quarantined permanently.

This is conservative by design: it avoids pretending that an Untyped watermark can be reset by freeing metadata.

### Object manager

\`src/kernel/object_manager.zig\` composes the two allocators with an injectable \`KernelOps\` backend.

The initial supported batch kinds are:

- 4 KiB x86 Frame;
- Endpoint;
- Notification;
- TCB;
- CNode (variable radix).

For each homogeneous batch, the manager validates the object layout, reserves destination slots and Untyped capacity, calls Retype, and publishes a generation-checked object handle only after success.

Destroy is retryable. The manager records progress after each successful per-object Revoke and Delete. It then revokes the parent Untyped cap, confirms reclamation, and releases the destination slots. Failed rollback or uncertain cleanup quarantines both the Untyped root and affected slots.

The host tests use a mock backend. They cover repeated create/destroy, successful rollback after a Retype error, quarantine after rollback failure, and retry after a partial Delete failure.

### seL4 C ABI backend

- \`include/zweig/kernel.h\` defines the internal C ABI and fixed object-kind / rights-bit values.
- \`src/kernel/sel4_shim.c\` adapts the selected SDK's libsel4 headers for object layout, Untyped Retype, CNode Copy/Mint/Revoke/Delete.
- \`src/kernel/sel4_backend.zig\` adapts those calls to \`KernelOps\` and provides CSpace-local path helpers for Copy/Mint.

The C shim deliberately contains no allocation policy. Rights attenuation is checked in Zig before Copy/Mint; seL4 remains the final authority and may reject the invocation.

## Important integration blocker: Untyped handoff

The current Microkit system description does not give the existing memory-manager PD an Untyped capability.

In Microkit's static SDF model, a \`memory_region\` represents memory that has already been allocated and is mapped as a Frame into PDs. It is not an Untyped capability that the PD can Retype. The current SDF CSpace grant elements provision selected TCB/SC/VSpace capabilities; they do not express an arbitrary Untyped-capability grant to a Protection Domain.

The Untyped capabilities used to compose the initial static system are held by the trusted initial-task/capDL setup path. They are not automatically available to an ordinary Microkit PD through the current \`system/zweig.system\`.

Therefore:

1. This PR does **not** add a fake Untyped CPtr or reinterpret the existing \`memory_pool\` Frame mapping as Untyped memory.
2. \`Pool.registerRoot\` accepts only an explicit cap CPtr and physical extent supplied by trusted bootstrap code.
3. The new ObjectManager is not called from the current POSIX or memory-manager runtime.
4. The new C ABI object file is compiled into the memory-manager ELF to check the selected SDK headers, but no live Retype invocation is made during the existing smoke test.

Before live QEMU allocation can be enabled, a separate bootstrap integration task must deliver a deliberately selected normal-memory Untyped capability to a manager-owned CSpace slot and provide its physical base/size metadata. This likely requires extending the Microkit capDL/loader initialisation path or introducing a controlled initial-task handoff. That work must preserve the existing Microkit-managed slots and must not expose root CNode authority or all Untyped memory to the POSIX server.

## Not implemented in this slice

The following remain necessary for Phase 10 acceptance:

- Untyped capability handoff and registration from the real bootstrap path;
- a dedicated Resource Manager PD and authenticated RPC protocol;
- high-level cross-CSpace delegation integrated with the Phase 6 Authority Ledger;
- dynamic TCB configuration (CSpace root, VSpace root, IPC buffer, Fault Endpoint, registers);
- MCS Scheduling Context creation/configuration/bind/unbind and Reply Object management;
- x86-64 VSpace root, ASID-pool, page-table, and Frame mapping operations;
- safe TCB quiesce/suspend and SC unbind before TCB destruction;
- live QEMU tests for Frame/Endpoint/Notification/CNode/TCB Retype, denied authority, revoke, and reclamation.

The current low-level object layout supports only the five kinds listed above. Scheduling Context, Reply Object, ASID pool, VSpace root, page tables, and device IRQ/DMA delegation are intentionally not guessed from generic object sizes; their APIs depend on the selected kernel configuration and need a separate SDK-verified change.

## Build and tests

The Makefile now includes the new Zig kernel modules in \`zig fmt --check\` and the unified host test root. It also compiles \`src/kernel/sel4_shim.c\` against the configured Microkit SDK headers and links the object into the memory-manager ELF.

The expected local validation commands remain:

\`\`\`sh
make check
make test
make build
make smoke-test
\`\`\`

They were **not run while preparing this change** because the current execution environment does not contain Zig 0.17.1, the Microkit 2.4.0 SDK, or QEMU. The existing QEMU smoke test remains a Phase 2/4/8/9 regression test; no Phase 10 PASS banner is emitted by this implementation slice.

## Next implementation steps

1. Design and implement an explicit Microkit bootstrap/capDL Untyped-cap handoff, including reserved CSpace slot ranges and a trusted extent manifest.
2. Add a Resource Manager service entry point that registers only those handed-off caps and accepts bounded resource-plan RPCs.
3. Add QEMU integration tests that actually Retype and Revoke one normal-memory Frame, then Endpoint/Notification objects, and verify slot and Untyped reuse.
4. Add verified TCB configuration and MCS Scheduling Context / Reply Object support against the exact Microkit 2.4.0 headers and kernel configuration.
5. Connect Capability Copy/Mint/Revoke operations to the Phase 6 Authority Ledger and test cross-CSpace rights attenuation.
6. Expand to x86-64 page tables, VSpace/ASID handling, and Frame mapping before claiming dynamic process creation.
