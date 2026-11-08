// SPDX-License-Identifier: BSD-2-Clause
//! Transactional bridge from Zweig resource policy to real seL4 object calls.
//!
//! This module never assumes that a multi-object Retype is a kernel
//! transaction. It reserves both destination slots and Untyped capacity
//! first, and quarantines uncertain resources whenever rollback cannot be
//! proven complete.

const cspace = @import("cspace_allocator.zig");
const untyped = @import("untyped_pool.zig");

pub const max_objects: usize = 32;
pub const max_batch: u32 = 32;
pub const cnode_word_depth: u64 = 64;

pub const Kind = enum(u8) {
    frame_4k = 1,
    endpoint = 2,
    notification = 3,
    tcb = 4,
    cnode = 5,
};

pub const ObjectHandle = struct {
    slot: u16,
    generation: u32,
};

pub const ObjectRequest = struct {
    owner: u64,
    kind: Kind,
    count: u32 = 1,
    memory_kind: untyped.MemoryKind = .normal,
    /// Used only for variable-sized CNode objects; this is the CNode radix.
    requested_size_bits: u8 = 0,
};

pub const Layout = struct {
    object_type: u64,
    retype_size_bits: u8,
    allocation_size_bits: u8,
};

pub const KernelOps = struct {
    context: ?*anyopaque = null,
    object_layout: *const fn (
        ?*anyopaque,
        u32,
        u8,
        *u64,
        *u8,
        *u8,
    ) callconv(.c) c_int,
    retype: *const fn (
        ?*anyopaque,
        u64,
        u64,
        u8,
        u64,
        u64,
        u64,
        u64,
        u32,
    ) callconv(.c) c_int,
    cnode_revoke: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) c_int,
    cnode_delete: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) c_int,
};

const RecordState = enum(u8) {
    free,
    live,
    destroying,
    quarantined,
};

const Record = struct {
    generation: u32 = 1,
    state: RecordState = .free,
    owner: u64 = 0,
    kind: Kind = .frame_4k,
    count: u32 = 0,
    slots: cspace.Lease = .{ .start = 0, .count = 0, .generation = 0, .owner = 0 },
    untyped_lease: untyped.Lease = .{
        .root = .{ .slot = 0, .generation = 0 },
        .owner = 0,
        .generation = 0,
        .offset = 0,
        .bytes = 0,
        .object_size_bits = 0,
        .count = 0,
    },
    revoke_done: [max_batch]bool = @splat(false),
    delete_done: [max_batch]bool = @splat(false),
    parent_revoke_done: bool = false,
};

pub const Error = error{
    InvalidOwner,
    InvalidCount,
    InvalidLayout,
    UnsupportedObject,
    ObjectTableFull,
    CSpaceExhausted,
    UntypedUnavailable,
    DeviceMemoryRestriction,
    KernelCallFailed,
    RollbackFailed,
    StaleObject,
    WrongOwner,
    InvalidState,
    ResourceQuarantined,
    InternalState,
};

