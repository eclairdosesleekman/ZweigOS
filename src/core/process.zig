// SPDX-License-Identifier: BSD-2-Clause
//! Generation-checked process metadata registry.
//!
//! Phase 2 uses this for statically composed service Protection Domains.
//! It does not create or destroy TCBs; dynamic process creation is a later
//! milestone that will pair records with seL4 object-management authority.

pub const max_processes: usize = 32;

pub const State = enum(u8) {
    starting,
    running,
    exited,
    failed,
};

pub const Id = struct {
    slot: u16,
    generation: u16,

    pub fn encode(self: Id) u32 {
        return (@as(u32, self.generation) << 16) | @as(u32, self.slot);
    }

    pub fn decode(raw: u32) Id {
        return .{
            .slot = @truncate(raw),
            .generation = @truncate(raw >> 16),
        };
    }
};

const Entry = struct {
    generation: u16 = 1,
    active: bool = false,
    domain_id: u16 = 0,
    state: State = .starting,
    exit_code: i32 = 0,
};

pub const Table = struct {
    entries: [max_processes]Entry = [_]Entry{.{}} ** max_processes,

    pub fn register(self: *Table, domain_id: u16) error{AlreadyRegistered, TableFull}!Id {
        for (self.entries) |entry| {
            if (entry.active and entry.domain_id == domain_id) return error.AlreadyRegistered;
        }

        for (&self.entries, 0..) |*entry, index| {
            if (!entry.active) {
                entry.active = true;
                entry.domain_id = domain_id;
                entry.state = .starting;
                entry.exit_code = 0;
                return .{
                    .slot = @intCast(index),
                    .generation = entry.generation,
                };
            }
        }
        return error.TableFull;
    }

    pub fn markRunning(self: *Table, id: Id) error{StaleProcessId}!void {
        const entry = self.getEntry(id) orelse return error.StaleProcessId;
        entry.state = .running;
    }

    pub fn markExited(self: *Table, id: Id, exit_code: i32) error{StaleProcessId}!void {
        const entry = self.getEntry(id) orelse return error.StaleProcessId;
        entry.state = .exited;
        entry.exit_code = exit_code;
    }

    pub fn remove(self: *Table, id: Id) error{StaleProcessId}!void {
        const entry = self.getEntry(id) orelse return error.StaleProcessId;
        entry.active = false;
        entry.domain_id = 0;
        entry.state = .starting;
        entry.exit_code = 0;
        entry.generation +%= 1;
        if (entry.generation == 0) entry.generation = 1;
    }

    pub fn state(self: *const Table, id: Id) error{StaleProcessId}!State {
        const index: usize = id.slot;
        if (index >= max_processes) return error.StaleProcessId;
        const entry = self.entries[index];
        if (!entry.active or entry.generation != id.generation) return error.StaleProcessId;
        return entry.state;
    }

    fn getEntry(self: *Table, id: Id) ?*Entry {
        const index: usize = id.slot;
        if (index >= max_processes) return null;
        const entry = &self.entries[index];
        if (!entry.active or entry.generation != id.generation) return null;
        return entry;
    }
};

test "process registry tracks service state and rejects stale IDs" {
    const std = @import("std");
    var table = Table{};
    const id = try table.register(7);

    try std.testing.expectEqual(State.starting, try table.state(id));
    try table.markRunning(id);
    try std.testing.expectEqual(State.running, try table.state(id));
    try table.markExited(id, 23);
    try std.testing.expectEqual(State.exited, try table.state(id));

    const encoded = id.encode();
    try std.testing.expectEqual(id.generation, Id.decode(encoded).generation);
    try table.remove(id);
    try std.testing.expectError(error.StaleProcessId, table.state(id));

    const replacement = try table.register(8);
    try std.testing.expect(replacement.generation != id.generation);
}
