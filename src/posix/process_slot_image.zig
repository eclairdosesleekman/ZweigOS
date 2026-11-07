// SPDX-License-Identifier: BSD-2-Clause
//! Bounds and helpers for the single pre-mapped x86-64 executable slot.

pub const base_address: u64 = 0x4400_0000;
pub const page_size: usize = 4096;
pub const max_image_size: usize = page_size;

pub const Error = error{ EmptyImage, ImageTooLarge };

pub fn validateLength(length: usize) Error!void {
    if (length == 0) return error.EmptyImage;
    if (length > max_image_size) return error.ImageTooLarge;
}

/// Build a tiny leaf function that returns an integer in RAX using the
/// x86-64 System V function ABI: mov eax, imm32; ret.
pub fn returnValueProgram(value: u32) [6]u8 {
    return .{
        0xb8,
        @truncate(value),
        @truncate(value >> 8),
        @truncate(value >> 16),
        @truncate(value >> 24),
        0xc3,
    };
}

test "flat image length is bounded by the pre-mapped executable page" {
    const std = @import("std");
    try validateLength(1);
    try validateLength(max_image_size);
    try std.testing.expectError(error.EmptyImage, validateLength(0));
    try std.testing.expectError(error.ImageTooLarge, validateLength(max_image_size + 1));
}

test "return-value program encodes mov eax, imm32 followed by ret" {
    const std = @import("std");
    const program = returnValueProgram(0x1234_5678);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xb8, 0x78, 0x56, 0x34, 0x12, 0xc3 },
        &program,
    );
}