pub const Manager = struct {
    slots: *cspace.Allocator,
    untyped_pool: *untyped.Pool,
    ops: KernelOps,
    /// CNode capability used as the root argument to Untyped_Retype. For this
    /// first implementation it must address the manager's own CSpace.
    destination_root_cnode: u64,
    destination_node_index: u64 = 0,
    destination_node_depth: u64 = 0,
    /// CPtr of the manager CSpace root used by CNode_Revoke/Delete.
    cspace_root_cnode: u64,
    objects: [max_objects]Record = @splat(.{}),

    pub fn init(
        slots: *cspace.Allocator,
        untyped_pool: *untyped.Pool,
        ops: KernelOps,
        destination_root_cnode: u64,
        cspace_root_cnode: u64,
    ) Manager {
        return .{
            .slots = slots,
            .untyped_pool = untyped_pool,
            .ops = ops,
            .destination_root_cnode = destination_root_cnode,
            .cspace_root_cnode = cspace_root_cnode,
        };
    }

    /// Create a homogeneous batch of kernel objects. The returned handle is
    /// metadata, never a seL4 CPtr; capCptr is an internal-only lookup helper.
    pub fn create(self: *Manager, request: ObjectRequest) Error!ObjectHandle {
        if (request.owner == 0) return error.InvalidOwner;
        if (request.count == 0 or request.count > max_batch) return error.InvalidCount;
        if (request.memory_kind == .device and request.kind != .frame_4k) {
            return error.DeviceMemoryRestriction;
        }
        if (request.kind != .cnode and request.requested_size_bits != 0) {
            return error.InvalidLayout;
        }
        const record_index = self.findFreeRecord() orelse return error.ObjectTableFull;

        var object_type: u64 = 0;
        var retype_size_bits: u8 = 0;
        var allocation_size_bits: u8 = 0;
        const layout_status = self.ops.object_layout(
            self.ops.context,
            @as(u32, @backingInt(request.kind)),
            request.requested_size_bits,
            &object_type,
            &retype_size_bits,
            &allocation_size_bits,
        );
        if (layout_status != 0 or allocation_size_bits < 4 or allocation_size_bits >= 63) {
            return error.InvalidLayout;
        }

        const slot_lease = self.slots.reserve(request.owner, request.count) catch {
            return error.CSpaceExhausted;
        };
        const object_memory: untyped.ObjectMemory =
            if (request.kind == .frame_4k) .frame else .kernel_object;
        const untyped_lease = self.untyped_pool.acquire(
            request.owner,
            object_memory,
            request.memory_kind,
            allocation_size_bits,
            request.count,
        ) catch |err| {
            self.slots.release(slot_lease) catch {
                self.quarantineSlotReservation(record_index, request, slot_lease);
                return error.InternalState;
            };
            if (err == error.DeviceMemoryRestriction) return error.DeviceMemoryRestriction;
            return error.UntypedUnavailable;
        };
        const untyped_cptr = self.untyped_pool.rootCap(untyped_lease) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.InternalState;
        };
        const first_slot = self.slots.cptr(slot_lease, 0) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.InternalState;
        };

        const retype_status = self.ops.retype(
            self.ops.context,
            untyped_cptr,
            object_type,
            retype_size_bits,
            self.destination_root_cnode,
            self.destination_node_index,
            self.destination_node_depth,
            first_slot,
            request.count,
        );
        if (retype_status != 0) {
            return self.rollbackFailedCreate(record_index, request, slot_lease, untyped_lease);
        }

        self.slots.markInstalled(slot_lease) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.InternalState;
        };

        const record = &self.objects[record_index];
        record.state = .live;
        record.owner = request.owner;
        record.kind = request.kind;
        record.count = request.count;
        record.slots = slot_lease;
        record.untyped_lease = untyped_lease;
        record.revoke_done = @splat(false);
        record.delete_done = @splat(false);
        record.parent_revoke_done = false;

        return .{
            .slot = @intCast(record_index),
            .generation = record.generation,
        };
    }

    /// Return a CPtr only to trusted code executing in this same CSpace.
    pub fn capCptr(self: *const Manager, handle: ObjectHandle, owner: u64, index: u32) Error!u64 {
        const record = try self.getRecord(handle);
        if (record.state != .live) return error.InvalidState;
        if (record.owner != owner) return error.WrongOwner;
        return self.slots.cptr(record.slots, index) catch return error.StaleObject;
    }

    /// Destroy is retryable. Per-slot revoke/delete progress is committed only
    /// after the corresponding kernel invocation succeeds.
    pub fn destroy(self: *Manager, handle: ObjectHandle, owner: u64) Error!void {
        const record = try self.getRecordMut(handle);
        if (record.owner != owner) return error.WrongOwner;
        if (record.state == .quarantined) return error.ResourceQuarantined;
        if (record.state != .live and record.state != .destroying) return error.InvalidState;
        record.state = .destroying;

        var index: u32 = 0;
        while (index < record.count) : (index += 1) {
            const slot_cptr = self.slots.cptr(record.slots, index) catch {
                self.quarantineRecord(record);
                return error.InternalState;
            };
            const progress_index: usize = @intCast(index);
            if (!record.revoke_done[progress_index]) {
                const status = self.ops.cnode_revoke(
                    self.ops.context,
                    self.cspace_root_cnode,
                    slot_cptr,
                    cnode_word_depth,
                );
                if (status != 0) return error.KernelCallFailed;
                record.revoke_done[progress_index] = true;
            }
            if (!record.delete_done[progress_index]) {
                const status = self.ops.cnode_delete(
                    self.ops.context,
                    self.cspace_root_cnode,
                    slot_cptr,
                    cnode_word_depth,
                );
                if (status != 0) return error.KernelCallFailed;
                self.slots.markSlotDeleted(record.slots, index) catch {
                    self.quarantineRecord(record);
                    return error.InternalState;
                };
                record.delete_done[progress_index] = true;
            }
        }

        if (!record.parent_revoke_done) {
            self.untyped_pool.markPendingReclaim(record.untyped_lease) catch {
                self.quarantineRecord(record);
                return error.InternalState;
            };
            const untyped_cptr = self.untyped_pool.rootCap(record.untyped_lease) catch {
                self.quarantineRecord(record);
                return error.InternalState;
            };
            const status = self.ops.cnode_revoke(
                self.ops.context,
                self.cspace_root_cnode,
                untyped_cptr,
                cnode_word_depth,
            );
            if (status != 0) {
                self.quarantineRecord(record);
                return error.KernelCallFailed;
            }
            self.untyped_pool.confirmRevokedAndReclaim(record.untyped_lease) catch {
                self.quarantineRecord(record);
                return error.InternalState;
            };
            record.parent_revoke_done = true;
        }

        self.slots.release(record.slots) catch return error.InternalState;
        const generation = nextGeneration(record.generation);
        record.* = .{ .generation = generation };
    }

    pub fn activeObjectCount(self: *const Manager) usize {
        var count: usize = 0;
        for (self.objects) |record| {
            if (record.state == .live or record.state == .destroying or record.state == .quarantined) {
                count += 1;
            }
        }
        return count;
    }

    fn rollbackFailedCreate(
        self: *Manager,
        record_index: usize,
        request: ObjectRequest,
        slot_lease: cspace.Lease,
        untyped_lease: untyped.Lease,
    ) Error!ObjectHandle {
        self.untyped_pool.markPendingReclaim(untyped_lease) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.RollbackFailed;
        };
        const untyped_cptr = self.untyped_pool.rootCap(untyped_lease) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.RollbackFailed;
        };
        const status = self.ops.cnode_revoke(
            self.ops.context,
            self.cspace_root_cnode,
            untyped_cptr,
            cnode_word_depth,
        );
        if (status != 0) {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.RollbackFailed;
        }
        self.untyped_pool.confirmRevokedAndReclaim(untyped_lease) catch {
            self.quarantineNewRecord(record_index, request, slot_lease, untyped_lease);
            return error.RollbackFailed;
        };
        self.slots.release(slot_lease) catch {
            self.quarantineSlotReservation(record_index, request, slot_lease);
            return error.RollbackFailed;
        };
        return error.KernelCallFailed;
    }

    fn quarantineNewRecord(
        self: *Manager,
        record_index: usize,
        request: ObjectRequest,
        slot_lease: cspace.Lease,
        untyped_lease: untyped.Lease,
    ) void {
        self.untyped_pool.quarantine(untyped_lease) catch {};
        self.slots.quarantine(slot_lease) catch {};
        self.recordQuarantined(record_index, request, slot_lease, untyped_lease);
    }

    fn quarantineSlotReservation(
        self: *Manager,
        record_index: usize,
        request: ObjectRequest,
        slot_lease: cspace.Lease,
    ) void {
        self.slots.quarantine(slot_lease) catch {};
        const record = &self.objects[record_index];
        record.state = .quarantined;
        record.owner = request.owner;
        record.kind = request.kind;
        record.count = request.count;
        record.slots = slot_lease;
    }

    fn recordQuarantined(
        self: *Manager,
        record_index: usize,
        request: ObjectRequest,
        slot_lease: cspace.Lease,
        untyped_lease: untyped.Lease,
    ) void {
        const record = &self.objects[record_index];
        record.state = .quarantined;
        record.owner = request.owner;
        record.kind = request.kind;
        record.count = request.count;
        record.slots = slot_lease;
        record.untyped_lease = untyped_lease;
    }

    fn quarantineRecord(self: *Manager, record: *Record) void {
        self.untyped_pool.quarantine(record.untyped_lease) catch {};
        self.slots.quarantine(record.slots) catch {};
        record.state = .quarantined;
    }

    fn findFreeRecord(self: *const Manager) ?usize {
        for (self.objects, 0..) |record, index| {
            if (record.state == .free) return index;
        }
        return null;
    }

    fn getRecord(self: *const Manager, handle: ObjectHandle) Error!*const Record {
        const index: usize = handle.slot;
        if (index >= max_objects) return error.StaleObject;
        const record = &self.objects[index];
        if (record.state == .free or record.generation != handle.generation) return error.StaleObject;
        return record;
    }

    fn getRecordMut(self: *Manager, handle: ObjectHandle) Error!*Record {
        const index: usize = handle.slot;
        if (index >= max_objects) return error.StaleObject;
        const record = &self.objects[index];
        if (record.state == .free or record.generation != handle.generation) return error.StaleObject;
        return record;
    }
};

