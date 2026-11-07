// SPDX-License-Identifier: BSD-2-Clause
//! Passive POSIX syscall service for the statically composed bootstrap task.
//!
//! The shared I/O page is mapped read/write into the client and this service.
//! Calls are synchronous PP RPCs, so the single-client buffer is not reused
//! until the service replies. Before adding client threads, introduce per-thread
//! buffers or explicit serialization.

const abi = @import("abi.zig");
const fd_table = @import("fd_table.zig");
const process_manager = @import("process_manager.zig");

extern fn zweig_console_putc(character: c_int) void;

const expected_channel: u32 = 0;
const shared_buffer_address: usize = 0x4100_0000;
const shared_buffer_size: usize = 4096;
const bootstrap_domain_id: u16 = 1;

var processes: process_manager.Table = .{};
var bootstrap_process: process_manager.ProcessInfo = undefined;
var processes_ready = false;

fn ensureProcesses() void {
    if (!processes_ready) {
        bootstrap_process = processes.initialize(bootstrap_domain_id) catch unreachable;
        processes_ready = true;
    }
}

fn bootstrapDescriptors() *fd_table.Table {
    ensureProcesses();
    return processes.descriptors(bootstrap_process.id) orelse unreachable;
}

fn writeConsole(fd: i64, length: u64) i64 {
    const descriptors = bootstrapDescriptors();
    if (!descriptors.canWrite(fd)) return abi.failure(.bad_fd);
    if (length > @as(u64, @intCast(shared_buffer_size))) return abi.failure(.invalid);

    const bytes: [*]const u8 = @ptrFromInt(shared_buffer_address);
    for (0..@as(usize, @intCast(length))) |index| {
        zweig_console_putc(@intCast(bytes[index]));
    }
    return @intCast(length);
}

fn readConsole(fd: i64) i64 {
    if (!bootstrapDescriptors().canRead(fd)) return abi.failure(.bad_fd);

    // The input device path is not part of Phase 4 yet.
    return abi.failure(.try_again);
}

pub export fn zweig_posix_dispatch(
    channel: u32,
    syscall_number: u64,
    argument0: u64,
    argument1: u64,
) i64 {
    if (channel != expected_channel) return abi.failure(.invalid);
    ensureProcesses();

    return switch (syscall_number) {
        @backingInt(abi.Syscall.getpid) => @intCast(bootstrap_process.pid),
        @backingInt(abi.Syscall.write) => blk: {
            if (argument0 >= @as(u64, @intCast(fd_table.max_fds))) break :blk abi.failure(.bad_fd);
            break :blk writeConsole(@intCast(argument0), argument1);
        },
        @backingInt(abi.Syscall.read) => blk: {
            if (argument0 >= @as(u64, @intCast(fd_table.max_fds))) break :blk abi.failure(.bad_fd);
            break :blk readConsole(@intCast(argument0));
        },
        @backingInt(abi.Syscall.close) => blk: {
            if (argument0 >= @as(u64, @intCast(fd_table.max_fds))) break :blk abi.failure(.bad_fd);
            if (bootstrapDescriptors().close(@intCast(argument0))) break :blk 0;
            break :blk abi.failure(.bad_fd);
        },
        else => abi.failure(.not_implemented),
    };
}

pub export fn init() void {
    ensureProcesses();
    const startup: [:0]const u8 = "Zweig POSIX service: process 1 ready\r\n";
    for (startup) |character| {
        zweig_console_putc(@intCast(character));
    }
}

pub export fn notified(_: u32) void {}
