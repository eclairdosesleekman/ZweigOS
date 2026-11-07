// SPDX-License-Identifier: BSD-2-Clause
//! Fixed-width RPC protocol shared by the client and memory service.

pub const ChannelId = u32;

pub const Operation = enum(u64) {
    ping = 1,
    allocate_pages = 2,
    release_pages = 3,
    get_stats = 4,
};

pub const Status = enum(u32) {
    ok = 0,
    invalid_request = 1,
    invalid_argument = 2,
    out_of_memory = 3,
    stale_lease = 4,
    internal_error = 5,
};

pub const Stats = struct {
    total_pages: u32,
    free_pages: u32,
};

test "operation IDs remain stable for the wire ABI" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 1), @backingInt(Operation.ping));
    try std.testing.expectEqual(@as(u64, 2), @backingInt(Operation.allocate_pages));
    try std.testing.expectEqual(@as(u64, 3), @backingInt(Operation.release_pages));
    try std.testing.expectEqual(@as(u64, 4), @backingInt(Operation.get_stats));
}
