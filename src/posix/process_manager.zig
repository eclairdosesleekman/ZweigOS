// SPDX-License-Identifier: BSD-2-Clause
//! Bounded POSIX process bookkeeping for Phase 4.
//!
//! This module owns Zweig PIDs, parent/child relationships, process lifecycle
//! state, wait/reap semantics, and a distinct descriptor table per process.
//! A spawn reserves metadata only: it does not create a seL4 TCB, CNode,
//! VSpace, Scheduling Context, or executable image.

const std = @import("std");
const process_registry = @import("../core/process.zig");
const fd_table = @import("fd_table.zig");

pub const max_processes = process_registry.max_processes;
pub const ProcessId = process_registry.Id;
pub const State = process_registry.State;

pub const ProcessInfo = struct {
    id: ProcessId,
    pid: u32,
};

pub const ExitInfo = struct {
    pid: u32,
    exit_code: i32,
};

const Record = struct {
    active: bool = false,
    id: ?ProcessId = null,
    pid: u32 = 0,
    parent: ?ProcessId = null,
    descriptors: fd_table.Table = .{},
};

pub const Table = struct {
    registry: process_registry.Table = .{},
    records: [max_processes]Record = @splat(.{}),
    initialized: bool = false,
    next_pid: u32 = 1,

    pub fn initialize(
        self: *Table,
        bootstrap_domain_id: u16,
    ) error{ AlreadyInitialized, AlreadyRegistered, TableFull }!ProcessInfo {
        if (self.initialized) return error.AlreadyInitialized;
        const record = self.freeRecord() orelse return error.TableFull;
        const id = self.registry.register(bootstrap_domain_id) catch |err| {
            return switch (err) {
                error.AlreadyRegistered => error.AlreadyRegistered,
                error.TableFull => error.TableFull,
            };
        };
        self.registry.markRunning(id) catch unreachable;

        record.* = .{
            .active = true,
            .id = id,
            .pid = 1,
            .parent = null,
            .descriptors = fd_table.Table.standard(),
        };
        self.initialized = true;
        self.next_pid = 2;
        return .{ .id = id, .pid = 1 };
    }

    pub fn spawn(
        self: *Table,
        parent_id: ProcessId,
        domain_id: u16,
    ) error{
        StaleProcessId,
        ParentNotRunning,
        ProcessIdExhausted,
        AlreadyRegistered,
        TableFull,
    }!ProcessInfo {
        const parent = self.find(parent_id) orelse return error.StaleProcessId;
        const parent_state = self.registry.state(parent_id) catch return error.StaleProcessId;
        if (parent_state != .running) return error.ParentNotRunning;
        if (self.next_pid == 0) return error.ProcessIdExhausted;
        const child_record = self.freeRecord() orelse return error.TableFull;

        const child_id = self.registry.register(domain_id) catch |err| {
            return switch (err) {
                error.AlreadyRegistered => error.AlreadyRegistered,
                error.TableFull => error.TableFull,
            };
        };

        const child_pid = self.next_pid;
        self.next_pid +%= 1;
        child_record.* = .{
            .active = true,
            .id = child_id,
            .pid = child_pid,
            .parent = parent_id,
            // Descriptor entries are copied by value. Closing/reassigning a
            // descriptor in one process cannot mutate its parent's table.
            .descriptors = parent.descriptors,
        };
        return .{ .id = child_id, .pid = child_pid };
    }

    pub fn markRunning(
        self: *Table,
        id: ProcessId,
    ) error{ StaleProcessId, InvalidStateTransition }!void {
        if (self.find(id) == null) return error.StaleProcessId;
        const current = self.registry.state(id) catch return error.StaleProcessId;
        if (current != .starting) return error.InvalidStateTransition;
        self.registry.markRunning(id) catch return error.StaleProcessId;
    }

    pub fn exit(
        self: *Table,
        id: ProcessId,
        exit_code: i32,
    ) error{ StaleProcessId, InvalidStateTransition }!void {
        if (self.find(id) == null) return error.StaleProcessId;
        const current = self.registry.state(id) catch return error.StaleProcessId;
        if (current != .starting and current != .running) return error.InvalidStateTransition;
        self.registry.markExited(id, exit_code) catch return error.StaleProcessId;
    }

    pub fn fail(
        self: *Table,
        id: ProcessId,
        exit_code: i32,
    ) error{ StaleProcessId, InvalidStateTransition }!void {
        if (self.find(id) == null) return error.StaleProcessId;
        const current = self.registry.state(id) catch return error.StaleProcessId;
        if (current != .starting and current != .running) return error.InvalidStateTransition;
        self.registry.markFailed(id, exit_code) catch return error.StaleProcessId;
    }

    pub fn wait(
        self: *Table,
        parent_id: ProcessId,
        child_pid: u32,
    ) error{ StaleProcessId, ParentNotRunning, ChildNotFound, WouldBlock, HasChildren }!ExitInfo {
        if (self.find(parent_id) == null) return error.StaleProcessId;
        const parent_state = self.registry.state(parent_id) catch return error.StaleProcessId;
        if (parent_state != .running) return error.ParentNotRunning;

        const child = self.findChild(parent_id, child_pid) orelse return error.ChildNotFound;
        const child_id = child.id orelse return error.StaleProcessId;
        const child_state = self.registry.state(child_id) catch return error.StaleProcessId;
        if (child_state == .starting or child_state == .running) return error.WouldBlock;
        if (self.hasActiveChildren(child_id)) return error.HasChildren;

        const result = ExitInfo{
            .pid = child.pid,
            .exit_code = self.registry.exitCode(child_id) catch return error.StaleProcessId,
        };
        self.registry.remove(child_id) catch return error.StaleProcessId;
        child.* = .{};
        return result;
    }

    pub fn descriptors(self: *Table, id: ProcessId) ?*fd_table.Table {
        const record = self.find(id) orelse return null;
        return &record.descriptors;
    }

    pub fn pid(self: *const Table, id: ProcessId) ?u32 {
        const record = self.findConst(id) orelse return null;
        return record.pid;
    }

    pub fn lookupPid(self: *const Table, pid_value: u32) ?ProcessInfo {
        for (self.records) |record| {
            if (record.active and record.pid == pid_value) {
                return .{ .id = record.id.?, .pid = record.pid };
            }
        }
        return null;
    }

    pub fn state(self: *const Table, id: ProcessId) ?State {
        if (self.findConst(id) == null) return null;
        return self.registry.state(id) catch null;
    }

    pub fn activeCount(self: *const Table) usize {
        var count: usize = 0;
        for (self.records) |record| {
            if (record.active) count += 1;
        }
        return count;
    }

    fn freeRecord(self: *Table) ?*Record {
        for (&self.records) |*record| {
            if (!record.active) return record;
        }
        return null;
    }

    fn find(self: *Table, id: ProcessId) ?*Record {
        for (&self.records) |*record| {
            if (!record.active) continue;
            if (record.id) |existing| {
                if (sameId(existing, id)) return record;
            }
        }
        return null;
    }

    fn findConst(self: *const Table, id: ProcessId) ?*const Record {
        for (&self.records) |*record| {
            if (!record.active) continue;
            if (record.id) |existing| {
                if (sameId(existing, id)) return record;
            }
        }
        return null;
    }

    fn findChild(self: *Table, parent_id: ProcessId, child_pid: u32) ?*Record {
        for (&self.records) |*record| {
            if (!record.active or record.pid != child_pid) continue;
            if (record.parent) |record_parent| {
                if (sameId(record_parent, parent_id)) return record;
            }
        }
        return null;
    }

    fn hasActiveChildren(self: *const Table, parent_id: ProcessId) bool {
        for (self.records) |record| {
            if (!record.active) continue;
            if (record.parent) |record_parent| {
                if (sameId(record_parent, parent_id)) return true;
            }
        }
        return false;
    }

    fn sameId(left: ProcessId, right: ProcessId) bool {
        return left.slot == right.slot and left.generation == right.generation;
    }
};

