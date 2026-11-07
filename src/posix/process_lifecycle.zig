// SPDX-License-Identifier: BSD-2-Clause
//! Transactional process lifecycle coordinator for Phase 7.
//!
//! This composes the Phase 4 process registry, Phase 6 authority ledger, and
//! Phase 6 ELF resource planner. It orders prepare/commit/abort/exit/reap and
//! performs deterministic capability cleanup. It does not create or run seL4
//! TCBs; "commit" advances the process policy state only.

const std = @import("std");
const process_manager = @import("process_manager.zig");
const process_resources = @import("process_resources.zig");
const object_authority = @import("../core/object_authority.zig");

pub const ProcessId = process_manager.ProcessId;
pub const Phase = enum(u8) {
    prepared,
    running,
    exited,
    aborted,
};

pub const LaunchTicket = struct {
    process: process_manager.ProcessInfo,
};

const max_processes = process_manager.max_processes;
const max_resources = object_authority.max_batch;
const abort_exit_code: i32 = -125;

const Record = struct {
    active: bool = false,
    process_id: ProcessId = .{ .slot = 0, .generation = 0 },
    pid: u32 = 0,
    phase: Phase = .prepared,
    reservations: object_authority.ReservationSet = .{},
    request_count: usize = 0,
    grantable: [max_resources]bool = @splat(false),
    released: [max_resources]bool = @splat(false),
};

const ReleaseError = object_authority.RevokeError || object_authority.DestroyError;

pub const PrepareError = error{
    StaleProcess,
    ProcessNotStarting,
    WrongPlanOwner,
    InvalidPlan,
    AlreadyPrepared,
    ManagerFull,
} || process_resources.Error || object_authority.ReserveError;

pub const CommitError = error{
    UnknownProcess,
    InvalidLifecycleState,
} || error{StaleProcessId, InvalidStateTransition};

pub const AbortError = error{
    UnknownProcess,
    InvalidLifecycleState,
} || ReleaseError || error{StaleProcessId, InvalidStateTransition};

pub const ExitError = error{
    UnknownProcess,
    InvalidLifecycleState,
} || error{StaleProcessId, InvalidStateTransition};

pub const ReapError = error{
    ProcessNotManaged,
    ProcessNotExited,
} || ReleaseError || error{
    StaleProcessId,
    ParentNotRunning,
    ChildNotFound,
    WouldBlock,
    HasChildren,
};

