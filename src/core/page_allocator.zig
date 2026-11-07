// SPDX-License-Identifier: BSD-2-Clause
//! Fixed-size contiguous page allocator for a Microkit-mapped memory region.
//!
//! This manages pages inside an arena already mapped into the memory-manager
//! Protection Domain. It does not create seL4 Frame capabilities or map pages
//! into another VSpace; those operations require an Untyped/CSpace authority
//! path and are intentionally deferred.

pub const page_size: usize = 4096;
pub const max_pages: usize = 256;
pub const max_leases: usize = 64;

pub const Lease = struct {
    token: u64,
    first_page: u16,
    page_count: u16,
};

const LeaseSlot = struct {
    generation: u32 = 1,
    active: bool = false,
    first_page: u16 = 0,
    page_count: u16 = 0,
};

pub const PageAllocator = struct {
    arena: []u8,
    page_count: usize,
    allocated: [max_pages]bool,
    leases: [max_leases]LeaseSlot,

    pub const InitError = error{
        EmptyArena,
        MisalignedArena,
        InvalidArenaSize,
        ArenaTooLarge,
    };

    pub const AllocError = error{
        InvalidPageCount,
        OutOfMemory,
        LeaseTableFull,
    };

    pub const ReleaseError = error{
        InvalidToken,
        StaleToken,
        CorruptState,
    };

    pub fn init(arena: []u8) InitError!PageAllocator {
        if (arena.len == 0) return error.EmptyArena;
        if (@intFromPtr(arena.ptr) % page_size != 0) return error.MisalignedArena;
        if (arena.len % page_size != 0) return error.InvalidArenaSize;

        const count = arena.len / page_size;
        if (count > max_pages) return error.ArenaTooLarge;

        return .{
            .arena = arena,
            .page_count = count,
            .allocated = [_]bool{false} ** max_pages,
            .leases = [_]LeaseSlot{.{}} ** max_leases,
        };
    }

    pub fn allocate(self: *PageAllocator, requested_pages: usize) AllocError!Lease {
        if (requested_pages == 0 or requested_pages > self.page_count) {
            return error.InvalidPageCount;
        }

        var free_slot: ?usize = null;
        for (self.leases, 0..) |slot, index| {
            if (!slot.active) {
                free_slot = index;
                break;
            }
        }
        const lease_index = free_slot orelse return error.LeaseTableFull;

        var run_start: usize = 0;
        var run_length: usize = 0;
        var found_start: ?usize = null;

        for (0..self.page_count) |page_index| {
            if (self.allocated[page_index]) {
                run_length = 0;
                continue;
            }

            if (run_length == 0) run_start = page_index;
            run_length += 1;
            if (run_length == requested_pages) {
                found_start = run_start;
                break;
            }
        }

        const first_page = found_start orelse return error.OutOfMemory;
        const end_page = first_page + requested_pages;
        for (first_page..end_page) |page_index| {
            self.allocated[page_index] = true;
        }

        const byte_start = first_page * page_size;
        const byte_end = end_page * page_size;
        @memset(self.arena[byte_start..byte_end], 0);

        const slot = &self.leases[lease_index];
        slot.active = true;
        slot.first_page = @intCast(first_page);
        slot.page_count = @intCast(requested_pages);

        const token = (@as(u64, slot.generation) << 32) | @as(u64, @intCast(lease_index));
        return .{
            .token = token,
            .first_page = slot.first_page,
            .page_count = slot.page_count,
        };
    }

    pub fn release(self: *PageAllocator, token: u64) ReleaseError!void {
        const lease_index: usize = @intCast(token & 0xffff_ffff);
        const generation: u32 = @truncate(token >> 32);
        if (lease_index >= max_leases) return error.InvalidToken;

        const slot = &self.leases[lease_index];
        if (!slot.active or slot.generation != generation) return error.StaleToken;

        const first_page: usize = slot.first_page;
        const end_page = first_page + @as(usize, slot.page_count);
        if (end_page > self.page_count) return error.CorruptState;

        for (first_page..end_page) |page_index| {
            if (!self.allocated[page_index]) return error.CorruptState;
        }
        for (first_page..end_page) |page_index| {
            self.allocated[page_index] = false;
        }

        slot.active = false;
        slot.first_page = 0;
        slot.page_count = 0;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    pub fn freePages(self: *const PageAllocator) usize {
        var free_count: usize = 0;
        for (0..self.page_count) |index| {
            if (!self.allocated[index]) free_count += 1;
        }
        return free_count;
    }

    pub fn totalPages(self: *const PageAllocator) usize {
        return self.page_count;
    }
};

test "allocator reserves contiguous pages, zeroes them, and releases them" {
    const std = @import("std");
    var backing: [8 * page_size]u8 align(page_size) = undefined;
    @memset(backing[0..], 0xaa);

    var allocator = try PageAllocator.init(backing[0..]);
    const lease = try allocator.allocate(3);

    try std.testing.expectEqual(@as(usize, 5), allocator.freePages());
    try std.testing.expectEqual(@as(usize, 0), lease.first_page);
    try std.testing.expectEqual(@as(u8, 0), backing[0]);
    try std.testing.expectEqual(@as(u8, 0), backing[3 * page_size - 1]);

    try allocator.release(lease.token);
    try std.testing.expectEqual(@as(usize, 8), allocator.freePages());
    try std.testing.expectError(error.StaleToken, allocator.release(lease.token));
}

test "allocator rejects zero and oversized requests without changing state" {
    const std = @import("std");
    var backing: [4 * page_size]u8 align(page_size) = undefined;
    var allocator = try PageAllocator.init(backing[0..]);

    try std.testing.expectError(error.InvalidPageCount, allocator.allocate(0));
    try std.testing.expectError(error.InvalidPageCount, allocator.allocate(5));
    try std.testing.expectEqual(@as(usize, 4), allocator.freePages());
}

test "allocator detects fragmentation when a contiguous run is unavailable" {
    const std = @import("std");
    var backing: [6 * page_size]u8 align(page_size) = undefined;
    var allocator = try PageAllocator.init(backing[0..]);

    const a = try allocator.allocate(2);
    const b = try allocator.allocate(2);
    const c = try allocator.allocate(2);
    try allocator.release(b.token);
    try std.testing.expectError(error.OutOfMemory, allocator.allocate(3));

    try allocator.release(a.token);
    try allocator.release(c.token);
    try std.testing.expectEqual(@as(usize, 6), allocator.freePages());
}
