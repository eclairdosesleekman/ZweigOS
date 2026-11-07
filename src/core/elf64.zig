// SPDX-License-Identifier: BSD-2-Clause
//! Defensive ELF64 little-endian x86-64 image validation.
//!
//! This validates an image before a future loader maps PT_LOAD segments.
//! It deliberately does not allocate Frames, build page tables, or jump to
//! an entry point.

const std = @import("std");

pub const Header = struct {
    entry: u64,
    program_header_offset: u64,
    program_header_entry_size: u16,
    program_header_count: u16,
    loadable_segment_count: u16,
};

pub const Error = error{
    TruncatedHeader,
    BadMagic,
    UnsupportedClass,
    UnsupportedEndian,
    UnsupportedType,
    UnsupportedMachine,
    UnsupportedVersion,
    InvalidHeaderSize,
    InvalidProgramHeaderSize,
    TruncatedProgramHeaders,
    NoLoadableSegments,
    InvalidLoadSegment,
};

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

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

pub fn validate(image: []const u8) Error!Header {
    if (image.len < 64) return error.TruncatedHeader;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadMagic;
    if (image[4] != 2) return error.UnsupportedClass;
    if (image[5] != 1) return error.UnsupportedEndian;
    if (image[6] != 1) return error.UnsupportedVersion;

    const file_type = read16(image, 16);
    if (file_type != 2 and file_type != 3) return error.UnsupportedType;
    if (read16(image, 18) != 62) return error.UnsupportedMachine;
    if (read32(image, 20) != 1) return error.UnsupportedVersion;

    const entry = read64(image, 24);
    const phoff = read64(image, 32);
    const ehsize = read16(image, 52);
    const phentsize = read16(image, 54);
    const phnum = read16(image, 56);

    if (ehsize < 64) return error.InvalidHeaderSize;
    if (phnum == 0 or phentsize < 56) return error.InvalidProgramHeaderSize;

    const table_bytes = @as(u64, phentsize) * @as(u64, phnum);
    const table_end_result = @addWithOverflow(phoff, table_bytes);
    if (table_end_result[1] != 0) return error.TruncatedProgramHeaders;
    const image_length: u64 = @intCast(image.len);
    if (phoff > image_length or table_end_result[0] > image_length) {
        return error.TruncatedProgramHeaders;
    }

    var loadable_count: u16 = 0;
    for (0..phnum) |index| {
        const offset64 = phoff + (@as(u64, @intCast(index)) * phentsize);
        const offset: usize = @intCast(offset64);
        if (read32(image, offset) != 1) continue; // PT_LOAD

        const file_offset = read64(image, offset + 8);
        const virtual_address = read64(image, offset + 16);
        const file_size = read64(image, offset + 32);
        const memory_size = read64(image, offset + 40);
        const alignment = read64(image, offset + 48);

        if (file_size > memory_size) return error.InvalidLoadSegment;
        const file_end_result = @addWithOverflow(file_offset, file_size);
        if (file_end_result[1] != 0 or file_end_result[0] > image_length) {
            return error.InvalidLoadSegment;
        }
        const virtual_end_result = @addWithOverflow(virtual_address, memory_size);
        if (virtual_end_result[1] != 0) return error.InvalidLoadSegment;

        if (alignment > 1) {
            if ((alignment & (alignment - 1)) != 0) return error.InvalidLoadSegment;
            if ((file_offset % alignment) != (virtual_address % alignment)) {
                return error.InvalidLoadSegment;
            }
        }

        loadable_count += 1;
    }

    if (loadable_count == 0) return error.NoLoadableSegments;

    return .{
        .entry = entry,
        .program_header_offset = phoff,
        .program_header_entry_size = phentsize,
        .program_header_count = phnum,
        .loadable_segment_count = loadable_count,
    };
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

test "ELF64 validator accepts an x86-64 loadable image" {
    var image = [_]u8{0} ** 136;
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
    write64(&image, 72, 120);
    write64(&image, 80, 0x20_0000);
    write64(&image, 96, 16);
    write64(&image, 104, 4096);
    write64(&image, 112, 8);

    const header = try validate(&image);
    try std.testing.expectEqual(@as(u64, 0x20_0000), header.entry);
    try std.testing.expectEqual(@as(u16, 1), header.loadable_segment_count);
}

test "ELF64 validator rejects non-x86-64 and truncated segment data" {
    var image = [_]u8{0} ** 136;
    image[0] = 0x7f;
    image[1] = 'E';
    image[2] = 'L';
    image[3] = 'F';
    image[4] = 2;
    image[5] = 1;
    image[6] = 1;
    write16(&image, 16, 2);
    write16(&image, 18, 3);
    write32(&image, 20, 1);
    write64(&image, 32, 64);
    write16(&image, 52, 64);
    write16(&image, 54, 56);
    write16(&image, 56, 1);
    try std.testing.expectError(error.UnsupportedMachine, validate(&image));

    write16(&image, 18, 62);
    write32(&image, 64, 1);
    write64(&image, 72, 120);
    write64(&image, 80, 0x20_0000);
    write64(&image, 96, 32);
    write64(&image, 104, 16);
    write64(&image, 112, 8);
    try std.testing.expectError(error.InvalidLoadSegment, validate(&image));
}
