// SPDX-License-Identifier: BSD-2-Clause
//! Validated initial x86-64 user register context for the Phase 8 execution slot.

pub const user_min_address: u64 = 0x1_0000;
pub const user_address_end: u64 = 0x0000_8000_0000_0000;
pub const initial_rflags: u64 = 0x202;

pub const Mapping = struct {
    virtual_address: u64,
    byte_length: u64,
    readable: bool,
    writable: bool,
    executable: bool,
};

pub const InitialContext = struct {
    rip: u64,
    rsp: u64,
    rflags: u64 = initial_rflags,
};

pub const Error = error{
    InvalidMapping,
    WritableExecutableMapping,
    EntryNotExecutable,
    StackNotWritable,
    InvalidInstructionPointer,
    InvalidStackPointer,
};

/// Build the first three x86-64 user registers from an executable mapping and
/// a separate writable stack. The caller still needs a valid TCB capability,
/// CSpace, VSpace, and scheduling context before installing this state.
pub fn build(
    entry: u64,
    stack_pointer: u64,
    code: Mapping,
    stack: Mapping,
) Error!InitialContext {
    try validateMapping(code);
    try validateMapping(stack);
    if (code.writable and code.executable) return error.WritableExecutableMapping;
    if (stack.writable and stack.executable) return error.WritableExecutableMapping;

    if (!code.readable or !code.executable or entry < code.virtual_address or
        entry >= endOf(code))
    {
        return error.EntryNotExecutable;
    }
    if (!stack.readable or !stack.writable or stack.executable) {
        return error.StackNotWritable;
    }

    if (entry < user_min_address or entry >= user_address_end) {
        return error.InvalidInstructionPointer;
    }
    if (stack_pointer % 16 != 0 or stack_pointer <= stack.virtual_address or
        stack_pointer > endOf(stack) or stack_pointer >= user_address_end)
    {
        return error.InvalidStackPointer;
    }

    return .{
        .rip = entry,
        .rsp = stack_pointer,
        .rflags = initial_rflags,
    };
}

fn validateMapping(mapping: Mapping) Error!void {
    if (mapping.byte_length == 0 or mapping.virtual_address % 4096 != 0 or
        mapping.byte_length % 4096 != 0 or mapping.virtual_address < user_min_address)
    {
        return error.InvalidMapping;
    }
    const end = @addWithOverflow(mapping.virtual_address, mapping.byte_length);
    if (end[1] != 0 or end[0] > user_address_end) return error.InvalidMapping;
    if (!(mapping.readable or mapping.writable or mapping.executable)) {
        return error.InvalidMapping;
    }
}

fn endOf(mapping: Mapping) u64 {
    return mapping.virtual_address + mapping.byte_length;
}

test "initial context points into RX code and a distinct RW stack" {
    const std = @import("std");
    const code = Mapping{
        .virtual_address = 0x20_0000,
        .byte_length = 2 * 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const stack = Mapping{
        .virtual_address = 0x70_0000,
        .byte_length = 4 * 4096,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    const context = try build(0x20_0100, 0x70_4000, code, stack);
    try std.testing.expectEqual(@as(u64, 0x20_0100), context.rip);
    try std.testing.expectEqual(@as(u64, 0x70_4000), context.rsp);
    try std.testing.expectEqual(initial_rflags, context.rflags);
}

test "initial context rejects W plus X mappings and invalid entry or stack" {
    const std = @import("std");
    const code = Mapping{
        .virtual_address = 0x20_0000,
        .byte_length = 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const stack = Mapping{
        .virtual_address = 0x70_0000,
        .byte_length = 4 * 4096,
        .readable = true,
        .writable = true,
        .executable = false,
    };

    var invalid_code = code;
    invalid_code.writable = true;
    try std.testing.expectError(
        error.WritableExecutableMapping,
        build(0x20_0100, 0x70_4000, invalid_code, stack),
    );
    try std.testing.expectError(
        error.EntryNotExecutable,
        build(0x30_0000, 0x70_4000, code, stack),
    );
    try std.testing.expectError(
        error.InvalidStackPointer,
        build(0x20_0100, 0x70_3ff8, code, stack),
    );
    try std.testing.expectError(
        error.InvalidStackPointer,
        build(0x20_0100, 0x70_0000, code, stack),
    );
}

test "initial context rejects non-user, unaligned, and overflowing ranges" {
    const std = @import("std");
    const code = Mapping{
        .virtual_address = 0x20_0000,
        .byte_length = 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const stack = Mapping{
        .virtual_address = 0x70_0000,
        .byte_length = 4 * 4096,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    try std.testing.expectError(
        error.InvalidMapping,
        build(0x20_0100, 0x70_4000, .{
            .virtual_address = user_address_end - 4096,
            .byte_length = 8192,
            .readable = true,
            .writable = false,
            .executable = true,
        }, stack),
    );
    try std.testing.expectError(
        error.EntryNotExecutable,
        build(0xffff_8000_0000_0000, 0x70_4000, code, stack),
    );
}
