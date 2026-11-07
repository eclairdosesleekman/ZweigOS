// SPDX-License-Identifier: BSD-2-Clause
//! Phase 5 ELF image materialization and initial x86-64 process stack builder.
//!
//! This copies validated PT_LOAD contents (including zero-filled BSS) into a
//! caller-supplied, page-aligned staging arena and emits a virtual mapping
//! manifest. It does not manufacture Frame capabilities, install page tables,
//! apply dynamic relocations, or start a TCB. Only static ET_EXEC images are
//! accepted; ET_DYN and writable+executable segments are deliberately rejected.

const std = @import("std");
const load_plan = @import("load_plan.zig");

pub const page_size: usize = 4096;
pub const max_mappings: usize = load_plan.max_load_segments + 1;
pub const max_arguments: usize = 32;
pub const max_environment: usize = 32;

const user_min_address: u64 = 0x1_0000;
const user_address_end: u64 = 0x0000_8000_0000_0000;

const at_null: u64 = 0;
const at_pagesz: u64 = 6;
const at_entry: u64 = 9;
const max_usize: u64 = @intCast(std.math.maxInt(usize));

pub const Arguments = struct {
    argv: []const []const u8 = &.{},
    envp: []const []const u8 = &.{},
};

pub const Options = struct {
    stack_top: u64 = load_plan.default_stack_top,
    stack_size: u64 = load_plan.default_stack_size,
    arguments: Arguments = .{},
};

pub const Mapping = struct {
    virtual_address: u64 = 0,
    byte_length: u64 = 0,
    backing_offset: usize = 0,
    readable: bool = false,
    writable: bool = false,
    executable: bool = false,
};

pub const LoadedImage = struct {
    entry: u64,
    stack_pointer: u64,
    stack_bottom: u64,
    stack_top: u64,
    stack_guard_bottom: u64,
    mappings: [max_mappings]Mapping,
    mapping_count: usize,
    argument_count: usize,
    environment_count: usize,
    arena_used_bytes: usize,
};

pub const Error = load_plan.Error || error{
    UnsupportedImageType,
    InvalidArena,
    ArenaExhausted,
    InvalidStackLayout,
    StackOverlapsLoadSegment,
    SegmentOutsideUserRange,
    WritableExecutableSegment,
    OverlappingLoadPages,
    TooManyArguments,
    TooManyEnvironmentEntries,
    InvalidArgumentString,
    StackOverflow,
};

const StackAux = struct {
    tag: u64,
    value: u64,
};

fn alignDown(value: u64) u64 {
    return value & ~@as(u64, page_size - 1);
}

fn alignUp(value: u64) Error!u64 {
    const sum = @addWithOverflow(value, @as(u64, page_size - 1));
    if (sum[1] != 0) return error.InvalidLoadSegment;
    return sum[0] & ~@as(u64, page_size - 1);
}

fn overlaps(left_start: u64, left_end: u64, right_start: u64, right_end: u64) bool {
    return left_start < right_end and right_start < left_end;
}

fn reservePages(arena: []u8, cursor: *usize, size: usize) Error!usize {
    if (size == 0 or size % page_size != 0) return error.InvalidArena;
    const end_result = @addWithOverflow(cursor.*, size);
    if (end_result[1] != 0 or end_result[0] > arena.len) return error.ArenaExhausted;

    const start = cursor.*;
    @memset(arena[start..end_result[0]], 0);
    cursor.* = end_result[0];
    return start;
}

fn pushWord(stack: []u8, cursor: *usize, value: u64) Error!void {
    if (cursor.* < @sizeOf(u64)) return error.StackOverflow;
    cursor.* -= @sizeOf(u64);

    for (0..@sizeOf(u64)) |index| {
        const shift: u6 = @intCast(index * 8);
        stack[cursor.* + index] = @truncate(value >> shift);
    }
}

