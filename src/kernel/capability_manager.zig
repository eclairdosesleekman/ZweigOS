// SPDX-License-Identifier: BSD-2-Clause
//! Cross-CSpace capability lifecycle manager.
//!
//! The authority ledger stores policy identities. This module maps those
//! identities to CSpaceLocations and invokes the selected seL4 backend. CPtrs
//! are resolved only inside the Resource Manager and never enter an RPC.

const std = @import("std");
const authority = @import("../core/object_authority.zig");
const process = @import("../core/process.zig");
const catalog_mod = @import("cspace_location.zig");
const cspace = @import("cspace_allocator.zig");
const audit_mod = @import("audit_log.zig");
const backend = @import("sel4_backend.zig");

pub const max_capabilities: usize = authority.max_capabilities;

pub const CapabilityHandle = struct {
    slot: u16,
    generation: u32,
};

pub const DeriveOperation = enum(u8) { copy, mint };

pub const KernelOps = struct {
    context: ?*anyopaque = null,
    copy: *const fn (
        ?*anyopaque,
        u64, u64, u64,
        u64, u64, u64,
        u8, u8,
    ) callconv(.c) c_int,
    mint: *const fn (
        ?*anyopaque,
        u64, u64, u64,
        u64, u64, u64,
        u8, u8, u64,
    ) callconv(.c) c_int,
    revoke: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) c_int,
    delete: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) c_int,
};

const State = enum(u8) { free, live, quarantined };

const Record = struct {
    active: bool = false,
    state: State = .free,
    generation: u32 = 1,
    capability_id: authority.CapabilityId = .{},
    object_id: authority.ObjectId = .{},
    holder: process.Id = .{ .slot = 0, .generation = 0 },
    kind: authority.Kind = .endpoint,
    rights: authority.Rights = .{},
    location: catalog_mod.CSpaceLocation = .{
        .space = .{ .slot = 0, .generation = 0 },
        .slot = 0,
    },
    slot_lease: ?cspace.Lease = null,
    parent: ?CapabilityHandle = null,
    root: bool = false,
};

pub const Error = error{
    InvalidOwner,
    WrongOwner,
    StaleHandle,
    ManagerFull,
    UnsupportedRights,
    InvalidOperation,
    InvalidLocation,
    SlotAllocationFailed,
    LedgerFailure,
    KernelCallFailed,
    RollbackFailed,
    NotRoot,
    LiveDelegates,
    ResourceQuarantined,
    AccountingFailure,
};

