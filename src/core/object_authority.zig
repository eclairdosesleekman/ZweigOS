// SPDX-License-Identifier: BSD-2-Clause
//! Bounded, generation-checked authority ledger for future seL4 objects.
//!
//! This records who may use a reserved kernel-object resource and which
//! rights were delegated. It does not allocate CSpace slots, retype Untyped
//! memory, mint seL4 capabilities, or invoke the seL4 kernel.

const process = @import("process.zig");

pub const page_size: u64 = 4096;
pub const max_objects: usize = 64;
pub const max_capabilities: usize = 128;
pub const max_batch: usize = 24;

pub const Kind = enum(u8) {
    frame_region,
    endpoint,
    notification,
    tcb,
    cnode,
    vspace,
    scheduling_context,
    untyped,
};

pub const Rights = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    map: bool = false,
    invoke: bool = false,
    manage: bool = false,
    grant: bool = false,
    reserved: u1 = 0,

    pub fn allows(self: Rights, requested: Rights) bool {
        return self.reserved == 0 and requested.reserved == 0 and
            (!requested.read or self.read) and
            (!requested.write or self.write) and
            (!requested.execute or self.execute) and
            (!requested.map or self.map) and
            (!requested.invoke or self.invoke) and
            (!requested.manage or self.manage) and
            (!requested.grant or self.grant);
    }

    pub fn isEmpty(self: Rights) bool {
        return !(self.read or self.write or self.execute or self.map or
            self.invoke or self.manage or self.grant);
    }
};

pub const FrameMapping = struct {
    virtual_address: u64,
    byte_length: u64,
    backing_offset: u64,
    readable: bool,
    writable: bool,
    executable: bool,
};

pub const ObjectSpec = struct {
    kind: Kind,
    /// Number of pages for frame_region/untyped, otherwise one kernel object.
    units: u32 = 1,
    /// Present only for frame_region reservations from the Phase 5 staging arena.
    mapping: ?FrameMapping = null,
};

pub const Request = struct {
    spec: ObjectSpec,
    rights: Rights,
};

pub const ObjectId = struct {
    slot: u16 = 0,
    generation: u32 = 0,

    pub fn encode(self: ObjectId) u64 {
        return (@as(u64, self.generation) << 32) | @as(u64, self.slot);
    }

    pub fn decode(raw: u64) ObjectId {
        return .{
            .slot = @truncate(raw),
            .generation = @truncate(raw >> 32),
        };
    }
};

pub const CapabilityId = struct {
    slot: u16 = 0,
    generation: u32 = 0,

    pub fn encode(self: CapabilityId) u64 {
        return (@as(u64, self.generation) << 32) | @as(u64, self.slot);
    }

    pub fn decode(raw: u64) CapabilityId {
        return .{
            .slot = @truncate(raw),
            .generation = @truncate(raw >> 32),
        };
    }
};

pub const Reservation = struct {
    object: ObjectId,
    capability: CapabilityId,
};

pub const ReservationSet = struct {
    objects: [max_batch]ObjectId = @splat(.{}),
    capabilities: [max_batch]CapabilityId = @splat(.{}),
    count: usize = 0,
};

pub const ObjectInfo = struct {
    id: ObjectId,
    kind: Kind,
    owner: process.Id,
    units: u32,
    mapping: ?FrameMapping,
    rights: Rights,
};

const ObjectSlot = struct {
    generation: u32 = 1,
    active: bool = false,
    kind: Kind = .frame_region,
    owner: process.Id = .{ .slot = 0, .generation = 0 },
    units: u32 = 0,
    mapping: ?FrameMapping = null,
};

const CapabilitySlot = struct {
    generation: u32 = 1,
    active: bool = false,
    object: ObjectId = .{},
    holder: process.Id = .{ .slot = 0, .generation = 0 },
    rights: Rights = .{},
    parent: ?CapabilityId = null,
    root: bool = false,
};

pub const ReserveError = error{
    InvalidOwner,
    InvalidBatch,
    InvalidSpec,
    InvalidRights,
    ObjectTableFull,
    CapabilityTableFull,
};

pub const GrantError = error{
    InvalidRecipient,
    InvalidRights,
    StaleCapability,
    PermissionDenied,
    CapabilityTableFull,
};

