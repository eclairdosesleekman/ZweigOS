# Phase 9: W^X staging for the static execution slot

## Goal

Phase 9 takes the real TCB handoff from Phase 8 and lets the supervisor replace
the worker's built-in payload with a caller-supplied, bounded x86-64 machine-code
image. It deliberately reuses the same statically provisioned TCB and VSpace.

The image is a flat code blob, not an ELF file. The new `EXEC_SLOT = 6` syscall
copies at most one page from the bootstrap's shared I/O buffer into the
pre-mapped executable slot, starts the worker through a small trusted assembly
shim, and returns the value left in RAX by the image.

## Static mappings and W^X policy

The Microkit system description provisions one additional 4 KiB memory region:

- `posix_server` maps the region read/write at `0x44000000` to stage bytes;
- `process_slot` maps the same physical region read/execute at
  `0x44000000`; and
- the worker's existing 16 KiB stack remains read/write and non-executable.

The supervisor has a writable alias but no executable mapping of the image.
The worker has an executable mapping but no writable mapping of the image.
The policy is per Protection Domain: the trusted supervisor is the only writer
and the worker is the only executor. No single PD receives a writable and
executable mapping of the image.

## Execution flow

1. The C veneer `zweig_exec_slot(image, length)` checks the pointer and the
   one-page size limit, then copies bytes into the existing shared I/O page.
2. The POSIX service validates the length and copies the bytes into its RW
   alias of the executable slot, clearing the unused tail of the page.
3. The service validates the worker's RX image mapping and the trusted entry
   shim / RW non-executable stack context.
4. The supervisor suspends the static worker TCB, writes the shim's RIP, stack
   pointer, and RFLAGS, and resumes it through `seL4_TCB_WriteRegisters`.
5. The shim calls the image as a normal SysV x86-64 function. The image returns
   through `ret`; the shim forwards RAX to a trusted completion routine.
6. The worker records the result and completion marker in shared state, then
   self-suspends. The POSIX service verifies the run counter and returns RAX
   to the caller.

The smoke test stages two different return-value programs (42 and 7) into the
same page and executes both on the same TCB. This checks both code staging and
replacement rather than merely re-running a built-in function.

## Tests and validation

The unit suite checks image-size boundaries and the exact encoding of a small
`mov eax, imm32; ret` payload. Existing x86-64 context tests continue to check
page alignment, executable permissions, W^X, user-address limits, overflow,
and the separate writable stack. The QEMU smoke test checks the Phase 9 PASS
banner only after both uploaded programs return their expected values.

## Explicit boundaries

Phase 9 does not:

- create TCBs, CNodes, VSpaces, Frames, or Scheduling Contexts dynamically;
- parse ELF headers, map multiple PT_LOAD segments, apply relocations, or
  construct a process-specific address space;
- load code larger than one 4 KiB page or manage multiple concurrent slots;
- provide a fault endpoint, timeout, cancellation, or recovery for a payload
  that faults or never returns; or
- provide arbitrary `execve`, `fork`, `spawn`, or per-process syscall routing.

The uploaded bytes execute with the worker PD's existing mappings and
capability environment. They must be valid x86-64 code that follows the
System V function-entry/return convention and returns with its result in RAX.
This phase is a bounded W^X staging milestone, not a general ELF loader.
