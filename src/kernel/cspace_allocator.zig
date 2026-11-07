// SPDX-License-Identifier: BSD-2-Clause
//! Bounded allocator for a caller-owned CSpace slot window.
//!
//! CPtr values produced here are local to the configured CSpace. They must not
//! be serialized into an IPC message or treated as globally meaningful IDs.

pub const max_slots: usize = 256;

pub const State = enum(u8) {
    free,
    reserved,
    installed,
    deleted,
    quarantined,
};

pub const Lease = struct {
    start: u16,
    count: u16,
    generation: u32,
    owner: u64,
};

const Slot = struct {
    generation: u32 = 1,
    lease_generation: u32 = 0,
    owner: u64 = 0,
    state: State = .free,
};

pub const Error = error{
    InvalidWindow,
    InvalidOwner,
    InvalidCount,
    NoContiguousSlots,
    StaleLease,
    WrongOwner,
    InvalidState,
    IndexOutOfRange,
    CPtrOverflow,
};

pub const Allocator = struct {
    base_cptr: u64,
    capacity: u16,
    next_lease_generation: u32 = 1,
    slots: [max_slots]Slot = @splat(.{}),

    pub fn init(base_cptr: u64, capacity: u16) Error!Allocator {
        if (base_cptr == 0 or capacity == 0 or capacity > max_slots) return error.InvalidWindow;
        const end = @addWithOverflow(base_cptr, @as(u64, capacity));
        if (end[1] != 0) return error.InvalidWindow;
        return .{
            .base_cptr = base_cptr,
            .capacity = capacity,
        };
    }

    /// Reserve a contiguous range atomically. No slot is modified until a
    /// complete free run has been found.
    pub fn reserve(self: *Allocator, owner: u64, count: u32) Error!Lease {
        if (owner == 0) return error.InvalidOwner;
        if (count == 0 or count > @as(u32, self.capacity)) return error.InvalidCount;

        const needed: usize = @intCast(count);
        const capacity: usize = self.capacity;
        var run_start: usize = 0;
        var run_length: usize = 0;
        var found: ?usize = null;

        for (self.slots[0..capacity], 0..) |slot, index| {
            if (slot.state == .free) {
                if (run_length == 0) run_start = index;
                run_length += 1;
                if (run_length == needed) {
                    found = run_start;
                    break;
                }
            } else {
                run_length = 0;
            }
        }
        const start = found orelse return error.NoContiguousSlots;

        const generation = self.next_lease_generation;
        self.next_lease_generation = nextGeneration(self.next_lease_generation);
        for (self.slots[start .. start + needed]) |*slot| {
            slot.lease_generation = generation;
            slot.owner = owner;
            slot.state = .reserved;
        }

        return .{
            .start = @intCast(start),
            .count = @intCast(needed),
            .generation = generation,
            .owner = owner,
        };
    }

    pub fn cptr(self: *const Allocator, lease: Lease, index: u32) Error!u64 {
        try self.validate(lease);
        if (index >= lease.count) return error.IndexOutOfRange;
        const slot_index = @as(u64, lease.start) + @as(u64, index);
        const result = @addWithOverflow(self.base_cptr, slot_index);
        if (result[1] != 0) return error.CPtrOverflow;
        return result[0];
    }

    pub fn markInstalled(self: *Allocator, lease: Lease) Error!void {
        try self.validate(lease);
        const start: usize = lease.start;
        const end = start + @as(usize, lease.count);
        for (self.slots[start..end]) |slot| {
            if (slot.state != .reserved) return error.InvalidState;
        }
        for (self.slots[start..end]) |*slot| {
            slot.state = .installed;
        }
    }

    /// Mark one slot after its capability has been deleted successfully.
    /// This makes cleanup retryable without repeating already completed work.
    pub fn markSlotDeleted(self: *Allocator, lease: Lease, index: u32) Error!void {
        try self.validate(lease);
        if (index >= lease.count) return error.IndexOutOfRange;
        const slot_index = @as(usize, lease.start) + @as(usize, @intCast(index));
        const slot = &self.slots[slot_index];
        if (slot.state != .installed and slot.state != .deleted) {
            return error.InvalidState;
        }
        slot.state = .deleted;
    }

    pub fn stateAt(self: *const Allocator, lease: Lease, index: u32) Error!State {
        try self.validate(lease);
        if (index >= lease.count) return error.IndexOutOfRange;
        const slot_index = @as(usize, lease.start) + @as(usize, @intCast(index));
        return self.slots[slot_index].state;
    }

    /// Quarantine means that external kernel state is uncertain. Such slots
    /// are intentionally never returned to the allocator.
    pub fn quarantine(self: *Allocator, lease: Lease) Error!void {
        try self.validate(lease);
        const start: usize = lease.start;
        const end = start + @as(usize, lease.count);
        for (self.slots[start..end]) |*slot| {
            slot.state = .quarantined;
        }
    }

    /// Release is permitted only for unused reservations or slots whose
    /// capabilities have already been deleted by the kernel backend.
    pub fn release(self: *Allocator, lease: Lease) Error!void {
        try self.validate(lease);
        const start: usize = lease.start;
        const end = start + @as(usize, lease.count);
        for (self.slots[start..end]) |slot| {
            if (slot.state != .reserved and slot.state != .deleted) {
                return error.InvalidState;
            }
        }
        for (self.slots[start..end]) |*slot| {
            const generation = nextGeneration(slot.generation);
            slot.* = .{ .generation = generation };
        }
    }

    pub fn freeCount(self: *const Allocator) usize {
        var count: usize = 0;
        for (self.slots[0..@as(usize, self.capacity)]) |slot| {
            if (slot.state == .free) count += 1;
        }
        return count;
    }

    fn validate(self: *const Allocator, lease: Lease) Error!void {
        if (lease.count == 0 or lease.start >= self.capacity or
            @as(u32, lease.start) + @as(u32, lease.count) > @as(u32, self.capacity))
        {
            return error.StaleLease;
        }
        if (lease.owner == 0) return error.InvalidOwner;
        const start: usize = lease.start;
        const end = start + @as(usize, lease.count);
        for (self.slots[start..end]) |slot| {
            if (slot.state == .free or slot.state == .quarantined or
                slot.lease_generation != lease.generation)
            {
                return error.StaleLease;
            }
            if (slot.owner != lease.owner) return error.WrongOwner;
        }
    }
};