pub const LookupError = error{
    StaleCapability,
    StaleObject,
    PermissionDenied,
};

pub const RevokeError = error{
    StaleCapability,
    PermissionDenied,
};

pub const DestroyError = error{
    StaleCapability,
    StaleObject,
    PermissionDenied,
    LiveDelegates,
};

pub const Table = struct {
    objects: [max_objects]ObjectSlot = @splat(.{}),
    capabilities: [max_capabilities]CapabilitySlot = @splat(.{}),

    /// Atomically reserve a bounded set of objects and root capabilities.
    /// All requests are validated and capacity is checked before the table is
    /// modified, so failure never leaves a partially reserved process.
    pub fn reserveBatch(
        self: *Table,
        owner: process.Id,
        requests: []const Request,
    ) ReserveError!ReservationSet {
        if (!validOwner(owner)) return error.InvalidOwner;
        if (requests.len == 0 or requests.len > max_batch) return error.InvalidBatch;

        for (requests) |request| {
            if (!validRequest(request)) return error.InvalidSpec;
            if (!validRights(request.spec.kind, request.rights)) return error.InvalidRights;
        }

        var object_slots: [max_batch]usize = undefined;
        var capability_slots: [max_batch]usize = undefined;
        var object_count: usize = 0;
        var capability_count: usize = 0;

        for (self.objects, 0..) |slot, index| {
            if (!slot.active and object_count < requests.len) {
                object_slots[object_count] = index;
                object_count += 1;
            }
        }
        if (object_count != requests.len) return error.ObjectTableFull;

        for (self.capabilities, 0..) |slot, index| {
            if (!slot.active and capability_count < requests.len) {
                capability_slots[capability_count] = index;
                capability_count += 1;
            }
        }
        if (capability_count != requests.len) return error.CapabilityTableFull;

        var result = ReservationSet{ .count = requests.len };
        for (requests, 0..) |request, request_index| {
            const object_index = object_slots[request_index];
            const capability_index = capability_slots[request_index];
            const object_generation = self.objects[object_index].generation;
            const capability_generation = self.capabilities[capability_index].generation;

            const object_id = ObjectId{
                .slot = @intCast(object_index),
                .generation = object_generation,
            };
            const capability_id = CapabilityId{
                .slot = @intCast(capability_index),
                .generation = capability_generation,
            };

            self.objects[object_index] = .{
                .generation = object_generation,
                .active = true,
                .kind = request.spec.kind,
                .owner = owner,
                .units = request.spec.units,
                .mapping = request.spec.mapping,
            };
            self.capabilities[capability_index] = .{
                .generation = capability_generation,
                .active = true,
                .object = object_id,
                .holder = owner,
                .rights = request.rights,
                .parent = null,
                .root = true,
            };

            result.objects[request_index] = object_id;
            result.capabilities[request_index] = capability_id;
        }
        return result;
    }

    pub fn reserve(
        self: *Table,
        owner: process.Id,
        spec: ObjectSpec,
        rights: Rights,
    ) ReserveError!Reservation {
        const requests = [_]Request{.{ .spec = spec, .rights = rights }};
        const result = try self.reserveBatch(owner, &requests);
        return .{
            .object = result.objects[0],
            .capability = result.capabilities[0],
        };
    }

    /// Delegate a strict subset of the caller's rights to another process.
    /// A delegated capability refers to the same reserved object and records
    /// its parent so every descendant can be revoked together.
    pub fn grant(
        self: *Table,
        parent_id: CapabilityId,
        caller: process.Id,
        recipient: process.Id,
        requested: Rights,
    ) GrantError!CapabilityId {
        if (!validOwner(recipient)) return error.InvalidRecipient;
        const parent = self.getCapability(parent_id) orelse return error.StaleCapability;
        if (!sameOwner(parent.holder, caller) or !parent.rights.grant) {
            return error.PermissionDenied;
        }
        if (!parent.rights.allows(requested)) return error.PermissionDenied;

        const object = self.getObjectConst(parent.object) orelse return error.StaleCapability;
        if (!validRights(object.kind, requested)) return error.InvalidRights;

        const slot_index = self.findFreeCapability() orelse return error.CapabilityTableFull;
        const generation = self.capabilities[slot_index].generation;
        const child_id = CapabilityId{
            .slot = @intCast(slot_index),
            .generation = generation,
        };
        self.capabilities[slot_index] = .{
            .generation = generation,
            .active = true,
            .object = parent.object,
            .holder = recipient,
            .rights = requested,
            .parent = parent_id,
            .root = false,
        };
        return child_id;
    }

    /// Resolve a capability only for its recorded holder and requested rights.
    pub fn lookup(
        self: *const Table,
        capability_id: CapabilityId,
        holder: process.Id,
        requested: Rights,
    ) LookupError!ObjectInfo {
        const capability = self.getCapabilityConst(capability_id) orelse {
            return error.StaleCapability;
        };
        if (!sameOwner(capability.holder, holder) or
            !capability.rights.allows(requested))
        {
            return error.PermissionDenied;
        }
        const object = self.getObjectConst(capability.object) orelse return error.StaleObject;
        return .{
            .id = capability.object,
            .kind = object.kind,
            .owner = object.owner,
            .units = object.units,
            .mapping = object.mapping,
            .rights = capability.rights,
        };
    }

    /// Revoke every delegated descendant while retaining the supplied
    /// capability. The caller must hold a grant-capable parent capability.
    pub fn revokeDescendants(
        self: *Table,
        parent_id: CapabilityId,
        caller: process.Id,
    ) RevokeError!usize {
        const parent = self.getCapability(parent_id) orelse return error.StaleCapability;
        if (!sameOwner(parent.holder, caller) or !parent.rights.grant) {
            return error.PermissionDenied;
        }

        var queue: [max_capabilities]CapabilityId = undefined;
        var queue_head: usize = 0;
        var queue_tail: usize = 1;
        var revoked: usize = 0;
        queue[0] = parent_id;

        while (queue_head < queue_tail) : (queue_head += 1) {
            const current_parent = queue[queue_head];
            for (&self.capabilities, 0..) |*candidate, index| {
                if (!candidate.active) continue;
                const candidate_parent = candidate.parent orelse continue;
                if (!sameCapability(candidate_parent, current_parent)) continue;

                const child_id = CapabilityId{
                    .slot = @intCast(index),
                    .generation = candidate.generation,
                };
                queue[queue_tail] = child_id;
                queue_tail += 1;
                invalidateCapability(candidate);
                revoked += 1;
            }
        }
        return revoked;
    }

    /// Destroy a reserved object after all delegated capabilities have been
    /// revoked. Only the process holding its root capability may destroy it.
    pub fn destroy(
        self: *Table,
        root_id: CapabilityId,
        owner: process.Id,
    ) DestroyError!void {
        const root = self.getCapability(root_id) orelse return error.StaleCapability;
        if (!root.root or !sameOwner(root.holder, owner)) return error.PermissionDenied;
        const object_id = root.object;
        const object = self.getObject(object_id) orelse return error.StaleObject;
        if (!sameOwner(object.owner, owner)) return error.PermissionDenied;

        for (self.capabilities, 0..) |candidate, index| {
            if (!candidate.active or !sameObject(candidate.object, object_id)) continue;
            const candidate_id = CapabilityId{
                .slot = @intCast(index),
                .generation = candidate.generation,
            };
            if (!sameCapability(candidate_id, root_id)) return error.LiveDelegates;
        }

        const object_index: usize = object_id.slot;
        invalidateCapability(&self.capabilities[root_id.slot]);
        const generation = nextGeneration(self.objects[object_index].generation);
        self.objects[object_index] = .{ .generation = generation };
    }

    pub fn activeObjectCount(self: *const Table) usize {
        var count: usize = 0;
        for (self.objects) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    pub fn activeCapabilityCount(self: *const Table) usize {
        var count: usize = 0;
        for (self.capabilities) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    fn findFreeCapability(self: *const Table) ?usize {
        for (self.capabilities, 0..) |slot, index| {
            if (!slot.active) return index;
        }
        return null;
    }

    fn getCapability(self: *Table, id: CapabilityId) ?*CapabilitySlot {
        const index: usize = id.slot;
        if (index >= max_capabilities) return null;
        const slot = &self.capabilities[index];
        if (!slot.active or slot.generation != id.generation) return null;
        return slot;
    }

    fn getCapabilityConst(self: *const Table, id: CapabilityId) ?*const CapabilitySlot {
        const index: usize = id.slot;
        if (index >= max_capabilities) return null;
        const slot = &self.capabilities[index];
        if (!slot.active or slot.generation != id.generation) return null;
        return slot;
    }

    fn getObject(self: *Table, id: ObjectId) ?*ObjectSlot {
        const index: usize = id.slot;
        if (index >= max_objects) return null;
        const slot = &self.objects[index];
        if (!slot.active or slot.generation != id.generation) return null;
        return slot;
    }

    fn getObjectConst(self: *const Table, id: ObjectId) ?*const ObjectSlot {
        const index: usize = id.slot;
        if (index >= max_objects) return null;
        const slot = &self.objects[index];
        if (!slot.active or slot.generation != id.generation) return null;
        return slot;
    }
};

fn validOwner(owner: process.Id) bool {
    return @as(usize, owner.slot) < process.max_processes and owner.generation != 0;
}

fn sameOwner(left: process.Id, right: process.Id) bool {
    return left.slot == right.slot and left.generation == right.generation;
}

fn sameCapability(left: CapabilityId, right: CapabilityId) bool {
    return left.slot == right.slot and left.generation == right.generation;
}

fn sameObject(left: ObjectId, right: ObjectId) bool {
    return left.slot == right.slot and left.generation == right.generation;
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

fn invalidateCapability(slot: *CapabilitySlot) void {
    const generation = nextGeneration(slot.generation);
    slot.* = .{ .generation = generation };
}

fn allowedRights(kind: Kind) Rights {
    return switch (kind) {
        .frame_region => .{
            .read = true,
            .write = true,
            .execute = true,
            .map = true,
            .grant = true,
        },
        .endpoint, .notification => .{ .invoke = true, .grant = true },
        .tcb, .cnode, .scheduling_context, .untyped => .{
            .manage = true,
            .grant = true,
        },
        .vspace => .{ .map = true, .manage = true, .grant = true },
    };
}

fn validRights(kind: Kind, rights: Rights) bool {
    return rights.reserved == 0 and !rights.isEmpty() and allowedRights(kind).allows(rights);
}

fn validRequest(request: Request) bool {
    if (request.spec.units == 0) return false;

    if (request.spec.kind == .frame_region) {
        const mapping = request.spec.mapping orelse return false;
        if (mapping.byte_length == 0 or mapping.byte_length % page_size != 0) return false;
        if (mapping.virtual_address % page_size != 0 or
            mapping.backing_offset % page_size != 0)
        {
            return false;
        }
        if (mapping.byte_length / page_size != request.spec.units) return false;
        if (mapping.writable and mapping.executable) return false;
        if (!(mapping.readable or mapping.writable or mapping.executable)) return false;
        const end = @addWithOverflow(mapping.virtual_address, mapping.byte_length);
        if (end[1] != 0) return false;
        return true;
    }

    if (request.spec.mapping != null) return false;
    return switch (request.spec.kind) {
        .untyped => true,
        else => request.spec.units == 1,
    };
}

test "object authority binds typed rights to the owning process" {
    const std = @import("std");
    const owner = process.Id{ .slot = 0, .generation = 1 };
    const other = process.Id{ .slot = 1, .generation = 1 };
    var table = Table{};
    const reservation = try table.reserve(owner, .{
        .kind = .frame_region,
        .units = 2,
        .mapping = .{
            .virtual_address = 0x20_0000,
            .byte_length = 2 * page_size,
            .backing_offset = 0,
            .readable = true,
            .writable = false,
            .executable = true,
        },
    }, .{ .read = true, .execute = true, .map = true, .grant = true });

    const resolved = try table.lookup(
        reservation.capability,
        owner,
        .{ .read = true, .map = true },
    );
    try std.testing.expectEqual(Kind.frame_region, resolved.kind);
    try std.testing.expectEqual(@as(u32, 2), resolved.units);
    try std.testing.expectError(
        error.PermissionDenied,
        table.lookup(reservation.capability, other, .{ .read = true }),
    );
    try std.testing.expectError(
        error.PermissionDenied,
        table.lookup(reservation.capability, owner, .{ .write = true }),
    );
    try std.testing.expectEqual(reservation.object, ObjectId.decode(reservation.object.encode()));
    try std.testing.expectEqual(
        reservation.capability,
        CapabilityId.decode(reservation.capability.encode()),
    );
}

test "delegated capabilities are attenuated and descendants can be revoked" {
    const std = @import("std");
    const owner = process.Id{ .slot = 0, .generation = 1 };
    const child = process.Id{ .slot = 1, .generation = 1 };
    const grandchild = process.Id{ .slot = 2, .generation = 1 };
    var table = Table{};
    const root = try table.reserve(owner, .{ .kind = .endpoint }, .{
        .invoke = true,
        .grant = true,
    });

    const child_cap = try table.grant(root.capability, owner, child, .{
        .invoke = true,
        .grant = true,
    });
    const grandchild_cap = try table.grant(child_cap, child, grandchild, .{
        .invoke = true,
    });
    try std.testing.expectError(
        error.PermissionDenied,
        table.grant(child_cap, child, grandchild, .{ .manage = true }),
    );
    try std.testing.expectEqual(@as(usize, 3), table.activeCapabilityCount());

    try std.testing.expectEqual(@as(usize, 2), try table.revokeDescendants(root.capability, owner));
    try std.testing.expectEqual(@as(usize, 1), table.activeCapabilityCount());
    try std.testing.expectError(
        error.StaleCapability,
        table.lookup(child_cap, child, .{ .invoke = true }),
    );
    try std.testing.expectError(
        error.StaleCapability,
        table.lookup(grandchild_cap, grandchild, .{ .invoke = true }),
    );
    _ = try table.lookup(root.capability, owner, .{ .invoke = true });
    try table.destroy(root.capability, owner);
    try std.testing.expectEqual(@as(usize, 0), table.activeObjectCount());
    try std.testing.expectEqual(@as(usize, 0), table.activeCapabilityCount());
}

test "object destruction refuses live delegates and invalidates old generations" {
    const std = @import("std");
    const owner = process.Id{ .slot = 0, .generation = 1 };
    const child = process.Id{ .slot = 1, .generation = 1 };
    var table = Table{};
    const root = try table.reserve(owner, .{ .kind = .tcb }, .{ .manage = true, .grant = true });
    _ = try table.grant(root.capability, owner, child, .{ .manage = true });

    try std.testing.expectError(error.LiveDelegates, table.destroy(root.capability, owner));
    try std.testing.expectEqual(@as(usize, 1), try table.revokeDescendants(root.capability, owner));
    try table.destroy(root.capability, owner);
    try std.testing.expectError(
        error.StaleCapability,
        table.lookup(root.capability, owner, .{ .manage = true }),
    );
    try std.testing.expectError(
        error.StaleCapability,
        table.destroy(root.capability, owner),
    );
}

test "batch reservation is atomic and rejects malformed W plus X mappings" {
    const std = @import("std");
    const owner = process.Id{ .slot = 0, .generation = 1 };
    var table = Table{};

    const bad = [_]Request{
        .{ .spec = .{ .kind = .endpoint }, .rights = .{ .invoke = true } },
        .{
            .spec = .{
                .kind = .frame_region,
                .units = 1,
                .mapping = .{
                    .virtual_address = 0x30_0000,
                    .byte_length = page_size,
                    .backing_offset = 0,
                    .readable = true,
                    .writable = true,
                    .executable = true,
                },
            },
            .rights = .{ .read = true, .write = true, .execute = true, .map = true },
        },
    };
    try std.testing.expectError(error.InvalidSpec, table.reserveBatch(owner, &bad));
    try std.testing.expectEqual(@as(usize, 0), table.activeObjectCount());
    try std.testing.expectEqual(@as(usize, 0), table.activeCapabilityCount());

    try std.testing.expectError(error.InvalidOwner, table.reserve(
        .{ .slot = 0, .generation = 0 },
        .{ .kind = .endpoint },
        .{ .invoke = true },
    ));
}
