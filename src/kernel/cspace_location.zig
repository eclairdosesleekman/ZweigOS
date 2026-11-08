// SPDX-License-Identifier: BSD-2-Clause
//! Addressable CSpace catalogue. Locations are Zweig identities, not CPtrs.

const cspace = @import("cspace_allocator.zig");\nconst std = @import("std");
pub const max_spaces: usize = 8;
pub const max_cnode_depth: usize = 4;
pub const word_depth: u64 = 64;

pub const SpaceId = struct { slot: u16, generation: u32 };
pub const CSpaceLocation = struct {
    space: SpaceId,
    cnode_path: [max_cnode_depth]u32 = @splat(0),
    path_length: u8 = 0,
    slot: u32,
};
pub const SlotPath = struct { root: u64, index: u64, depth: u64 };

const Space = struct {
    active: bool = false,
    generation: u32 = 1,
    root_cnode_cptr: u64 = 0,
    allocator: cspace.Allocator = undefined,
};

pub const Error = error{
    InvalidSpace, SpaceTableFull, StaleSpace, UnsupportedCNodePath,
    SlotOutOfRange, AllocationFailed,
};

pub const Catalog = struct {
    spaces: [max_spaces]Space = @splat(.{}),

    /// root_cnode_cptr is held by the Resource Manager, never supplied by a client.
    pub fn register(self: *Catalog, root_cnode_cptr: u64, first_slot: u64, capacity: u16) Error!SpaceId {
        if (root_cnode_cptr == 0 or first_slot == 0 or capacity == 0) return error.InvalidSpace;
        const allocator = cspace.Allocator.init(first_slot, capacity) catch return error.InvalidSpace;
        for (&self.spaces, 0..) |*space, index| {
            if (space.active) continue;
            space.* = .{
                .active = true, .generation = space.generation,
                .root_cnode_cptr = root_cnode_cptr, .allocator = allocator,
            };
            return .{ .slot = @intCast(index), .generation = space.generation };
        }
        return error.SpaceTableFull;
    }

    pub fn reserve(self: *Catalog, id: SpaceId, owner: u64, count: u32) Error!cspace.Lease {
        const space = self.getSpace(id) orelse return error.StaleSpace;
        return space.allocator.reserve(owner, count) catch return error.AllocationFailed;
    }

    pub fn location(self: *const Catalog, id: SpaceId, lease: cspace.Lease, index: u32) Error!CSpaceLocation {
        const space = self.getSpaceConst(id) orelse return error.StaleSpace;
        const local_cptr = space.allocator.cptr(lease, index) catch return error.SlotOutOfRange;
        if (local_cptr > std.math.maxInt(u32)) return error.SlotOutOfRange;
        return .{ .space = id, .slot = @intCast(local_cptr) };
    }

    pub fn slotPath(self: *const Catalog, location_value: CSpaceLocation) Error!SlotPath {
        if (location_value.path_length != 0) return error.UnsupportedCNodePath;
        const space = self.getSpaceConst(location_value.space) orelse return error.StaleSpace;
        if (location_value.slot == 0) return error.SlotOutOfRange;
        return .{ .root = space.root_cnode_cptr, .index = location_value.slot, .depth = word_depth };
    }

    pub fn markInstalled(self: *Catalog, id: SpaceId, lease: cspace.Lease) Error!void {
        const space = self.getSpace(id) orelse return error.StaleSpace;
        space.allocator.markInstalled(lease) catch return error.AllocationFailed;
    }
    pub fn markDeleted(self: *Catalog, id: SpaceId, lease: cspace.Lease, index: u32) Error!void {
        const space = self.getSpace(id) orelse return error.StaleSpace;
        space.allocator.markSlotDeleted(lease, index) catch return error.AllocationFailed;
    }
    pub fn release(self: *Catalog, id: SpaceId, lease: cspace.Lease) Error!void {
        const space = self.getSpace(id) orelse return error.StaleSpace;
        space.allocator.release(lease) catch return error.AllocationFailed;
    }
    pub fn quarantine(self: *Catalog, id: SpaceId, lease: cspace.Lease) Error!void {
        const space = self.getSpace(id) orelse return error.StaleSpace;
        space.allocator.quarantine(lease) catch return error.AllocationFailed;
    }
    pub fn freeCount(self: *const Catalog, id: SpaceId) Error!usize {
        const space = self.getSpaceConst(id) orelse return error.StaleSpace;
        return space.allocator.freeCount();
    }

    fn getSpace(self: *Catalog, id: SpaceId) ?*Space {
        const index: usize = id.slot;
        if (index >= max_spaces) return null;
        const space = &self.spaces[index];
        if (!space.active or space.generation != id.generation) return null;
        return space;
    }
    fn getSpaceConst(self: *const Catalog, id: SpaceId) ?*const Space {
        const index: usize = id.slot;
        if (index >= max_spaces) return null;
        const space = &self.spaces[index];
        if (!space.active or space.generation != id.generation) return null;
        return space;
    }
};

test "CSpace catalog resolves opaque locations without treating them as CPtrs" {
    const std = @import("std");
    var catalog = Catalog{};
    const source = try catalog.register(0x40, 0x10, 8);
    const destination = try catalog.register(0x41, 0x20, 8);
    const lease = try catalog.reserve(destination, 7, 1);
    const location_value = try catalog.location(destination, lease, 0);
    try std.testing.expectEqual(destination.slot, location_value.space.slot);
    const path = try catalog.slotPath(location_value);
    try std.testing.expectEqual(@as(u64, 0x41), path.root);
    try std.testing.expectEqual(@as(u64, 0x20), path.index);
    try std.testing.expectEqual(word_depth, path.depth);
    try std.testing.expect(source.slot != destination.slot);
    try std.testing.expectError(error.UnsupportedCNodePath, catalog.slotPath(.{
        .space = source, .cnode_path = .{ 1, 0, 0, 0 }, .path_length = 1, .slot = 1,
    }));
}