pub const Manager = struct {
    ledger: *authority.Table,
    spaces: *catalog_mod.Catalog,
    ops: KernelOps,
    audit: ?*audit_mod.Log = null,
    service_id: u16 = 0,
    records: [max_capabilities]Record = @splat(.{}),

    pub fn init(
        ledger: *authority.Table,
        spaces: *catalog_mod.Catalog,
        ops: KernelOps,
    ) Manager {
        return .{ .ledger = ledger, .spaces = spaces, .ops = ops };
    }

    /// Register an already-materialized root capability. Callers must first
    /// establish that the CSpace slot contains the expected seL4 object; this
    /// method only adopts it into Zweig's policy/accounting tables.
    pub fn adoptRoot(
        self: *Manager,
        owner: process.Id,
        spec: authority.ObjectSpec,
        rights: authority.Rights,
        location: catalog_mod.CSpaceLocation,
    ) Error!CapabilityHandle {
        if (!validOwner(owner)) return error.InvalidOwner;
        const index = self.findFreeRecord() orelse return error.ManagerFull;
        _ = self.spaces.slotPath(location) catch return error.InvalidLocation;
        const reservation = self.ledger.reserve(owner, spec, rights) catch return error.LedgerFailure;
        const record = &self.records[index];
        record.* = .{
            .active = true,
            .state = .live,
            .generation = record.generation,
            .capability_id = reservation.capability,
            .object_id = reservation.object,
            .holder = owner,
            .kind = spec.kind,
            .rights = rights,
            .location = location,
            .slot_lease = null,
            .parent = null,
            .root = true,
        };
        self.emit(.capability_copied, owner, spec.kind, 0, 0);
        return .{ .slot = @intCast(index), .generation = record.generation };
    }

    /// Copy or mint a strict rights subset into a separately allocated CSpace.
    /// The slot and Ledger child record are both reserved before the syscall.
    pub fn delegate(
        self: *Manager,
        parent_handle: CapabilityHandle,
        caller: process.Id,
        recipient: process.Id,
        destination_space: catalog_mod.SpaceId,
        requested: authority.Rights,
        operation: DeriveOperation,
        badge: u64,
        request_id: u32,
    ) Error!CapabilityHandle {
        if (!validOwner(recipient)) return error.InvalidOwner;
        const parent = self.getRecord(parent_handle) catch return error.StaleHandle;
        if (!sameOwner(parent.holder, caller)) return error.WrongOwner;
        if (operation == .copy and badge != 0) return error.InvalidOperation;
        if (operation == .mint and badge == 0) return error.InvalidOperation;
        const record_index = self.findFreeRecord() orelse return error.ManagerFull;

        const destination_lease = self.spaces.reserve(
            destination_space,
            recipient.encode(),
            1,
        ) catch return error.SlotAllocationFailed;
        const destination_location = self.spaces.location(destination_space, destination_lease, 0) catch {
            self.spaces.release(destination_space, destination_lease) catch {};
            return error.InvalidLocation;
        };
        const source_path = self.spaces.slotPath(parent.location) catch {
            self.spaces.release(destination_space, destination_lease) catch {};
            return error.InvalidLocation;
        };
        const destination_path = self.spaces.slotPath(destination_location) catch {
            self.spaces.release(destination_space, destination_lease) catch {};
            return error.InvalidLocation;
        };

        const child_capability = self.ledger.grant(
            parent.capability_id,
            caller,
            recipient,
            requested,
        ) catch {
            self.spaces.release(destination_space, destination_lease) catch {};
            return error.LedgerFailure;
        };

        const parent_rights = sel4Rights(parent.kind, parent.rights) catch {
            _ = self.ledger.cancelGrant(parent.capability_id, child_capability, caller) catch return error.RollbackFailed;
            self.spaces.release(destination_space, destination_lease) catch return error.RollbackFailed;
            return error.UnsupportedRights;
        };
        const child_rights = sel4Rights(parent.kind, requested) catch {
            _ = self.ledger.cancelGrant(parent.capability_id, child_capability, caller) catch return error.RollbackFailed;
            self.spaces.release(destination_space, destination_lease) catch return error.RollbackFailed;
            return error.UnsupportedRights;
        };

        const kernel_status = switch (operation) {
            .copy => self.ops.copy(
                self.ops.context,
                destination_path.root,
                destination_path.index,
                destination_path.depth,
                source_path.root,
                source_path.index,
                source_path.depth,
                parent_rights,
                child_rights,
            ),
            .mint => self.ops.mint(
                self.ops.context,
                destination_path.root,
                destination_path.index,
                destination_path.depth,
                source_path.root,
                source_path.index,
                source_path.depth,
                parent_rights,
                child_rights,
                badge,
            ),
        };

        if (kernel_status != 0) {
            self.ledger.cancelGrant(parent.capability_id, child_capability, caller) catch {
                self.spaces.quarantine(destination_space, destination_lease) catch {};
                self.recordQuarantine(record_index, destination_space, destination_location, destination_lease, child_capability, recipient);
                self.emit(.resource_quarantined, recipient, parent.kind, request_id, kernel_status);
                return error.RollbackFailed;
            };
            self.spaces.release(destination_space, destination_lease) catch {
                self.recordQuarantine(record_index, destination_space, destination_location, destination_lease, child_capability, recipient);
                return error.RollbackFailed;
            };
            self.emit(.request_denied, recipient, parent.kind, request_id, kernel_status);
            return error.KernelCallFailed;
        }

        self.spaces.markInstalled(destination_space, destination_lease) catch {
            // The kernel cap exists. Never release this slot as if it were empty.
            self.spaces.quarantine(destination_space, destination_lease) catch {};
            self.recordQuarantine(record_index, destination_space, destination_location, destination_lease, child_capability, recipient);
            self.emit(.resource_quarantined, recipient, parent.kind, request_id, -1);
            return error.AccountingFailure;
        };

        const child_info = self.ledger.lookup(child_capability, recipient, .{}) catch {
            self.spaces.quarantine(destination_space, destination_lease) catch {};
            self.recordQuarantine(record_index, destination_space, destination_location, destination_lease, child_capability, recipient);
            return error.AccountingFailure;
        };
        const record = &self.records[record_index];
        record.* = .{
            .active = true,
            .state = .live,
            .generation = record.generation,
            .capability_id = child_capability,
            .object_id = child_info.id,
            .holder = recipient,
            .kind = child_info.kind,
            .rights = requested,
            .location = destination_location,
            .slot_lease = destination_lease,
            .parent = parent_handle,
            .root = false,
        };
        self.emit(
            if (operation == .mint) .capability_minted else .capability_copied,
            recipient,
            child_info.kind,
            request_id,
            0,
        );
        return .{ .slot = @intCast(record_index), .generation = record.generation };
    }

    /// Revoke the kernel derivation tree and then invalidate every recorded
    /// descendant slot. The supplied capability itself remains live.
    pub fn revokeTree(
        self: *Manager,
        handle: CapabilityHandle,
        caller: process.Id,
        request_id: u32,
    ) Error!usize {
        const parent = self.getRecord(handle) catch return error.StaleHandle;
        if (!sameOwner(parent.holder, caller)) return error.WrongOwner;
        if (!parent.rights.grant) return 0;

        const path = self.spaces.slotPath(parent.location) catch return error.InvalidLocation;
        const status = self.ops.revoke(self.ops.context, path.root, path.index, path.depth);
        if (status != 0) {
            self.emit(.request_denied, caller, parent.kind, request_id, status);
            return error.KernelCallFailed;
        }
        const revoked = self.ledger.revokeDescendants(parent.capability_id, caller) catch return error.LedgerFailure;
        const indices = self.collectDescendants(handle);
        for (indices.items[0..indices.count]) |index| {
            self.releaseRevokedRecord(index) catch {
                self.emit(.resource_quarantined, self.records[index].holder, self.records[index].kind, request_id, -2);
                return error.AccountingFailure;
            };
        }
        self.emit(.capability_revoked, caller, parent.kind, request_id, @intCast(revoked));
        return revoked;
    }

    /// Delete a delegated capability after revoking its descendants. Root
    /// capabilities are destroyed only by the object manager after object teardown.
    pub fn deleteDelegated(
        self: *Manager,
        handle: CapabilityHandle,
        caller: process.Id,
        request_id: u32,
    ) Error!void {
        const record = self.getRecord(handle) catch return error.StaleHandle;
        if (record.root) return error.NotRoot;
        if (!sameOwner(record.holder, caller)) return error.WrongOwner;

        _ = try self.revokeTree(handle, caller, request_id);
        const current = self.getRecord(handle) catch return error.StaleHandle;
        const path = self.spaces.slotPath(current.location) catch return error.InvalidLocation;
        const status = self.ops.delete(self.ops.context, path.root, path.index, path.depth);
        if (status != 0) return error.KernelCallFailed;

        self.ledger.deleteDelegated(current.capability_id, caller) catch {
            if (current.slot_lease) |lease| {
                self.spaces.quarantine(current.location.space, lease) catch {};
            }
            self.records[handle.slot].state = .quarantined;
            return error.AccountingFailure;
        };
        try self.releaseRecordSlot(handle.slot);
        self.emit(.capability_deleted, caller, current.kind, request_id, 0);
    }

    pub fn activeCount(self: *const Manager) usize {
        var count: usize = 0;
        for (self.records) |record| if (record.active) { count += 1; };
        return count;
    }

    fn collectDescendants(self: *const Manager, root: CapabilityHandle) struct {
        items: [max_capabilities]usize,
        count: usize,
    } {
        var result = .{ .items = @as([max_capabilities]usize, undefined), .count = 0 };
        var queue: [max_capabilities]CapabilityHandle = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = root;
        tail += 1;
        while (head < tail) : (head += 1) {
            const current = queue[head];
            for (self.records, 0..) |record, index| {
                if (!record.active or record.parent == null) continue;
                if (!sameHandle(record.parent.?, current)) continue;
                if (result.count < max_capabilities) {
                    result.items[result.count] = index;
                    result.count += 1;
                }
                if (tail < max_capabilities) {
                    queue[tail] = .{ .slot = @intCast(index), .generation = record.generation };
                    tail += 1;
                }
            }
        }
        return result;
    }

    fn releaseRevokedRecord(self: *Manager, index: usize) Error!void {
        const record = &self.records[index];
        if (!record.active or record.root) return error.StaleHandle;
        try self.releaseRecordSlot(index);
    }

    fn releaseRecordSlot(self: *Manager, index: usize) Error!void {
        const record = &self.records[index];
        if (record.slot_lease) |lease| {
            self.spaces.markDeleted(record.location.space, lease, 0) catch {
                self.spaces.quarantine(record.location.space, lease) catch {};
                self.records[index].state = .quarantined;
                return error.AccountingFailure;
            };
            self.spaces.release(record.location.space, lease) catch {
                self.spaces.quarantine(record.location.space, lease) catch {};
                self.records[index].state = .quarantined;
                return error.AccountingFailure;
            };
        }
        const generation = nextGeneration(record.generation);
        self.records[index] = .{ .generation = generation };
    }

    fn recordQuarantine(
        self: *Manager,
        index: usize,
        space: catalog_mod.SpaceId,
        location: catalog_mod.CSpaceLocation,
        lease: cspace.Lease,
        capability_id: authority.CapabilityId,
        holder: process.Id,
    ) void {
        const record = &self.records[index];
        record.* = .{
            .active = true,
            .state = .quarantined,
            .generation = record.generation,
            .capability_id = capability_id,
            .holder = holder,
            .location = location,
            .slot_lease = lease,
            .parent = null,
            .root = false,
        };
        _ = space;
    }

    fn getRecord(self: *const Manager, handle: CapabilityHandle) Error!*const Record {
        const index: usize = handle.slot;
        if (index >= max_capabilities) return error.StaleHandle;
        const record = &self.records[index];
        if (!record.active or record.state != .live or record.generation != handle.generation) return error.StaleHandle;
        return record;
    }

    fn findFreeRecord(self: *const Manager) ?usize {
        for (self.records, 0..) |record, index| if (!record.active) return index;
        return null;
    }

    fn recordQuarantineUnused(self: *Manager) void {
        _ = self;
    }

    fn emit(
        self: *Manager,
        event: audit_mod.Event,
        owner: process.Id,
        kind: authority.Kind,
        request_id: u32,
        result_code: i32,
    ) void {
        if (self.audit) |log| {
            _ = log.append(.{
                .service_id = self.service_id,
                .process = owner,
                .event = event,
                .request_id = request_id,
                .object_kind = @intCast(@intFromEnum(kind)),
                .result_code = result_code,
            });
        }
    }
};