pub const Manager = struct {
    records: [max_processes]Record = @splat(.{}),

    /// Reserve all metadata resources for an already-created starting process.
    /// The process record must come from ProcessManager.spawn(). No lifecycle
    /// record is changed if resource validation or authority reservation fails.
    pub fn prepare(
        self: *Manager,
        processes: *const process_manager.Table,
        authority: *object_authority.Table,
        child: process_manager.ProcessInfo,
        plan: process_resources.Plan,
    ) PrepareError!LaunchTicket {
        if (processes.pid(child.id) == null or processes.pid(child.id).? != child.pid) {
            return error.StaleProcess;
        }
        const process_state = processes.state(child.id) orelse return error.StaleProcess;
        if (process_state != .starting) return error.ProcessNotStarting;
        if (!sameId(plan.owner, child.id)) return error.WrongPlanOwner;
        if (plan.request_count == 0 or plan.request_count > max_resources) {
            return error.InvalidPlan;
        }
        if (self.find(child.id) != null) return error.AlreadyPrepared;
        const slot = self.freeRecord() orelse return error.ManagerFull;

        // reserveBatch validates all requests and checks both tables' capacity
        // before writing any slot; after success, storing this record cannot fail.
        const reservations = try authority.reserveBatch(
            child.id,
            plan.requests[0..plan.request_count],
        );

        var record = Record{
            .active = true,
            .process_id = child.id,
            .pid = child.pid,
            .phase = .prepared,
            .reservations = reservations,
            .request_count = plan.request_count,
        };
        for (plan.requests[0..plan.request_count], 0..) |request, index| {
            record.grantable[index] = request.rights.grant;
        }
        slot.* = record;
        return .{ .process = child };
    }

    /// Make a prepared process runnable in the process policy state machine.
    /// This is not a seL4 TCB resume operation.
    pub fn commit(
        self: *Manager,
        processes: *process_manager.Table,
        id: ProcessId,
    ) CommitError!void {
        const record = self.find(id) orelse return error.UnknownProcess;
        if (record.phase != .prepared) return error.InvalidLifecycleState;
        const process_state = processes.state(id) orelse return error.UnknownProcess;
        if (process_state != .starting) return error.InvalidLifecycleState;
        try processes.markRunning(id);
        record.phase = .running;
    }

    /// Abort a prepared launch, release its reservations, and make the failed
    /// process waitable by its parent.
    pub fn abort(
        self: *Manager,
        processes: *process_manager.Table,
        authority: *object_authority.Table,
        id: ProcessId,
    ) AbortError!void {
        const record = self.find(id) orelse return error.UnknownProcess;
        if (record.phase != .prepared) return error.InvalidLifecycleState;
        if (processes.state(id) != .starting) return error.InvalidLifecycleState;

        try self.releaseResources(record, authority);
        try processes.fail(id, abort_exit_code);
        record.phase = .aborted;
    }

    /// Record successful process termination in the policy state machine.
    /// A real runtime must call this only after the TCB has stopped executing.
    pub fn exit(
        self: *Manager,
        processes: *process_manager.Table,
        id: ProcessId,
        exit_code: i32,
    ) ExitError!void {
        const record = self.find(id) orelse return error.UnknownProcess;
        if (record.phase != .running) return error.InvalidLifecycleState;
        const process_state = processes.state(id) orelse return error.UnknownProcess;
        if (process_state != .running) return error.InvalidLifecycleState;

        try processes.exit(id, exit_code);
        record.phase = .exited;
    }

    /// Revoke descendants, destroy per-process resource reservations, then
    /// reap the direct child. Resource release is remembered item-by-item so
    /// an interrupted cleanup can be retried without double-destroying roots.
    ///
    /// If the child still has children, its resources are released but the
    /// process record remains until descendants have been reaped.
    pub fn reap(
        self: *Manager,
        processes: *process_manager.Table,
        authority: *object_authority.Table,
        parent_id: ProcessId,
        child_pid: u32,
    ) ReapError!process_manager.ExitInfo {
        const child = processes.childOf(parent_id, child_pid) orelse return error.ChildNotFound;
        const record = self.find(child.id) orelse return error.ProcessNotManaged;
        const state = processes.state(child.id) orelse return error.StaleProcessId;
        if (state == .starting or state == .running) return error.ProcessNotExited;

        try self.releaseResources(record, authority);
        const result = try processes.wait(parent_id, child_pid);
        record.* = .{};
        return result;
    }

    pub fn phase(self: *const Manager, id: ProcessId) ?Phase {
        const record = self.findConst(id) orelse return null;
        return record.phase;
    }

    pub fn activeCount(self: *const Manager) usize {
        var count: usize = 0;
        for (self.records) |record| {
            if (record.active) count += 1;
        }
        return count;
    }

    fn releaseResources(
        self: *Manager,
        record: *Record,
        authority: *object_authority.Table,
    ) ReleaseError!void {
        _ = self;
        for (0..record.request_count) |index| {
            if (record.released[index]) continue;
            const capability = record.reservations.capabilities[index];
            if (record.grantable[index]) {
                _ = try authority.revokeDescendants(capability, record.process_id);
            }
            try authority.destroy(capability, record.process_id);
            record.released[index] = true;
        }
    }

    fn freeRecord(self: *Manager) ?*Record {
        for (&self.records) |*record| {
            if (!record.active) return record;
        }
        return null;
    }

    fn find(self: *Manager, id: ProcessId) ?*Record {
        for (&self.records) |*record| {
            if (record.active and sameId(record.process_id, id)) return record;
        }
        return null;
    }

    fn findConst(self: *const Manager, id: ProcessId) ?*const Record {
        for (self.records) |*record| {
            if (record.active and sameId(record.process_id, id)) return record;
        }
        return null;
    }

    fn sameId(left: ProcessId, right: ProcessId) bool {
        return left.slot == right.slot and left.generation == right.generation;
    }
};

fn sameId(left: ProcessId, right: ProcessId) bool {
    return left.slot == right.slot and left.generation == right.generation;
}