fn nextGeneration(value: u32) u32 {
    const next = value +% 1;
    return if (next == 0) 1 else next;
}

test "CSpace allocator reserves contiguous runs and reuses released slots with new generations" {
    const std = @import("std");
    var allocator = try Allocator.init(0x20, 8);
    const first = try allocator.reserve(1, 3);
    try std.testing.expectEqual(@as(u64, 0x20), try allocator.cptr(first, 0));
    try std.testing.expectEqual(@as(u64, 0x22), try allocator.cptr(first, 2));
    try allocator.release(first);

    const second = try allocator.reserve(1, 3);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expectError(error.StaleLease, allocator.cptr(first, 0));
}

test "CSpace allocator does not release an installed capability" {
    const std = @import("std");
    var allocator = try Allocator.init(0x40, 4);
    const lease = try allocator.reserve(7, 2);
    try allocator.markInstalled(lease);
    try std.testing.expectError(error.InvalidState, allocator.release(lease));
    try std.testing.expectEqual(@as(usize, 2), allocator.freeCount());
}

test "CSpace allocator validates a batch before changing slots" {
    const std = @import("std");
    var allocator = try Allocator.init(0x10, 4);
    const lease = try allocator.reserve(11, 2);
    try allocator.markInstalled(lease);
    try allocator.markSlotDeleted(lease, 0);
    try std.testing.expectError(error.WrongOwner, allocator.release(.{
        .start = lease.start,
        .count = lease.count,
        .generation = lease.generation,
        .owner = 12,
    }));
    try std.testing.expectEqual(State.deleted, try allocator.stateAt(lease, 0));
    try std.testing.expectEqual(State.installed, try allocator.stateAt(lease, 1));
}

test "CSpace allocator quarantines uncertain slots permanently" {
    const std = @import("std");
    var allocator = try Allocator.init(0x80, 4);
    const lease = try allocator.reserve(3, 2);
    try allocator.quarantine(lease);
    try std.testing.expectError(error.StaleLease, allocator.release(lease));
    try std.testing.expectEqual(@as(usize, 2), allocator.freeCount());
}