fn nextGeneration(value: u32) u32 {
    const next = value +% 1;
    return if (next == 0) 1 else next;
}

test "object manager repeats create and destroy without leaking slots or Untyped roots" {
    const std = @import("std");
    var slots = try cspace.Allocator.init(0x100, 32);
    var pool = untyped.Pool{};
    _ = try pool.registerRoot(0x80, 0x20_0000, 16, .normal);
    var mock = Mock{};
    var manager = Manager.init(&slots, &pool, mock.ops(), 1, 1);

    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        const handle = try manager.create(.{ .owner = 1, .kind = .endpoint });
        try std.testing.expectEqual(@as(u64, 0x100), try manager.capCptr(handle, 1, 0));
        try manager.destroy(handle, 1);
        try std.testing.expectEqual(@as(usize, 32), slots.freeCount());
        try std.testing.expectEqual(@as(usize, 1), pool.freeRootCount());
        try std.testing.expectEqual(@as(usize, 0), manager.activeObjectCount());
    }
}

test "object manager rolls back a failed Retype when root revoke succeeds" {
    const std = @import("std");
    var slots = try cspace.Allocator.init(0x200, 8);
    var pool = untyped.Pool{};
    _ = try pool.registerRoot(0x90, 0x30_0000, 16, .normal);
    var mock = Mock{ .fail_retype = true };
    var manager = Manager.init(&slots, &pool, mock.ops(), 1, 1);

    try std.testing.expectError(
        error.KernelCallFailed,
        manager.create(.{ .owner = 2, .kind = .tcb }),
    );
    try std.testing.expectEqual(@as(usize, 8), slots.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.freeRootCount());
    try std.testing.expectEqual(@as(u32, 1), mock.revoke_calls);
}

