// SPDX-License-Identifier: BSD-2-Clause
//! Zweig OS Phase 4 bootstrap: exercise the memory and POSIX service ABIs.

// Microkit's libmicrokit supplies the actual _start symbol. This declaration
// tells Zig not to synthesize the hosted std.start entry point.
pub const _start = {};

const capability = @import("core/capability.zig");
const protocol = @import("core/protocol.zig");
const scheduling = @import("core/scheduling.zig");

extern fn zweig_console_puts(message: [*:0]const u8) void;
extern fn zweig_memory_call(
    channel: u32,
    operation: u64,
    argument: u64,
    value_out: *u64,
) i32;
extern fn zweig_write(fd: c_int, buffer: [*]const u8, length: usize) i64;
extern fn zweig_read(fd: c_int, buffer: ?[*]u8, length: usize) i64;
extern fn zweig_getpid() i64;
extern fn zweig_run_slot() i64;

const memory_channel: u32 = 0;

fn log(message: [*:0]const u8) void {
    zweig_console_puts(message);
}

fn exerciseMemoryService() bool {
    const client_profile = scheduling.Profile{
        .priority = 99,
        .budget_us = 1000,
        .period_us = 10000,
    };
    client_profile.validate() catch return false;

    var service_caps = capability.Table{};
    service_caps.install(.{
        .service = .memory,
        .channel = memory_channel,
        .rights = .{ .call = true },
    }) catch return false;

    const memory = service_caps.lookup(.memory, .{ .call = true }) catch return false;

    var lease_token: u64 = 0;
    const alloc_status = zweig_memory_call(
        memory.channel,
        @backingInt(protocol.Operation.allocate_pages),
        4,
        &lease_token,
    );
    if (alloc_status != 0) return false;

    var free_pages_after_alloc: u64 = 0;
    const stats_status = zweig_memory_call(
        memory.channel,
        @backingInt(protocol.Operation.get_stats),
        0,
        &free_pages_after_alloc,
    );
    if (stats_status != 0 or free_pages_after_alloc != 252) return false;

    var release_result: u64 = 0;
    const release_status = zweig_memory_call(
        memory.channel,
        @backingInt(protocol.Operation.release_pages),
        lease_token,
        &release_result,
    );
    if (release_status != 0) return false;

    var free_pages_after_release: u64 = 0;
    const final_stats_status = zweig_memory_call(
        memory.channel,
        @backingInt(protocol.Operation.get_stats),
        0,
        &free_pages_after_release,
    );
    return final_stats_status == 0 and free_pages_after_release == 256;
}

fn exercisePosixAbi() bool {
    const greeting: [:0]const u8 = "Zweig OS: POSIX write via seL4 IPC\r\n";
    const written = zweig_write(1, greeting.ptr, greeting.len);
    if (written != @as(i64, @intCast(greeting.len))) return false;

    // Phase 4 sources the bootstrap PID from the process manager's registry.
    if (zweig_getpid() != 1) return false;

    // stdin exists as fd 0, but an input driver is not available yet.
    // EAGAIN (-11) is the expected raw syscall result.
    if (zweig_read(0, null, 1) != -11) return false;
    return true;
}

export fn init() void {
    if (!exerciseMemoryService()) {
        log("Zweig Phase 2: memory RPC FAILED\r\n");
        return;
    }
    log("Zweig Phase 2: memory RPC PASS\r\n");

    if (!exercisePosixAbi()) {
        log("Zweig Phase 4: POSIX syscall FAILED\r\n");
        return;
    }
    log("Zweig Phase 4: process-aware POSIX syscall PASS\r\n");

    if (zweig_run_slot() != 1) {
        log("Zweig Phase 8: seL4 TCB execution slot FAILED\r\n");
        return;
    }
    log("Zweig Phase 8: seL4 TCB execution slot PASS\r\n");
}

export fn notified(_: u32) void {}
