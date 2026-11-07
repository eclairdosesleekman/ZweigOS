// SPDX-License-Identifier: BSD-2-Clause
//! Passive memory service running in its own Microkit Protection Domain.

const PageAllocator = @import("../core/page_allocator.zig").PageAllocator;
const protocol = @import("../core/protocol.zig");

extern "c" fn zweig_console_puts(message: [*:0]const u8) void;

const arena_base: usize = 0x4000_0000;
const arena_size: usize = 0x10_0000;
const expected_channel: u32 = 0;

var allocator: PageAllocator = undefined;
var allocator_ready = false;

fn ensureAllocator() bool {
    if (allocator_ready) return true;

    const arena_ptr: [*]u8 = @ptrFromInt(arena_base);
    const arena = arena_ptr[0..arena_size];
    allocator = PageAllocator.init(arena) catch return false;
    allocator_ready = true;
    return true;
}

export fn init() void {
    if (!ensureAllocator()) {
        zweig_console_puts("Zweig memory manager: arena initialization failed\r\n");
        return;
    }
    zweig_console_puts("Zweig memory manager: 256 x 4 KiB arena ready\r\n");
}

export fn notified(_: u32) void {}

// Called only by the C ABI adapter from Microkit's protected() entry point.
export fn zweig_memory_dispatch(
    channel: u32,
    operation_raw: u64,
    argument: u64,
    value_out: *u64,
) u32 {
    value_out.* = 0;
    if (channel != expected_channel) return @intFromEnum(protocol.Status.invalid_request);
    if (!ensureAllocator()) return @intFromEnum(protocol.Status.internal_error);

    const operation = std.meta.intToEnum(protocol.Operation, operation_raw) catch {
        return @intFromEnum(protocol.Status.invalid_request);
    };

    switch (operation) {
        .ping => {
            value_out.* = 0x5a57_4549_474f_534f;
            return @intFromEnum(protocol.Status.ok);
        },
        .allocate_pages => {
            if (argument == 0 or argument > PageAllocator.max_pages) {
                return @intFromEnum(protocol.Status.invalid_argument);
            }
            const lease = allocator.allocate(@intCast(argument)) catch |err| {
                return switch (err) {
                    error.InvalidPageCount => @intFromEnum(protocol.Status.invalid_argument),
                    error.OutOfMemory, error.LeaseTableFull => @intFromEnum(protocol.Status.out_of_memory),
                };
            };
            value_out.* = lease.token;
            return @intFromEnum(protocol.Status.ok);
        },
        .release_pages => {
            allocator.release(argument) catch |err| {
                return switch (err) {
                    error.InvalidToken, error.StaleToken => @intFromEnum(protocol.Status.stale_lease),
                    error.CorruptState => @intFromEnum(protocol.Status.internal_error),
                };
            };
            return @intFromEnum(protocol.Status.ok);
        },
        .get_stats => {
            value_out.* = allocator.freePages();
            return @intFromEnum(protocol.Status.ok);
        },
    }
}