test "object manager quarantines resources when Retype rollback fails" {
    const std = @import("std");
    var slots = try cspace.Allocator.init(0x300, 8);
    var pool = untyped.Pool{};
    _ = try pool.registerRoot(0xa0, 0x40_0000, 16, .normal);
    var mock = Mock{ .fail_retype = true, .fail_revoke_call = 1 };
    var manager = Manager.init(&slots, &pool, mock.ops(), 1, 1);

    try std.testing.expectError(
        error.RollbackFailed,
        manager.create(.{ .owner = 3, .kind = .frame_4k }),
    );
    // Exactly the one reserved destination slot is quarantined; the other
    // seven slots remain available to unrelated allocations.
    try std.testing.expectEqual(@as(usize, 7), slots.freeCount());
    try std.testing.expectEqual(@as(usize, 0), pool.freeRootCount());
}

test "object manager resumes partial destroy without repeating completed deletes" {
    const std = @import("std");
    var slots = try cspace.Allocator.init(0x400, 8);
    var pool = untyped.Pool{};
    _ = try pool.registerRoot(0xb0, 0x50_0000, 16, .normal);
    var mock = Mock{ .fail_delete_call = 2 };
    var manager = Manager.init(&slots, &pool, mock.ops(), 1, 1);
    const handle = try manager.create(.{ .owner = 4, .kind = .endpoint, .count = 2 });

    try std.testing.expectError(error.KernelCallFailed, manager.destroy(handle, 4));
    try std.testing.expectEqual(@as(u32, 2), mock.delete_calls);
    mock.fail_delete_call = 0;
    try manager.destroy(handle, 4);
    try std.testing.expectEqual(@as(u32, 3), mock.delete_calls);
    try std.testing.expectEqual(@as(usize, 8), slots.freeCount());
    try std.testing.expectEqual(@as(usize, 1), pool.freeRootCount());
    try std.testing.expectError(error.StaleObject, manager.destroy(handle, 4));
}