fn sel4Rights(kind: authority.Kind, rights: authority.Rights) Error!u8 {
    if (rights.reserved != 0) return error.UnsupportedRights;
    return switch (kind) {
        .frame_region => blk: {
            if (rights.manage or rights.invoke) return error.UnsupportedRights;
            break :blk (@as(u8, @intFromBool(rights.grant)) << 1) |
                (@as(u8, @intFromBool(rights.read)) << 2) |
                (@as(u8, @intFromBool(rights.write)) << 3);
        },
        .endpoint, .notification => blk: {
            if (rights.manage or rights.map or rights.execute) return error.UnsupportedRights;
            const send = rights.invoke or rights.write;
            break :blk (@as(u8, @intFromBool(rights.grant)) << 1) |
                (@as(u8, @intFromBool(rights.read)) << 2) |
                (@as(u8, @intFromBool(send)) << 3);
        },
        else => error.UnsupportedRights,
    };
}

fn defaultCopy(
    context: ?*anyopaque,
    dest_root: u64, dest_index: u64, dest_depth: u64,
    src_root: u64, src_index: u64, src_depth: u64,
    parent_rights: u8, rights: u8,
) callconv(.c) c_int {
    _ = context;
    return backend.copyCapability(
        .{ .root = dest_root, .index = dest_index, .depth = dest_depth },
        .{ .root = src_root, .index = src_index, .depth = src_depth },
        parent_rights,
        rights,
    );
}

