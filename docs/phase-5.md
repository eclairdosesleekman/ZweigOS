# Phase 5: ELF image staging and initial process stack

## Goal

Phase 5 advances the Phase 3 ELF load planner from metadata-only output to
byte-level image staging. A caller supplies the executable bytes and a
page-aligned backing arena. The loader validates the ELF header, copies the
static loadable segments, clears each segment's BSS tail, reserves a stack, and
returns a mapping manifest suitable for a later seL4 object-authority service.

This phase does not create a runnable seL4 process. It deliberately separates
image correctness and initial-stack construction from privileged kernel-object
operations.

## Supported executable format

The loader accepts little-endian x86-64 ELF64 static `ET_EXEC` images with
validated `PT_LOAD` segments. It rejects:

- `ET_DYN`, until load-bias selection and relocation support exist;
- writable-and-executable segments (W^X);
- virtual ranges outside the lower user address space;
- byte ranges which do not fit the supplied ELF file or overflow address math;
- distinct segments whose page-rounded mappings collide; and
- any loadable range which overlaps the initial stack or its guard page.

For each accepted segment, the loader rounds the virtual interval outward to
4 KiB page boundaries and allocates the same number of zeroed bytes from the
staging arena. File contents are copied to the correct in-page offset. The
remaining `p_memsz - p_filesz` bytes remain zero as required for BSS.

The returned mapping record contains the virtual base, byte length, arena
backing offset, and readable/writable/executable flags. Mapping records are
data for a later authority component; they are not Frame capabilities and do
not install page tables.

## Initial stack

The stack is a separate read/write, non-executable mapping. Its size and top
are caller-configurable but must be page-aligned and within the lower user
address range. One page immediately below the stack is omitted from the
mapping manifest as a guard page.

The loader copies bounded argument and environment strings into the stack and
builds this x86-64 entry layout:

- `argc`;
- `argv[]`, followed by a null pointer;
- `envp[]`, followed by a null pointer; and
- auxiliary vector entries `AT_PAGESZ`, `AT_ENTRY`, and `AT_NULL`.

The returned initial stack pointer is 16-byte aligned. The tests read the
materialized stack words back from the staging arena to verify pointer arrays,
terminators, auxiliary values, and string contents.

## API

`src/posix/image_loader.zig` exposes:

- `load(image, arena, options)`: validates and materializes an image;
- `LoadedImage.entry` and `LoadedImage.stack_pointer`: entry state for a
  future TCB context;
- `LoadedImage.mappings`: bounded array of virtual-to-arena mapping records;
- `LoadedImage.stack_guard_bottom`: the unmapped guard-page base.

The implementation uses fixed-capacity mapping, argv, and envp metadata. It
performs no dynamic allocation.

## Build integration

All loader tests run under `make test`. The Microkit build targets now use
small source-root wrappers for the memory-manager and POSIX Protection
Domains. These keep their relative imports inside the common `src/` Zig
module root, addressing the Phase 4 CI failure where the direct
`src/memory_manager/main.zig` root tried to import `../core` outside its
module path.

## Runtime boundary

Phase 5 does not:

- create or retype Untyped memory into seL4 Frame capabilities;
- map the returned backing offsets into a new VSpace;
- apply `R_X86_64_RELATIVE` or other dynamic relocations;
- create a TCB, CNode, VSpace, or Scheduling Context;
- populate a process CSpace or authenticate a process over the syscall IPC;
- transfer control to the entry point; or
- provide `fork`, `execve`, `mmap`, or a dynamic linker.

The Phase 4 process manager remains a metadata registry. A future object
authority service must bind its process records to real kernel objects and
consume this mapping manifest before the OS can start independent user
executables.

## Validation

The Phase 5 workflow runs Zig formatting, all core/POSIX tests, the three
Microkit Protection Domain links, Microkit system composition, and the existing
QEMU bootstrap smoke test. The ELF loader tests cover file/BSS population,
mapping permissions, page collision handling, W^X, ET_DYN rejection,
user-range validation, stack guard separation, stack alignment, argv/envp,
auxiliary vectors, bounds, and arena exhaustion.
