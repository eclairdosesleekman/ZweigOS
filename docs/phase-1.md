# Phase 1: bootable Zig Protection Domain

## Goal

Bring up an unmodified seL4 kernel through the seL4 Microkit SDK on QEMU's
`x86_64_generic` platform, then execute a native 64-bit Zig component in a
Microkit Protection Domain.

This milestone intentionally proves only the boot and language/runtime
boundary. It does not attempt to implement a UNIX process model or POSIX.

## Pinned dependencies

| Dependency | Version / target |
| --- | --- |
| seL4 Microkit SDK | 2.4.0 |
| Microkit board | `x86_64_generic` |
| Microkit config | `debug` |
| Zig | 0.17.1 |
| QEMU | `qemu-system-x86_64` |

The SDK is expected to contain:

- `bin/microkit`
- `board/x86_64_generic/debug/lib/libmicrokit.a`
- `board/x86_64_generic/debug/lib/microkit.ld`
- `board/x86_64_generic/debug/elf/sel4_32.elf`

## Build

```sh
export MICROKIT_SDK=/absolute/path/to/microkit-sdk-2.4.0
make check
make build
```

The Zig executable is linked against the SDK's `libmicrokit.a` and
`microkit.ld`. It targets the x86-64 System V ABI used by the Microkit
x86-64 examples, does not link a host C library, and disables Zig's normal
program entry point. The Microkit runtime supplies `_start` and invokes the
component callbacks.

The component exports these C ABI functions:

- `init(void)` — prints the bring-up banner.
- `notified(unsigned int channel)` — currently an intentionally empty
  callback; no notification channels are assigned yet.

The only imported C symbol is `microkit_dbg_puts`, used as a temporary
bring-up console. It is provided by the Microkit debug library. A later
milestone should replace this dependency with a dedicated user-space serial
driver/service and an explicit console IPC interface.

## Run in QEMU

```sh
make run
```

The QEMU command uses the Microkit-generated `build/loader.img` as its initrd
and the SDK's `sel4_32.elf` as the kernel image. This is intentional for the
Microkit x86-64 QEMU boot flow: the kernel boot image is the 32-bit ELF variant
even though it enters a 64-bit system and executes 64-bit Protection Domains.

The expected debug-console output includes:

```text
Zweig OS - Phase 1
seL4 Microkit / x86_64_generic
Zig freestanding Protection Domain
Hello from Zweig OS!
```

Run a bounded automated boot check with:

```sh
make smoke-test
```

The smoke test stops QEMU after ten seconds and verifies that the banner was
written. A successful banner check confirms that the kernel, Microkit loader,
Zig component, and debug console reached the expected point; it is not a
general kernel stability or real-time test.

## MCS configuration

The Protection Domain is assigned:

- Priority: 100
- Budget: 1,000 microseconds
- Period: 10,000 microseconds

This caps its configured CPU budget at 10% over each replenishment period in
the Microkit scheduling model. The values are initial bring-up policy, not a
measured workload budget or a hard real-time guarantee.

## Current boundaries

Phase 1 deliberately does not include:

- dynamic process creation or ELF application loading;
- a general-purpose memory manager or demand paging;
- POSIX syscalls, musl, pthreads, or Linux binary compatibility;
- VFS, persistent filesystems, networking, or device management;
- a general UART driver (the debug console is only for bring-up);
- SMP policy, WCET analysis, or hard real-time claims.

The next milestone can introduce a small Zig service framework, explicit
Capability/endpoint wiring, and a dedicated serial console service while
keeping the seL4 kernel unchanged.
