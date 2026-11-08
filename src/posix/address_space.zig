// SPDX-License-Identifier: BSD-2-Clause
//! Fixed initial x86-64 user address-space policy for dynamic Phase 11 processes.
//!
//! This policy reserves deterministic locations for the stack guard and IPC
//! buffer. It deliberately does not allocate page tables or expose CPtrs.

pub const page_size: u64 = 4096;
pub const user_min_address: u64 = 0x1_0000;
pub const user_address_end: u64 = 0x0000_8000_0000_0000;
pub const default_stack_top: u64 = 0x0000_7fff_ffff_e000;
pub const default_stack_size: u64 = 8 * 1024 * 1024;

pub const Permissions = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    reserved: u5 = 0,
};

pub const Range = struct {
    base: u64,
    length: u64,

    pub fn end(self: Range) Error!u64 {
        const result = @addWithOverflow(self.base, self.length);
        if (result[1] != 0) return error.AddressOverflow;
        return result[0];
    }

    pub fn overlaps(self: Range, other: Range) Error!bool {
        if (self.length == 0 or other.length == 0) return error.InvalidRange;
        const self_end = try self.end();
        const other_end = try other.end();
        return self.base < other_end and other.base < self_end;
    }
};

pub const Error = error{
    AddressOverflow,
    InvalidRange,
    NonCanonicalUserAddress,
    UnalignedRange,
    WritableExecutableRange,
    EmptyPermissions,
    ReservedRangeCollision,
    InvalidStack,
};

pub const InitialLayout = struct {
    stack: Range,
    stack_guard: Range,
    ipc_buffer: Range,
};

/// Derive a process's IPC-buffer page immediately below (but never inside)
/// the stack guard. A page of separation is retained for future fault/VDSO use.
pub fn initialLayout(stack_top: u64, stack_size: u64) Error!InitialLayout {
    if (stack_top % page_size != 0 or stack_size == 0 or stack_size % page_size != 0) {
        return error.UnalignedRange;
    }
    if (stack_top > user_address_end or stack_top <= stack_size + 2 * page_size) {
        return error.InvalidStack;
    }

    const stack_bottom = stack_top - stack_size;
    const guard = Range{ .base = stack_bottom - page_size, .length = page_size };
    const ipc = Range{ .base = stack_bottom - 3 * page_size, .length = page_size };
    const stack = Range{ .base = stack_bottom, .length = stack_size };
    if (try guard.overlaps(ipc) or try guard.overlaps(stack) or try ipc.overlaps(stack)) {
        return error.InvalidStack;
    }
    return .{ .stack = stack, .stack_guard = guard, .ipc_buffer = ipc };
}

pub fn validateRange(range: Range, permissions: Permissions) Error!void {
    if (range.length == 0 or range.base % page_size != 0 or range.length % page_size != 0) {
        return error.UnalignedRange;
    }
    const end = try range.end();
    if (range.base < user_min_address or end > user_address_end) {
        return error.NonCanonicalUserAddress;
    }
    if (permissions.reserved != 0) return error.EmptyPermissions;
    if (!(permissions.read or permissions.write or permissions.execute)) {
        return error.EmptyPermissions;
    }
    if (permissions.write and permissions.execute) return error.WritableExecutableRange;
}

pub fn validateInitialMappings(
    mappings: []const Mapping,
    stack_pointer: u64,
    stack_top: u64,
    stack_size: u64,
) Error!InitialLayout {
    const layout = try initialLayout(stack_top, stack_size);
    if (stack_pointer % 16 != 0 or stack_pointer < layout.stack.base or
        stack_pointer > (try layout.stack.end()))
    {
        return error.InvalidStack;
    }

    for (mappings, 0..) |mapping, index| {
        const range = Range{ .base = mapping.virtual_address, .length = mapping.byte_length };
        try validateRange(range, .{
            .read = mapping.readable,
            .write = mapping.writable,
            .execute = mapping.executable,
        });
        if (try range.overlaps(layout.stack_guard) or try range.overlaps(layout.ipc_buffer)) {
            return error.ReservedRangeCollision;
        }
        if (mapping.writable and mapping.executable) return error.WritableExecutableRange;

        for (mappings[0..index]) |previous| {
            if (try range.overlaps(.{
                .base = previous.virtual_address,
                .length = previous.byte_length,
            })) return error.InvalidRange;
        }
    }
    return layout;
}

pub const Mapping = struct {
    virtual_address: u64,
    byte_length: u64,
    readable: bool,
    writable: bool,
    executable: bool,
};

test "initial address-space layout keeps IPC buffer below guard and stack" {
    const std = @import("std");
    const layout = try initialLayout(default_stack_top, default_stack_size);
    try std.testing.expect(!(try layout.ipc_buffer.overlaps(layout.stack_guard)));
    try std.testing.expect(!(try layout.stack_guard.overlaps(layout.stack)));
    try std.testing.expect(!(try layout.ipc_buffer.overlaps(layout.stack)));
    try std.testing.expectEqual(@as(u64, page_size), layout.ipc_buffer.length);
}

test "address-space policy rejects W plus X, overflow, and reserved collisions" {
    const std = @import("std");
    try std.testing.expectError(
        error.WritableExecutableRange,
        validateRange(.{ .base = 0x20_0000, .length = page_size }, .{
            .read = true,
            .write = true,
            .execute = true,
        }),
    );
    try std.testing.expectError(
        error.AddressOverflow,
        (Range{ .base = std.math.maxInt(u64) - 4095, .length = 8192 }).end(),
    );

    const layout = try initialLayout(default_stack_top, default_stack_size);
    const mappings = [_]Mapping{.{
        .virtual_address = layout.ipc_buffer.base,
        .byte_length = page_size,
        .readable = true,
        .writable = true,
        .executable = false,
    }};
    try std.testing.expectError(
        error.ReservedRangeCollision,
        validateInitialMappings(&mappings, layout.stack.base + 16, default_stack_top, default_stack_size),
    );
}

test "address-space policy preserves disjoint static ELF mappings" {
    const std = @import("std");
    const mappings = [_]Mapping{
        .{
            .virtual_address = 0x20_0000,
            .byte_length = 2 * page_size,
            .readable = true,
            .writable = false,
            .executable = true,
        },
        .{
            .virtual_address = 0x30_0000,
            .byte_length = 2 * page_size,
            .readable = true,
            .writable = true,
            .executable = false,
        },
    };
    const layout = try validateInitialMappings(
        &mappings,
        default_stack_top - 16,
        default_stack_top,
        default_stack_size,
    );
    try std.testing.expectEqual(default_stack_top - default_stack_size, layout.stack.base);
}