test "bootstrap and child receive unique PIDs and independent inherited descriptors" {
    var table = Table{};
    const bootstrap = try table.initialize(1);
    try std.testing.expectEqual(@as(u32, 1), bootstrap.pid);
    try std.testing.expectEqual(State.running, table.state(bootstrap.id).?);

    const child = try table.spawn(bootstrap.id, 2);
    try std.testing.expectEqual(@as(u32, 2), child.pid);
    try std.testing.expectEqual(child.id.slot, table.lookupPid(2).?.id.slot);

    const parent_fds = table.descriptors(bootstrap.id).?;
    const child_fds = table.descriptors(child.id).?;
    try std.testing.expect(parent_fds.canWrite(1));
    try std.testing.expect(child_fds.canWrite(1));
    try std.testing.expect(child_fds.close(1));
    try std.testing.expect(!child_fds.canWrite(1));
    try std.testing.expect(parent_fds.canWrite(1));
}

test "wait blocks until exit then returns status and reaps the generation-checked ID" {
    var table = Table{};
    const parent = try table.initialize(1);
    const child = try table.spawn(parent.id, 2);

    try std.testing.expectError(error.WouldBlock, table.wait(parent.id, child.pid));
    try table.markRunning(child.id);
    try table.exit(child.id, 42);

    const result = try table.wait(parent.id, child.pid);
    try std.testing.expectEqual(@as(u32, 2), result.pid);
    try std.testing.expectEqual(@as(i32, 42), result.exit_code);
    try std.testing.expectEqual(@as(usize, 1), table.activeCount());
    try std.testing.expect(table.descriptors(child.id) == null);
    try std.testing.expectError(error.StaleProcessId, table.markRunning(child.id));
    try std.testing.expectError(error.ChildNotFound, table.wait(parent.id, child.pid));
}

