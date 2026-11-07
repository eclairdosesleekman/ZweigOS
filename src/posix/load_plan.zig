// SPDX-License-Identifier: BSD-2-Clause
//! Converts a validated ELF64 image into a bounded load plan.
//!
//! The plan is data only. Phase 3 does not yet allocate Frame capabilities,
//! populate arbitrary VSpaces, apply relocations, or start the ELF entry point.

const std = @import("std");
const elf64 = @import("../core/elf64.zig");

pub const max_load_segments: usize = 16;
pub const default_stack_size: u64 = 8 * 1024 * 1024;
pub const default_stack_top: u64 = 0x0000_7fff_ffff_e000;
pub const guard_size: u64 = 4096;

pub const Error = elf64.Error || error{
    TooManyLoadSegments,
    OverlappingLoadSegments,
};

pub const Segment = struct {
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
    readable: bool,
    writable: bool,
    executable: bool,
};

pub const Plan = struct {
    entry: u64,
    segments: [max_load_segments]Segment,
    segment_count: usize,
    stack_bottom: u64,
    stack_top: u64,
    stack_guard_bottom: u64,
};

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) |
        (@as(u64, read32(bytes, offset + 4)) << 32);
}

pub fn create(image: []const u8) Error!Plan {
    const header = try elf64.validate(image);
    var plan = Plan{
        .entry = header.entry,
        .segments = undefined,
        .segment_count = 0,
        .stack_bottom = default_stack_top - default_stack_size,
        .stack_top = default_stack_top,
        .stack_guard_bottom = default_stack_top - default_stack_size - guard_size,
    };

    for (0..header.program_header_count) |index| {
        const offset64 = header.program_header_offset +
            (@as(u64, @intCast(index)) * @as(u64, header.program_header_entry_size));
        const offset: usize = @intCast(offset64);
        if (read32(image, offset) != 1) continue; // PT_LOAD

        if (plan.segment_count == max_load_segments) return error.TooManyLoadSegments;

        const flags = read32(image, offset + 4);
        const segment = Segment{
            .file_offset = read64(image, offset + 8),
            .virtual_address = read64(image, offset + 16),
            .file_size = read64(image, offset + 32),
            .memory_size = read64(image, offset + 40),
            .alignment = read64(image, offset + 48),
            .readable = (flags & 4) != 0,
            .writable = (flags & 2) != 0,
            .executable = (flags & 1) != 0,
        };

        const segment_end = segment.virtual_address + segment.memory_size;
        for (plan.segments[0..plan.segment_count]) |existing| {
            const existing_end = existing.virtual_address + existing.memory_size;
            if (segment.virtual_address < existing_end and existing.virtual_address < segment_end) {
                return error.OverlappingLoadSegments;
            }
        }

        plan.segments[plan.segment_count] = segment;
        plan.segment_count += 1;
    }

    return plan;
}

fn write16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn write32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |index| {
        const shift: u5 = @intCast(index * 8);
        bytes[offset + index] = @truncate(value >> shift);
    }
}

fn write64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |index| {
        const shift: u6 = @intCast(index * 8);
        bytes[offset + index] = @truncate(value >> shift);
    }
}

test "ELF64 load planner records segment permissions and guarded stack layout" {
    var image: [136]u8 = @splat(0);
    image[0] = 0x7f;
    image[1] = 'E';
    image[2] = 'L';
    image[3] = 'F';
    image[4] = 2;
    image[5] = 1;
    image[6] = 1;
    write16(&image, 16, 2);
    write16(&image, 18, 62);
    write32(&image, 20, 1);
    write64(&image, 24, 0x20_0000);
    write64(&image, 32, 64);
    write16(&image, 52, 64);
    write16(&image, 54, 56);
    write16(&image, 56, 1);
    write32(&image, 64, 1); // PT_LOAD
    write32(&image, 68, 5); // PF_R | PF_X
    write64(&image, 72, 120);
    write64(&image, 80, 0x20_0000);
    write64(&image, 96, 16);
    write64(&image, 104, 4096);
    write64(&image, 112, 8);

    const plan = try create(&image);
    try std.testing.expectEqual(@as(usize, 1), plan.segment_count);
    try std.testing.expect(plan.segments[0].readable);
    try std.testing.expect(plan.segments[0].executable);
    try std.testing.expect(!plan.segments[0].writable);
    try std.testing.expectEqual(default_stack_top, plan.stack_top);
    try std.testing.expectEqual(default_stack_top - default_stack_size, plan.stack_bottom);
    try std.testing.expectEqual(plan.stack_bottom - guard_size, plan.stack_guard_bottom);
}