fn defaultMint(
    context: ?*anyopaque,
    dest_root: u64, dest_index: u64, dest_depth: u64,
    src_root: u64, src_index: u64, src_depth: u64,
    parent_rights: u8, rights: u8, badge: u64,
) callconv(.c) c_int {
    _ = context;
    return backend.mintCapability(
        .{ .root = dest_root, .index = dest_index, .depth = dest_depth },
        .{ .root = src_root, .index = src_index, .depth = src_depth },
        parent_rights,
        rights,
        badge,
    );
}

fn defaultRevoke(context: ?*anyopaque, root: u64, index: u64, depth: u64) callconv(.c) c_int {
    _ = context;
    return backend.revokeCapability(.{ .root = root, .index = index, .depth = depth });
}

fn defaultDelete(context: ?*anyopaque, root: u64, index: u64, depth: u64) callconv(.c) c_int {
    _ = context;
    return backend.deleteCapability(.{ .root = root, .index = index, .depth = depth });
}

pub fn sel4KernelOps() KernelOps {
    return .{ .copy = defaultCopy, .mint = defaultMint, .revoke = defaultRevoke, .delete = defaultDelete };
}

fn sameOwner(left: process.Id, right: process.Id) bool {
    return left.slot == right.slot and left.generation == right.generation;
}
fn sameHandle(left: CapabilityHandle, right: CapabilityHandle) bool {
    return left.slot == right.slot and left.generation == right.generation;
}
fn validOwner(owner: process.Id) bool {
    return @as(usize, owner.slot) < process.max_processes and owner.generation != 0;
}
fn nextGeneration(value: u32) u32 {
    const next = value +% 1;
    return if (next == 0) 1 else next;
}

