// SPDX-License-Identifier: BSD-2-Clause
//! Allocation-free audit ring. Raw CPtrs and physical addresses are absent.

const process = @import("../core/process.zig");
pub const capacity: usize = 128;

pub const Event = enum(u16) {
    root_registered = 1, quota_reserved = 2, object_created = 3,
    object_configured = 4, capability_copied = 5, capability_minted = 6,
    capability_revoked = 7, capability_deleted = 8, mapping_created = 9,
    mapping_removed = 10, object_destroyed = 11, rollback_started = 12,
    rollback_completed = 13, resource_quarantined = 14, request_denied = 15,
};

pub const Record = struct {
    sequence: u64 = 0,
    timestamp: u64 = 0,
    service_id: u16 = 0,
    process: process.Id = .{ .slot = 0, .generation = 0 },
    severity: u8 = 0,
    event: Event = .request_denied,
    request_id: u32 = 0,
    object_kind: u8 = 0,
    result_code: i32 = 0,
};

pub const Log = struct {
    records: [capacity]Record = @splat(.{}),
    next_sequence: u64 = 1,
    total_written: u64 = 0,

    pub fn append(self: *Log, record: Record) u64 {
        const sequence = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        const index: usize = @intCast((sequence - 1) % capacity);
        var committed = record;
        committed.sequence = sequence;
        self.records[index] = committed;
        self.total_written +%= 1;
        return sequence;
    }

    /// Copy records newer than after_sequence, oldest first.
    pub fn readAfter(self: *const Log, after_sequence: u64, output: []Record) usize {
        if (output.len == 0 or self.total_written == 0) return 0;
        const newest = self.next_sequence - 1;
        const oldest = if (self.total_written > capacity)
            newest - capacity + 1
        else
            newest - self.total_written + 1;
        var cursor = @max(after_sequence +| 1, oldest);
        var copied: usize = 0;
        while (cursor <= newest and copied < output.len) : (cursor += 1) {
            const index: usize = @intCast((cursor - 1) % capacity);
            const record = self.records[index];
            if (record.sequence == cursor) {
                output[copied] = record;
                copied += 1;
            }
        }
        return copied;
    }

    pub fn droppedCount(self: *const Log) u64 {
        return if (self.total_written > capacity) self.total_written - capacity else 0;
    }
};

test "audit ring preserves ordered events and bounds memory" {
    const std = @import("std");
    var log = Log{};
    var i: usize = 0;
    while (i < capacity + 4) : (i += 1) {
        _ = log.append(.{ .timestamp = @intCast(i), .event = .object_created, .request_id = @intCast(i + 1) });
    }
    try std.testing.expectEqual(@as(u64, 4), log.droppedCount());
    var output: [8]Record = undefined;
    const count = log.readAfter(0, &output);
    try std.testing.expectEqual(@as(usize, 8), count);
    try std.testing.expectEqual(@as(u64, 5), output[0].sequence);
    try std.testing.expectEqual(@as(u64, capacity + 4), output[count - 1].sequence);
}
