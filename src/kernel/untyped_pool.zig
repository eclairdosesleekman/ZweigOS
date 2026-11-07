// SPDX-License-Identifier: BSD-2-Clause
//! Conservative Untyped pool planner.
//!
//! One root Untyped capability is leased to at most one object batch at a
//! time. Its allocation cursor is reset only after the caller has successfully
//! invoked CNode_Revoke on that root capability. Deleting child caps alone is
//! deliberately not treated as proof that the Untyped watermark was reclaimed.

pub const max_roots: usize = 8;
pub const max_batch: u32 = 32;

pub const MemoryKind = enum(u8) {
    normal,
    device,
};

pub const ObjectMemory = enum(u8) {
    frame,
    kernel_object,
};

pub const RootId = struct {
    slot: u8,
    generation: u32,
};

pub const Lease = struct {
    root: RootId,
    owner: u64,
    generation: u32,
    offset: u64,
    bytes: u64,
    object_size_bits: u8,
    count: u32,
};

const RootState = enum(u8) {
    free,
    leased,
    pending_reclaim,
    quarantined,
};

const Root = struct {
    active: bool = false,
    generation: u32 = 1,
    cap_cptr: u64 = 0,
    physical_base: u64 = 0,
    size_bits: u8 = 0,
    memory_kind: MemoryKind = .normal,
    cursor: u64 = 0,
    state: RootState = .free,
    lease_generation: u32 = 0,
    lease_owner: u64 = 0,
};

pub const Error = error{
    InvalidRoot,
    RootTableFull,
    DuplicateRoot,
    InvalidOwner,
    InvalidCount,
    InvalidObjectSize,
    MisalignedRoot,
    AddressOverflow,
    OutOfMemory,
    DeviceMemoryRestriction,
    StaleLease,
    WrongOwner,
    InvalidState,
};

pub const Pool = struct {
    roots: [max_roots]Root = @splat(.{}),
    next_lease_generation: u32 = 1,

    /// Register a root Untyped cap explicitly supplied by trusted bootstrap
    /// code. The cap CPtr is local to the manager's CSpace.
    pub fn registerRoot(
        self: *Pool,
        cap_cptr: u64,
        physical_base: u64,
        size_bits: u8,
        memory_kind: MemoryKind,
    ) Error!RootId {
        if (cap_cptr == 0 or size_bits < 12 or size_bits >= 63) {
            return error.InvalidRoot;
        }
        const size: u64 = @as(u64, 1) << @as(u6, @intCast(size_bits));
        if ((physical_base & (size - 1)) != 0) return error.MisalignedRoot;
        const end = @addWithOverflow(physical_base, size);
        if (end[1] != 0) return error.AddressOverflow;

        for (self.roots) |root| {
            if (root.active and root.cap_cptr == cap_cptr) return error.DuplicateRoot;
        }
        for (&self.roots, 0..) |*root, index| {
            if (root.active) continue;
            const generation = root.generation;
            root.* = .{
                .active = true,
                .generation = generation,
                .cap_cptr = cap_cptr,
                .physical_base = physical_base,
                .size_bits = size_bits,
                .memory_kind = memory_kind,
                .cursor = 0,
                .state = .free,
            };
            return .{ .slot = @intCast(index), .generation = generation };
        }
        return error.RootTableFull;
    }

    /// Reserve a correctly aligned region in one currently idle root.
    /// Device Untyped memory can only back frames, never kernel objects.
    pub fn acquire(
        self: *Pool,
        owner: u64,
        object_memory: ObjectMemory,
        memory_kind: MemoryKind,
        object_size_bits: u8,
        count: u32,
    ) Error!Lease {
        if (owner == 0) return error.InvalidOwner;
        if (count == 0 or count > max_batch) return error.InvalidCount;
        if (memory_kind == .device and object_memory != .frame) {
            return error.DeviceMemoryRestriction;
        }
        if (object_size_bits < 4 or object_size_bits >= 63) {
            return error.InvalidObjectSize;
        }

        const object_bytes: u64 = @as(u64, 1) << @as(u6, @intCast(object_size_bits));
        const requested = @mulWithOverflow(object_bytes, @as(u64, count));
        if (requested[1] != 0) return error.AddressOverflow;

        for (&self.roots, 0..) |*root, index| {
            if (!root.active or root.state != .free) continue;
            if (root.memory_kind != memory_kind) continue;

            const root_bytes: u64 = @as(u64, 1) << @as(u6, @intCast(root.size_bits));
            const aligned = alignForward(root.cursor, object_bytes) orelse continue;
            const end = @addWithOverflow(aligned, requested[0]);
            if (end[1] != 0 or end[0] > root_bytes) continue;

            const generation = self.next_lease_generation;
            self.next_lease_generation = nextGeneration(self.next_lease_generation);
            root.cursor = end[0];
            root.state = .leased;
            root.lease_generation = generation;
            root.lease_owner = owner;

            return .{
                .root = .{ .slot = @intCast(index), .generation = root.generation },
                .owner = owner,
                .generation = generation,
                .offset = aligned,
                .bytes = requested[0],
                .object_size_bits = object_size_bits,
                .count = count,
            };
        }

        return error.OutOfMemory;
    }

    pub fn rootCap(self: *const Pool, lease: Lease) Error!u64 {
        const root = try self.getRoot(lease);
        return root.cap_cptr;
    }

    /// Mark all child objects as deleted and make the root eligible for the
    /// mandatory parent-revoke step. Repeated calls are safe for cleanup retry.
    pub fn markPendingReclaim(self: *Pool, lease: Lease) Error!void {
        const root = try self.getRoot(lease);
        switch (root.state) {
            .leased => root.state = .pending_reclaim,
            .pending_reclaim => {},
            else => return error.InvalidState,
        }
    }

    /// Call only after CNode_Revoke(root Untyped cap) returned success. The
    /// root capability itself remains registered and may serve the next lease.
    pub fn confirmRevokedAndReclaim(self: *Pool, lease: Lease) Error!void {
        const root = try self.getRoot(lease);
        if (root.state != .pending_reclaim) return error.InvalidState;
        root.cursor = 0;
        root.state = .free;
        root.lease_generation = 0;
        root.lease_owner = 0;
    }

    pub fn quarantine(self: *Pool, lease: Lease) Error!void {
        const root = try self.getRoot(lease);
        root.state = .quarantined;
    }

    pub fn isAvailable(self: *const Pool, id: RootId) bool {
        const root = self.getRootById(id) orelse return false;
        return root.state == .free;
    }

    pub fn freeRootCount(self: *const Pool) usize {
        var count: usize = 0;
        for (self.roots) |root| {
            if (root.active and root.state == .free) count += 1;
        }
        return count;
    }


    fn getRoot(self: *Pool, lease: Lease) Error!*Root {
        const index: usize = lease.root.slot;
        if (index >= max_roots) return error.StaleLease;
        const root = &self.roots[index];
        if (!root.active or root.generation != lease.root.generation or
            root.lease_generation != lease.generation)
        {
            return error.StaleLease;
        }
        if (root.lease_owner != lease.owner) return error.WrongOwner;
        if (root.state != .leased and root.state != .pending_reclaim and root.state != .quarantined) {
            return error.StaleLease;
        }
        return root;
    }

    fn getRootById(self: *const Pool, id: RootId) ?*const Root {
        const index: usize = id.slot;
        if (index >= max_roots) return null;
        const root = &self.roots[index];
        if (!root.active or root.generation != id.generation) return null;
        return root;
    }
};