test "parent must reap descendants before its own exited child" {
    var table = Table{};
    const parent = try table.initialize(1);
    const child = try table.spawn(parent.id, 2);
    try table.markRunning(child.id);
    const grandchild = try table.spawn(child.id, 3);
    try table.markRunning(grandchild.id);

    try table.exit(child.id, 7);
    try std.testing.expectError(error.HasChildren, table.wait(parent.id, child.pid));

    try table.exit(grandchild.id, 0);
    const grandchild_result = try table.wait(child.id, grandchild.pid);
    try std.testing.expectEqual(@as(i32, 0), grandchild_result.exit_code);
    const child_result = try table.wait(parent.id, child.pid);
    try std.testing.expectEqual(@as(i32, 7), child_result.exit_code);
}

test "failed children are waitable and process table capacity is bounded" {
    var table = Table{};
    const parent = try table.initialize(1);
    const child = try table.spawn(parent.id, 2);
    try table.fail(child.id, -5);
    const result = try table.wait(parent.id, child.pid);
    try std.testing.expectEqual(@as(i32, -5), result.exit_code);

    for (0..max_processes - 1) |index| {
        _ = try table.spawn(parent.id, @intCast(index + 3));
    }
    try std.testing.expectEqual(max_processes, table.activeCount());
    try std.testing.expectError(error.TableFull, table.spawn(parent.id, 99));
}

test "process registration rejects duplicate domains and repeated bootstrap initialization" {
    var table = Table{};
    const parent = try table.initialize(1);
    try std.testing.expectError(error.AlreadyInitialized, table.initialize(2));
    _ = try table.spawn(parent.id, 2);
    try std.testing.expectError(error.AlreadyRegistered, table.spawn(parent.id, 2));
}