test "delegation uses separate CSpace locations and rights attenuation" {
    const testing = std.testing;
    var ledger = authority.Table{};
    var spaces = catalog_mod.Catalog{};
    const owner = process.Id{ .slot = 0, .generation = 1 };
    const recipient = process.Id{ .slot = 1, .generation = 1 };
    const owner_space = try spaces.register(0x40, 0x10, 16);
    const child_space = try spaces.register(0x41, 0x20, 16);
    const source_lease = try spaces.reserve(owner_space, owner.encode(), 1);
    try spaces.markInstalled(owner_space, source_lease);
    const source_location = try spaces.location(owner_space, source_lease, 0);

    var mock = Mock{};
    var manager = Manager.init(&ledger, &spaces, mock.ops());
    const root = try manager.adoptRoot(owner, .{ .kind = .endpoint }, .{ .invoke = true, .grant = true }, source_location);
    const child = try manager.delegate(root, owner, recipient, child_space, .{ .invoke = true }, .mint, 0x1234, 77);

    try testing.expectEqual(@as(usize, 2), manager.activeCount());
    try testing.expectEqual(@as(u64, 0x20), mock.last_destination_index);
    try testing.expectEqual(@as(u64, 0x10), mock.last_source_index);
    try testing.expectEqual(@as(u64, 0x1234), mock.last_badge);
    try testing.expectEqual(@as(u64, 0x2), mock.last_child_rights);
    try manager.deleteDelegated(child, recipient, 78);
    try testing.expectEqual(@as(usize, 1), manager.activeCount());
    try testing.expectEqual(@as(usize, 16), try spaces.freeCount(child_space));
}