fn alignForward(value: u64, alignment: u64) ?u64 {
    const sum = @addWithOverflow(value, alignment - 1);
    if (sum[1] != 0) return null;
    return sum[0] & ~(alignment - 1);
}

fn nextGeneration(value: u32) u32 {
    const next = value +% 1;
    return if (next == 0) 1 else next;
}

test "Untyped pool enforces capacity, alignment, and explicit revoke before reuse" {
    const std = @import("std");
    var pool = Pool{};
    const root = try pool.registerRoot(0x30, 0x20_0000, 16, .normal);
    const lease = try pool.acquire(1, .kernel_object, .normal, 6, 2);
    try std.testing.expectEqual(@as(u64, 0), lease.offset);
    try std.testing.expectEqual(@as(u64, 128), lease.bytes);
    try pool.markPendingReclaim(lease);
    try std.testing.expectEqual(@as(usize, 0), pool.freeRootCount());
    try pool.confirmRevokedAndReclaim(lease);
    try std.testing.expect(pool.isAvailable(root));
    try std.testing.expectEqual(@as(usize, 1), pool.freeRootCount());
    try std.testing.expectError(error.StaleLease, pool.rootCap(lease));
}

test "device Untyped memory refuses kernel objects but may back frames" {
    const std = @import("std");
    var pool = Pool{};
    _ = try pool.registerRoot(0x31, 0x40_0000, 16, .device);
    try std.testing.expectError(
        error.DeviceMemoryRestriction,
        pool.acquire(2, .kernel_object, .device, 6, 1),
    );
    const frame = try pool.acquire(2, .frame, .device, 12, 1);
    try std.testing.expectEqual(@as(u64, 4096), frame.bytes);
}

test "Untyped pool quarantines uncertain roots" {
    const std = @import("std");
    var pool = Pool{};
    _ = try pool.registerRoot(0x32, 0x60_0000, 16, .normal);
    const lease = try pool.acquire(3, .frame, .normal, 12, 1);
    try pool.quarantine(lease);
    try std.testing.expectEqual(@as(usize, 0), pool.freeRootCount());
    try std.testing.expectError(error.InvalidState, pool.markPendingReclaim(lease));
}
