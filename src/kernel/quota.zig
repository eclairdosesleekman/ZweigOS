// SPDX-License-Identifier: BSD-2-Clause
//! Atomic per-process limits for physical frames, CSpace slots and kernel objects.

const process = @import("../core/process.zig");
pub const max_owners: usize = process.max_processes;

pub const Usage = struct {
    frame_pages: u64 = 0,
    cspace_slots: u64 = 0,
    kernel_objects: u64 = 0,
    tcbs: u64 = 0,
    scheduling_contexts: u64 = 0,
    untyped_bytes: u64 = 0,

    pub fn fitsWithin(self: Usage, limits: Usage) bool {
        return self.frame_pages <= limits.frame_pages and
            self.cspace_slots <= limits.cspace_slots and
            self.kernel_objects <= limits.kernel_objects and
            self.tcbs <= limits.tcbs and
            self.scheduling_contexts <= limits.scheduling_contexts and
            self.untyped_bytes <= limits.untyped_bytes;
    }

    fn add(self: Usage, other: Usage) Error!Usage {
        return .{
            .frame_pages = try addOne(self.frame_pages, other.frame_pages),
            .cspace_slots = try addOne(self.cspace_slots, other.cspace_slots),
            .kernel_objects = try addOne(self.kernel_objects, other.kernel_objects),
            .tcbs = try addOne(self.tcbs, other.tcbs),
            .scheduling_contexts = try addOne(self.scheduling_contexts, other.scheduling_contexts),
            .untyped_bytes = try addOne(self.untyped_bytes, other.untyped_bytes),
        };
    }

    fn subtract(self: Usage, other: Usage) Error!Usage {
        if (other.frame_pages > self.frame_pages or
            other.cspace_slots > self.cspace_slots or
            other.kernel_objects > self.kernel_objects or
            other.tcbs > self.tcbs or
            other.scheduling_contexts > self.scheduling_contexts or
            other.untyped_bytes > self.untyped_bytes) return error.CorruptState;
        return .{
            .frame_pages = self.frame_pages - other.frame_pages,
            .cspace_slots = self.cspace_slots - other.cspace_slots,
            .kernel_objects = self.kernel_objects - other.kernel_objects,
            .tcbs = self.tcbs - other.tcbs,
            .scheduling_contexts = self.scheduling_contexts - other.scheduling_contexts,
            .untyped_bytes = self.untyped_bytes - other.untyped_bytes,
        };
    }
};

pub const Limits = Usage;
pub const Lease = struct { owner: process.Id, generation: u32, usage: Usage };

const Record = struct {
    active: bool = false,
    generation: u32 = 1,
    owner: process.Id = .{ .slot = 0, .generation = 0 },
    limits: Limits = .{},
    used: Usage = .{},
};

pub const Error = error{
    InvalidOwner, AlreadyRegistered, TableFull, UnknownOwner, QuotaExceeded,
    ArithmeticOverflow, StaleLease, CorruptState,
};

pub const Table = struct {
    records: [max_owners]Record = @splat(.{}),
    next_lease_generation: u32 = 1,

    pub fn register(self: *Table, owner: process.Id, limits: Limits) Error!void {
        if (!validOwner(owner)) return error.InvalidOwner;
        if (self.find(owner) != null) return error.AlreadyRegistered;
        const slot = self.freeRecord() orelse return error.TableFull;
        slot.* = .{
            .active = true, .generation = slot.generation,
            .owner = owner, .limits = limits, .used = .{},
        };
    }

    /// Check every dimension before changing any counter.
    pub fn reserve(self: *Table, owner: process.Id, usage: Usage) Error!Lease {
        const record = self.find(owner) orelse return error.UnknownOwner;
        const next = try record.used.add(usage);
        if (!next.fitsWithin(record.limits)) return error.QuotaExceeded;
        const generation = self.next_lease_generation;
        self.next_lease_generation = nextGeneration(generation);
        record.used = next;
        return .{ .owner = owner, .generation = generation, .usage = usage };
    }

    pub fn release(self: *Table, lease: Lease) Error!void {
        const record = self.find(lease.owner) orelse return error.StaleLease;
        _ = lease.generation;
        record.used = try record.used.subtract(lease.usage);
    }

    pub fn usage(self: *const Table, owner: process.Id) ?Usage {
        const record = self.findConst(owner) orelse return null;
        return record.used;
    }

    pub fn unregister(self: *Table, owner: process.Id) Error!void {
        const record = self.find(owner) orelse return error.UnknownOwner;
        if (!record.used.fitsWithin(.{})) return error.CorruptState;
        const generation = nextGeneration(record.generation);
        record.* = .{ .generation = generation };
    }

    fn freeRecord(self: *Table) ?*Record {
        for (&self.records) |*record| if (!record.active) return record;
        return null;
    }
    fn find(self: *Table, owner: process.Id) ?*Record {
        for (&self.records) |*record| {
            if (record.active and sameOwner(record.owner, owner)) return record;
        }
        return null;
    }
    fn findConst(self: *const Table, owner: process.Id) ?*const Record {
        for (&self.records) |*record| {
            if (record.active and sameOwner(record.owner, owner)) return record;
        }
        return null;
    }
};

fn addOne(left: u64, right: u64) Error!u64 {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}
fn validOwner(owner: process.Id) bool {
    return @as(usize, owner.slot) < process.max_processes and owner.generation != 0;
}
fn sameOwner(left: process.Id, right: process.Id) bool {
    return left.slot == right.slot and left.generation == right.generation;
}
fn nextGeneration(value: u32) u32 {
    const next = value +% 1;
    return if (next == 0) 1 else next;
}

test "quota reservation is atomic across every resource dimension" {
    const std = @import("std");
    const owner = process.Id{ .slot = 1, .generation = 4 };
    var table = Table{};
    try table.register(owner, .{
        .frame_pages = 16, .cspace_slots = 8, .kernel_objects = 8,
        .tcbs = 2, .scheduling_contexts = 2, .untyped_bytes = 65536,
    });
    const lease = try table.reserve(owner, .{
        .frame_pages = 8, .cspace_slots = 4, .kernel_objects = 4,
        .tcbs = 1, .scheduling_contexts = 1, .untyped_bytes = 32768,
    });
    try std.testing.expectError(error.QuotaExceeded, table.reserve(owner, .{
        .frame_pages = 9, .cspace_slots = 1,
    }));
    try std.testing.expectEqual(@as(u64, 8), table.usage(owner).?.frame_pages);
    try std.testing.expectEqual(@as(u64, 4), table.usage(owner).?.cspace_slots);
    try table.release(lease);
    try std.testing.expectEqual(Usage{}, table.usage(owner).?);
    try table.unregister(owner);
}

test "quota planner rejects overflow and stale process generations" {
    const std = @import("std");
    const owner = process.Id{ .slot = 0, .generation = 1 };
    var table = Table{};
    try table.register(owner, .{ .frame_pages = std.math.maxInt(u64) });
    _ = try table.reserve(owner, .{ .frame_pages = std.math.maxInt(u64) });
    try std.testing.expectError(error.ArithmeticOverflow, table.reserve(owner, .{ .frame_pages = 1 }));
    try std.testing.expectError(
        error.UnknownOwner,
        table.reserve(.{ .slot = 0, .generation = 2 }, .{ .frame_pages = 1 }),
    );
}