fn pushString(
    stack: []u8,
    cursor: *usize,
    virtual_base: u64,
    value: []const u8,
) Error!u64 {
    for (value) |character| {
        if (character == 0) return error.InvalidArgumentString;
    }

    const size_result = @addWithOverflow(value.len, 1);
    if (size_result[1] != 0 or size_result[0] > cursor.*) return error.StackOverflow;
    cursor.* -= size_result[0];
    @memcpy(stack[cursor.* .. cursor.* + value.len], value);
    stack[cursor.* + value.len] = 0;

    const address_result = @addWithOverflow(virtual_base, @as(u64, @intCast(cursor.*)));
    if (address_result[1] != 0) return error.InvalidStackLayout;
    return address_result[0];
}

fn buildInitialStack(
    stack: []u8,
    virtual_base: u64,
    virtual_top: u64,
    entry: u64,
    arguments: Arguments,
) Error!u64 {
    if (arguments.argv.len > max_arguments) return error.TooManyArguments;
    if (arguments.envp.len > max_environment) return error.TooManyEnvironmentEntries;

    var argv_pointers: [max_arguments]u64 = undefined;
    var envp_pointers: [max_environment]u64 = undefined;
    var cursor = stack.len;

    for (arguments.argv, 0..) |argument, index| {
        argv_pointers[index] = try pushString(stack, &cursor, virtual_base, argument);
    }
    for (arguments.envp, 0..) |environment, index| {
        envp_pointers[index] = try pushString(stack, &cursor, virtual_base, environment);
    }

    const auxiliary = [_]StackAux{
        .{ .tag = at_pagesz, .value = @as(u64, page_size) },
        .{ .tag = at_entry, .value = entry },
        .{ .tag = at_null, .value = 0 },
    };
    const metadata_words = 1 +
        (arguments.argv.len + 1) +
        (arguments.envp.len + 1) +
        (auxiliary.len * 2);
    const metadata_size = metadata_words * @sizeOf(u64);
    if (cursor < metadata_size) return error.StackOverflow;

    // Place any alignment padding between AT_NULL and the copied strings. The
    // argc word at the initial stack pointer is therefore 16-byte aligned.
    const padding = (cursor - metadata_size) % 16;
    cursor -= padding;
    @memset(stack[cursor..cursor + padding], 0);

    var auxiliary_index = auxiliary.len;
    while (auxiliary_index > 0) {
        auxiliary_index -= 1;
        try pushWord(stack, &cursor, auxiliary[auxiliary_index].value);
        try pushWord(stack, &cursor, auxiliary[auxiliary_index].tag);
    }

    try pushWord(stack, &cursor, 0); // envp terminator
    var environment_index = arguments.envp.len;
    while (environment_index > 0) {
        environment_index -= 1;
        try pushWord(stack, &cursor, envp_pointers[environment_index]);
    }

    try pushWord(stack, &cursor, 0); // argv terminator
    var argument_index = arguments.argv.len;
    while (argument_index > 0) {
        argument_index -= 1;
        try pushWord(stack, &cursor, argv_pointers[argument_index]);
    }

    try pushWord(stack, &cursor, @as(u64, @intCast(arguments.argv.len)));

    const stack_pointer_result = @addWithOverflow(virtual_base, @as(u64, @intCast(cursor)));
    if (stack_pointer_result[1] != 0) return error.InvalidStackLayout;
    const stack_pointer = stack_pointer_result[0];
    if (stack_pointer % 16 != 0 or stack_pointer >= virtual_top) {
        return error.InvalidStackLayout;
    }
    return stack_pointer;
}

