// Phase 1 entry point for a single Microkit Protection Domain.
//
// Microkit provides the runtime/startup code and calls init() after the
// Protection Domain has been constructed. Keep this program freestanding:
// no host libc, process model, or Linux system calls are available here.

extern "c" fn microkit_dbg_puts(message: [*:0]const u8) void;

const boot_banner: [:0]const u8 =
    "\r\n" ++
    "Zweig OS - Phase 1\r\n" ++
    "seL4 Microkit / x86_64_generic\r\n" ++
    "Zig freestanding Protection Domain\r\n" ++
    "Hello from Zweig OS!\r\n";

export fn init() void {
    microkit_dbg_puts(boot_banner);
}

// This Protection Domain has no notification channels in Phase 1. Export the
// callback anyway so the image follows the complete Microkit component ABI.
export fn notified(_: u32) void {}