test "failed mint cancels authority metadata and returns the reserved slot" {
    const testing = std.testing;
    var ledger = authority.Table{};
    var spaces = catalog_mod.Catalog{};
    const owner = process.Id{ .slot = 0, .generation = 1 };
    const recipient = process.Id{ .slot = 1, .generation = 1 };
    const owner_space = try spaces.register(0x50, 0x30, 8);
    const child_space = try spaces.register(0x51, 0x40, 8);
    const lease = try spaces.reserve(owner_space, owner.encode(), 1);
    try spaces.markInstalled(owner_space, lease);
    const location = try spaces.location(owner_space, lease, 0);
    var mock = Mock{ .fail_mint = true };
    var manager = Manager.init(&ledger, &spaces, mock.ops());
    const root = try manager.adoptRoot(owner, .{ .kind = .endpoint }, .{ .invoke = true, .grant = true }, location);
    try testing.expectError(
        error.KernelCallFailed,
        manager.delegate(root, owner, recipient, child_space, .{ .invoke = true }, .mint, 9, 1),
    );
    try testing.expectEqual(@as(usize, 1), ledger.activeCapabilityCount());
    try testing.expectEqual(@as(usize, 8), try spaces.freeCount(child_space));
}

const Mock = struct {
    fail_mint: bool = false,
    last_destination_index: u64 = 0,
    last_source_index: u64 = 0,
    last_badge: u64 = 0,
    last_child_rights: u64 = 0,

    fn ops(self: *Mock) KernelOps {
        return .{
            .context = self,
            .copy = mockCopy,
            .mint = mockMint,
            .revoke = mockRevoke,
            .delete = mockDelete,
        };
    }
    fn mockCopy(
        context: ?*anyopaque,
        dest_root: u64, dest_index: u64, dest_depth: u64,
        src_root: u64, src_index: u64, src_depth: u64,
        parent_rights: u8, rights: u8,
    ) callconv(.c) c_int {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = dest_root; _ = dest_depth; _ = src_root; _ = src_depth;
        _ = parent_rights;
        self.last_destination_index = dest_index;
        self.last_source_index = src_index;
        self.last_child_rights = rights;
        return 0;
    }
    fn mockMint(
        context: ?*anyopaque,
        dest_root: u64, dest_index: u64, dest_depth: u64,
        src_root: u64, src_index: u64, src_depth: u64,
        parent_rights: u8, rights: u8, badge: u64,
    ) callconv(.c) c_int {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = dest_root; _ = dest_depth; _ = src_root; _ = src_depth;
        _ = parent_rights;
        self.last_destination_index = dest_index;
        self.last_source_index = src_index;
        self.last_child_rights = rights;
        self.last_badge = badge;
        return if (self.fail_mint) -1 else 0;
    }
    fn mockRevoke(context: ?*anyopaque, root: u64, index: u64, depth: u64) callconv(.c) c_int {
        _ = context; _ = root; _ = index; _ = depth; return 0;
    }
    fn mockDelete(context: ?*anyopaque, root: u64, index: u64, depth: u64) callconv(.c) c_int {
        _ = context; _ = root; _ = index; _ = depth; return 0;
    }
};