/// Materialize one static x86-64 ELF executable into an existing staging arena.
/// The returned mapping offsets refer to the same arena supplied by the caller.
pub fn load(
    image: []const u8,
    arena: []align(page_size) u8,
    options: Options,
) Error!LoadedImage {
    if (arena.len == 0 or arena.len % page_size != 0) return error.InvalidArena;

    const plan = try load_plan.create(image);
    if (plan.file_type != 2) return error.UnsupportedImageType;
    if (options.stack_size == 0 or options.stack_size % @as(u64, page_size) != 0) {
        return error.InvalidStackLayout;
    }
    if (options.stack_top % @as(u64, page_size) != 0 or
        options.stack_top > user_address_end or
        options.stack_size > options.stack_top)
    {
        return error.InvalidStackLayout;
    }
    if (options.stack_size > max_usize) return error.InvalidStackLayout;

    const stack_bottom = options.stack_top - options.stack_size;
    if (stack_bottom <= user_min_address + @as(u64, page_size)) return error.InvalidStackLayout;
    const stack_guard_bottom = stack_bottom - @as(u64, page_size);

    var result = LoadedImage{
        .entry = plan.entry,
        .stack_pointer = 0,
        .stack_bottom = stack_bottom,
        .stack_top = options.stack_top,
        .stack_guard_bottom = stack_guard_bottom,
        .mappings = @splat(.{}),
        .mapping_count = 0,
        .argument_count = options.arguments.argv.len,
        .environment_count = options.arguments.envp.len,
        .arena_used_bytes = 0,
    };

    var arena_cursor: usize = 0;
    for (plan.segments[0..plan.segment_count]) |segment| {
        if (segment.memory_size == 0) continue;
        if (segment.writable and segment.executable) return error.WritableExecutableSegment;

        const segment_end_result = @addWithOverflow(segment.virtual_address, segment.memory_size);
        if (segment_end_result[1] != 0) return error.InvalidLoadSegment;
        const segment_end = segment_end_result[0];
        if (segment.virtual_address < user_min_address or segment_end > user_address_end) {
            return error.SegmentOutsideUserRange;
        }

        const mapping_start = alignDown(segment.virtual_address);
        const mapping_end = try alignUp(segment_end);
        const mapping_size_u64 = mapping_end - mapping_start;
        if (mapping_size_u64 > max_usize) return error.InvalidLoadSegment;
        const mapping_size: usize = @intCast(mapping_size_u64);

        if (overlaps(mapping_start, mapping_end, stack_guard_bottom, options.stack_top)) {
            return error.StackOverlapsLoadSegment;
        }
        for (result.mappings[0..result.mapping_count]) |existing| {
            const existing_end = existing.virtual_address + existing.byte_length;
            if (overlaps(mapping_start, mapping_end, existing.virtual_address, existing_end)) {
                return error.OverlappingLoadPages;
            }
        }
        if (result.mapping_count == load_plan.max_load_segments) {
            return error.TooManyLoadSegments;
        }

        const backing_offset = try reservePages(arena, &arena_cursor, mapping_size);
        const segment_offset: usize = @intCast(segment.virtual_address - mapping_start);
        const file_size: usize = @intCast(segment.file_size);
        const file_offset: usize = @intCast(segment.file_offset);
        const destination_start = backing_offset + segment_offset;
        @memcpy(
            arena[destination_start .. destination_start + file_size],
            image[file_offset .. file_offset + file_size],
        );

        result.mappings[result.mapping_count] = .{
            .virtual_address = mapping_start,
            .byte_length = mapping_size_u64,
            .backing_offset = backing_offset,
            .readable = segment.readable,
            .writable = segment.writable,
            .executable = segment.executable,
        };
        result.mapping_count += 1;
    }

    const stack_size: usize = @intCast(options.stack_size);
    const stack_backing_offset = try reservePages(arena, &arena_cursor, stack_size);
    const stack = arena[stack_backing_offset .. stack_backing_offset + stack_size];
    result.stack_pointer = try buildInitialStack(
        stack,
        stack_bottom,
        options.stack_top,
        plan.entry,
        options.arguments,
    );

    result.mappings[result.mapping_count] = .{
        .virtual_address = stack_bottom,
        .byte_length = options.stack_size,
        .backing_offset = stack_backing_offset,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    result.mapping_count += 1;
    result.arena_used_bytes = arena_cursor;
    return result;
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

fn readWord(bytes: []const u8, offset: usize) u64 {
    var value: u64 = 0;
    for (0..8) |index| {
        const shift: u6 = @intCast(index * 8);
        value |= @as(u64, bytes[offset + index]) << shift;
    }
    return value;
}

fn testImage(file_type: u16, code_flags: u32, second_address: u64) [184]u8 {
    var image: [184]u8 = @splat(0);
    image[0] = 0x7f;
    image[1] = 'E';
    image[2] = 'L';
    image[3] = 'F';
    image[4] = 2;
    image[5] = 1;
    image[6] = 1;
    write16(&image, 16, file_type);
    write16(&image, 18, 62);
    write32(&image, 20, 1);
    write64(&image, 24, 0x20_0100);
    write64(&image, 32, 64);
    write16(&image, 52, 64);
    write16(&image, 54, 56);
    write16(&image, 56, 2);

    // RX text segment, intentionally not page-aligned in the ELF file.
    write32(&image, 64, 1);
    write32(&image, 68, code_flags);
    write64(&image, 72, 176);
    write64(&image, 80, 0x20_0100);
    write64(&image, 96, 4);
    write64(&image, 104, 0x80);
    write64(&image, 112, 1);

    // RW data/BSS segment.
    write32(&image, 120, 1);
    write32(&image, 124, 6);
    write64(&image, 128, 180);
    write64(&image, 136, second_address);
    write64(&image, 152, 4);
    write64(&image, 160, 5000);
    write64(&image, 168, 1);

    @memcpy(image[176..180], "CODE");
    @memcpy(image[180..184], "DATA");
    return image;
}

fn findMapping(loaded: *const LoadedImage, virtual_address: u64) ?Mapping {
    for (loaded.mappings[0..loaded.mapping_count]) |mapping| {
        if (virtual_address >= mapping.virtual_address and
            virtual_address < mapping.virtual_address + mapping.byte_length)
        {
            return mapping;
        }
    }
    return null;
}

test "ELF loader copies PT_LOAD bytes, clears BSS, and builds an aligned argv/envp stack" {
    const std = @import("std");
    const image = testImage(2, 5, 0x20_2100);
    var arena: [64 * page_size]u8 align(page_size) = undefined;
    @memset(arena[0..], 0xaa);

    const loaded = try load(&image, arena[0..], .{
        .stack_size = 2 * page_size,
        .arguments = .{
            .argv = &.{"init", "--safe"},
            .envp = &.{"HOME=/"},
        },
    });

    try std.testing.expectEqual(@as(u64, 0x20_0100), loaded.entry);
    try std.testing.expectEqual(@as(usize, 3), loaded.mapping_count);
    try std.testing.expectEqual(@as(usize, 2), loaded.argument_count);
    try std.testing.expectEqual(@as(usize, 1), loaded.environment_count);

    const text_mapping = findMapping(&loaded, 0x20_0100).?;
    try std.testing.expect(text_mapping.readable);
    try std.testing.expect(text_mapping.executable);
    try std.testing.expect(!text_mapping.writable);
    const text_offset = text_mapping.backing_offset + 0x100;
    try std.testing.expect(std.mem.eql(u8, arena[text_offset .. text_offset + 4], "CODE"));
    try std.testing.expectEqual(@as(u8, 0), arena[text_offset + 4]);
    try std.testing.expectEqual(@as(u8, 0), arena[text_offset + 0x7f]);

    const data_mapping = findMapping(&loaded, 0x20_2100).?;
    try std.testing.expect(data_mapping.readable);
    try std.testing.expect(data_mapping.writable);
    try std.testing.expect(!data_mapping.executable);
    const data_offset = data_mapping.backing_offset + 0x100;
    try std.testing.expect(std.mem.eql(u8, arena[data_offset .. data_offset + 4], "DATA"));
    try std.testing.expectEqual(@as(u8, 0), arena[data_offset + 4]);
    try std.testing.expectEqual(@as(u8, 0), arena[data_offset + 4999]);

    const stack_mapping = findMapping(&loaded, loaded.stack_bottom).?;
    try std.testing.expect(stack_mapping.writable);
    try std.testing.expect(!stack_mapping.executable);
    try std.testing.expect(findMapping(&loaded, loaded.stack_guard_bottom) == null);

    const stack_offset = stack_mapping.backing_offset +
        @as(usize, @intCast(loaded.stack_pointer - loaded.stack_bottom));
    try std.testing.expectEqual(@as(usize, 0), stack_offset % 16);
    try std.testing.expectEqual(@as(u64, 2), readWord(arena[0..], stack_offset));

    const argv0 = readWord(arena[0..], stack_offset + 8);
    const argv1 = readWord(arena[0..], stack_offset + 16);
    try std.testing.expectEqual(@as(u64, 0), readWord(arena[0..], stack_offset + 24));
    const env0 = readWord(arena[0..], stack_offset + 32);
    try std.testing.expectEqual(@as(u64, 0), readWord(arena[0..], stack_offset + 40));
    try std.testing.expectEqual(@as(u64, at_pagesz), readWord(arena[0..], stack_offset + 48));
    try std.testing.expectEqual(@as(u64, page_size), readWord(arena[0..], stack_offset + 56));
    try std.testing.expectEqual(@as(u64, at_entry), readWord(arena[0..], stack_offset + 64));
    try std.testing.expectEqual(loaded.entry, readWord(arena[0..], stack_offset + 72));
    try std.testing.expectEqual(@as(u64, at_null), readWord(arena[0..], stack_offset + 80));
    try std.testing.expectEqual(@as(u64, 0), readWord(arena[0..], stack_offset + 88));

    const argv0_offset = stack_mapping.backing_offset +
        @as(usize, @intCast(argv0 - loaded.stack_bottom));
    const argv1_offset = stack_mapping.backing_offset +
        @as(usize, @intCast(argv1 - loaded.stack_bottom));
    const env0_offset = stack_mapping.backing_offset +
        @as(usize, @intCast(env0 - loaded.stack_bottom));
    try std.testing.expect(std.mem.eql(u8, arena[argv0_offset .. argv0_offset + 5], "init\x00"));
    try std.testing.expect(std.mem.eql(u8, arena[argv1_offset .. argv1_offset + 7], "--safe\x00"));
    try std.testing.expect(std.mem.eql(u8, arena[env0_offset .. env0_offset + 7], "HOME=/\x00"));
}

test "ELF loader rejects ET_DYN until relocation support exists" {
    const std = @import("std");
    const image = testImage(3, 5, 0x20_2100);
    var arena: [64 * page_size]u8 align(page_size) = undefined;
    try std.testing.expectError(error.UnsupportedImageType, load(&image, arena[0..], .{
        .stack_size = 2 * page_size,
    }));
}

test "ELF loader rejects writable executable pages and overlapping page mappings" {
    const std = @import("std");
    var arena: [64 * page_size]u8 align(page_size) = undefined;

    const writable_executable = testImage(2, 7, 0x20_2100);
    try std.testing.expectError(error.WritableExecutableSegment, load(
        &writable_executable,
        arena[0..],
        .{ .stack_size = 2 * page_size },
    ));

    const shared_page = testImage(2, 5, 0x20_0300);
    try std.testing.expectError(error.OverlappingLoadPages, load(
        &shared_page,
        arena[0..],
        .{ .stack_size = 2 * page_size },
    ));
}

test "ELF loader enforces stack layout, argument bounds, and arena capacity" {
    const std = @import("std");
    const image = testImage(2, 5, 0x20_2100);
    var arena: [64 * page_size]u8 align(page_size) = undefined;

    try std.testing.expectError(error.InvalidStackLayout, load(&image, arena[0..], .{
        .stack_size = page_size + 1,
    }));
    try std.testing.expectError(error.StackOverlapsLoadSegment, load(&image, arena[0..], .{
        .stack_top = 0x20_4000,
        .stack_size = 2 * page_size,
    }));

    const long_argv: [max_arguments + 1][]const u8 = @splat("a");
    try std.testing.expectError(error.TooManyArguments, load(&image, arena[0..], .{
        .stack_size = 2 * page_size,
        .arguments = .{ .argv = &long_argv },
    }));

    const nul_argument = [_]u8{ 'b', 'a', 'd', 0, 'a', 'r', 'g' };
    const embedded_nul = testImage(2, 5, 0x20_2100);
    try std.testing.expectError(error.InvalidArgumentString, load(&embedded_nul, arena[0..], .{
        .stack_size = 2 * page_size,
        .arguments = .{ .argv = &.{nul_argument[0..]} },
    }));

    const kernel_address = testImage(2, 5, 0xffff_8000_0020_2100);
    try std.testing.expectError(error.SegmentOutsideUserRange, load(&kernel_address, arena[0..], .{
        .stack_size = 2 * page_size,
    }));

    var small_arena: [4 * page_size]u8 align(page_size) = undefined;
    try std.testing.expectError(error.ArenaExhausted, load(&image, small_arena[0..], .{
        .stack_size = 2 * page_size,
    }));
}