const Mock = struct {
    fail_retype: bool = false,
    fail_revoke_call: u32 = 0,
    fail_delete_call: u32 = 0,
    revoke_calls: u32 = 0,
    delete_calls: u32 = 0,

    fn ops(self: *Mock) KernelOps {
        return .{
            .context = self,
            .object_layout = layout,
            .retype = retype,
            .cnode_revoke = revoke,
            .cnode_delete = delete,
        };
    }

    fn layout(
        context: ?*anyopaque,
        kind: u32,
        requested_size_bits: u8,
        object_type_out: *u64,
        retype_size_bits_out: *u8,
        allocation_size_bits_out: *u8,
    ) callconv(.c) c_int {
        _ = context;
        if (kind < 1 or kind > 5) return -95;
        object_type_out.* = @as(u64, 0x100) + @as(u64, kind);
        if (kind == 5) {
            if (requested_size_bits == 0 or requested_size_bits > 59) return -22;
            retype_size_bits_out.* = requested_size_bits;
            allocation_size_bits_out.* = requested_size_bits + 4;
        } else {
            retype_size_bits_out.* = 0;
            allocation_size_bits_out.* = switch (kind) {
                1 => 12,
                2 => 6,
                3 => 6,
                4 => 11,
                else => 6,
            };
        }
        return 0;
    }

    fn retype(
        context: ?*anyopaque,
        untyped_cptr: u64,
        object_type: u64,
        size_bits: u8,
        root: u64,
        node_index: u64,
        node_depth: u64,
        node_offset: u64,
        count: u32,
    ) callconv(.c) c_int {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = untyped_cptr;
        _ = object_type;
        _ = size_bits;
        _ = root;
        _ = node_index;
        _ = node_depth;
        _ = node_offset;
        _ = count;
        return if (self.fail_retype) -1 else 0;
    }

    fn revoke(
        context: ?*anyopaque,
        root: u64,
        index: u64,
        depth: u64,
    ) callconv(.c) c_int {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = root;
        _ = index;
        _ = depth;
        self.revoke_calls += 1;
        return if (self.fail_revoke_call == self.revoke_calls) -1 else 0;
    }

    fn delete(
        context: ?*anyopaque,
        root: u64,
        index: u64,
        depth: u64,
    ) callconv(.c) c_int {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = root;
        _ = index;
        _ = depth;
        self.delete_calls += 1;
        return if (self.fail_delete_call == self.delete_calls) -1 else 0;
    }
};