fn testImage() @import("image_loader.zig").LoadedImage {
    const image_loader = @import("image_loader.zig");
    var loaded = image_loader.LoadedImage{
        .entry = 0x20_0100,
        .stack_pointer = 0x70_1ff0,
        .stack_bottom = 0x70_0000,
        .stack_top = 0x70_2000,
        .stack_guard_bottom = 0x6f_f000,
        .mappings = @splat(.{}),
        .mapping_count = 2,
        .argument_count = 1,
        .environment_count = 0,
        .arena_used_bytes = 4 * image_loader.page_size,
    };
    loaded.mappings[0] = .{
        .virtual_address = 0x20_0000,
        .byte_length = 2 * image_loader.page_size,
        .backing_offset = 0,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    loaded.mappings[1] = .{
        .virtual_address = 0x70_0000,
        .byte_length = 2 * image_loader.page_size,
        .backing_offset = 2 * image_loader.page_size,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    return loaded;
}

fn testPlan(owner: ProcessId) process_resources.Plan {
    return process_resources.build(owner, testImage(), .{
        .priority = 90,
        .budget_us = 500,
        .period_us = 5000,
    }, 8) catch unreachable;
}

test "prepared process commits, exits, and releases every authority reservation on reap" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    const child = try processes.spawn(parent.id, 2);
    const plan = testPlan(child.id);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};

    const ticket = try manager.prepare(&processes, &authority, child, plan);
    try testing.expectEqual(child.pid, ticket.process.pid);
    try testing.expectEqual(Phase.prepared, manager.phase(child.id).?);
    try testing.expectEqual(@as(usize, plan.request_count), authority.activeObjectCount());
    try testing.expectEqual(process_manager.State.starting, processes.state(child.id).?);

    try manager.commit(&processes, child.id);
    try testing.expectEqual(Phase.running, manager.phase(child.id).?);
    try testing.expectEqual(process_manager.State.running, processes.state(child.id).?);
    try testing.expectError(error.InvalidLifecycleState, manager.commit(&processes, child.id));

    try manager.exit(&processes, child.id, 37);
    try testing.expectEqual(Phase.exited, manager.phase(child.id).?);
    const status = try manager.reap(&processes, &authority, parent.id, child.pid);
    try testing.expectEqual(@as(i32, 37), status.exit_code);
    try testing.expectEqual(@as(u32, 2), status.pid);
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
    try testing.expectEqual(@as(usize, 0), authority.activeCapabilityCount());
    try testing.expectEqual(@as(usize, 0), manager.activeCount());
    try testing.expectEqual(@as(usize, 1), processes.activeCount());
}

test "abort rolls back all resources and leaves a waitable failed child" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    const child = try processes.spawn(parent.id, 2);
    const plan = testPlan(child.id);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};

    _ = try manager.prepare(&processes, &authority, child, plan);
    try manager.abort(&processes, &authority, child.id);
    try testing.expectEqual(Phase.aborted, manager.phase(child.id).?);
    try testing.expectEqual(process_manager.State.failed, processes.state(child.id).?);
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
    try testing.expectEqual(@as(usize, 0), authority.activeCapabilityCount());

    const status = try manager.reap(&processes, &authority, parent.id, child.pid);
    try testing.expectEqual(abort_exit_code, status.exit_code);
    try testing.expectEqual(@as(usize, 0), manager.activeCount());
}

test "reap rejects a non-child before releasing any reserved object" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    const child_a = try processes.spawn(parent.id, 2);
    const child_b = try processes.spawn(parent.id, 3);
    const grandchild = try processes.spawn(child_a.id, 4);
    const plan = testPlan(grandchild.id);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};

    _ = try manager.prepare(&processes, &authority, grandchild, plan);
    try processes.markRunning(child_a.id);
    try processes.markRunning(grandchild.id);
    try processes.exit(grandchild.id, 0);

    try testing.expectError(
        error.ChildNotFound,
        manager.reap(&processes, &authority, parent.id, grandchild.pid),
    );
    try testing.expectEqual(@as(usize, plan.request_count), authority.activeObjectCount());

    _ = try manager.reap(&processes, &authority, child_a.id, grandchild.pid);
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
    try testing.expectEqual(child_b.pid, processes.lookupPid(child_b.pid).?.pid);
}

test "reap revokes delegated descendants before destroying the process resources" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    const child = try processes.spawn(parent.id, 2);
    const plan = testPlan(child.id);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};

    _ = try manager.prepare(&processes, &authority, child, plan);
    const vspace_cap = manager.find(child.id).?.reservations.capabilities[0];
    const delegate = try authority.grant(
        vspace_cap,
        child.id,
        parent.id,
        .{ .map = true },
    );
    try manager.commit(&processes, child.id);
    try manager.exit(&processes, child.id, 0);
    _ = try manager.reap(&processes, &authority, parent.id, child.pid);

    try testing.expectError(
        error.StaleCapability,
        authority.lookup(delegate, parent.id, .{ .map = true }),
    );
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
}
