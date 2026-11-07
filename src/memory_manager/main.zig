// SPDX-License-Identifier: BSD-2-Clause
//! Passive memory service running in its own Microkit Protection Domain.

// Microkit's libmicrokit supplies the actual _start symbol. This declaration
// tells Zig not to synthesize the hosted std.start entry point.
pub const _start = {};

const page_allocator = @import("../core/page_allocator.zig");
const PageAllocator = page_allocator.PageAllocator;
const protocol = @import("../core/protocol.zig");

extern fn zweig_console_puts(message: [*:0]const u8) void;

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

pub export fn init() void {
    if (!ensureAllocator()) {
        zweig_console_puts("Zweig memory manager: arena initialization failed\r\n");
        return;
    }
    zweig_console_puts("Zweig memory manager: 256 x 4 KiB arena ready\r\n");
}

pub export fn notified(_: u32) void {}

// Called only by the C ABI adapter from Microkit's protected() entry point.
pub export fn zweig_memory_dispatch(
    channel: u32,
    operation_raw: u64,
    argument: u64,
    value_out: *u64,
) u32 {
    value_out.* = 0;
    if (channel != expected_channel) return @backingInt(protocol.Status.invalid_request);
    if (!ensureAllocator()) return @backingInt(protocol.Status.internal_error);

    const operation: protocol.Operation = switch (operation_raw) {
        @backingInt(protocol.Operation.ping) => .ping,
        @backingInt(protocol.Operation.allocate_pages) => .allocate_pages,
        @backingInt(protocol.Operation.release_pages) => .release_pages,
        @backingInt(protocol.Operation.get_stats) => .get_stats,
        else => return @backingInt(protocol.Status.invalid_request),
    };

    switch (operation) {
        .ping => {
            value_out.* = 0x5a57_4549_474f_534f;
            return @backingInt(protocol.Status.ok);
        },
        .allocate_pages => {
            if (argument == 0 or argument > page_allocator.max_pages) {
                return @backingInt(protocol.Status.invalid_argument);
            }
            const lease = allocator.allocate(@intCast(argument)) catch |err| {
                return switch (err) {
                    error.InvalidPageCount => @backingInt(protocol.Status.invalid_argument),
                    error.OutOfMemory, error.LeaseTableFull => @backingInt(protocol.Status.out_of_memory),
                };
            };
            value_out.* = lease.token;
            return @backingInt(protocol.Status.ok);
        },
        .release_pages => {
            allocator.release(argument) catch |err| {
                return switch (err) {
                    error.InvalidToken, error.StaleToken => @backingInt(protocol.Status.stale_lease),
                    error.CorruptState => @backingInt(protocol.Status.internal_error),
                };
            };
            return @backingInt(protocol.Status.ok);
        },
        .get_stats => {
            value_out.* = allocator.freePages();
            return @backingInt(protocol.Status.ok);
        },
    }
}
