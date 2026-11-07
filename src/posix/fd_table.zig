// SPDX-License-Identifier: BSD-2-Clause
//! Fixed-size descriptor table for the first POSIX service instance.
//!
//! The Phase 3 service owns descriptors for the bootstrap task. Later process
//! isolation work will move descriptor tables into per-process state.

pub const max_fds: usize = 32;

pub const Kind = enum(u8) {
    unused,
    console_input,
    console_output,
    console_error,
};

const Entry = struct {
    open: bool = false,
    kind: Kind = .unused,
};

pub const Table = struct {
    entries: [max_fds]Entry = @splat(.{}),

    pub fn standard() Table {
        var table = Table{};
        table.entries[0] = .{ .open = true, .kind = .console_input };
        table.entries[1] = .{ .open = true, .kind = .console_output };
        table.entries[2] = .{ .open = true, .kind = .console_error };
        return table;
    }

    pub fn isOpen(self: *const Table, fd: i64) bool {
        const index = toIndex(fd) orelse return false;
        return self.entries[index].open;
    }

    pub fn canRead(self: *const Table, fd: i64) bool {
        const index = toIndex(fd) orelse return false;
        const entry = self.entries[index];
        return entry.open and entry.kind == .console_input;
    }

    pub fn canWrite(self: *const Table, fd: i64) bool {
        const index = toIndex(fd) orelse return false;
        const entry = self.entries[index];
        return entry.open and (entry.kind == .console_output or entry.kind == .console_error);
    }

    pub fn close(self: *Table, fd: i64) bool {
        const index = toIndex(fd) orelse return false;
        if (!self.entries[index].open) return false;
        self.entries[index] = .{};
        return true;
    }

    fn toIndex(fd: i64) ?usize {
        if (fd < 0 or fd >= @as(i64, @intCast(max_fds))) return null;
        return @intCast(fd);
    }
};

test "standard descriptors have the expected direction and can be closed" {
    const std = @import("std");
    var table = Table.standard();

    try std.testing.expect(table.canRead(0));
    try std.testing.expect(!table.canWrite(0));
    try std.testing.expect(table.canWrite(1));
    try std.testing.expect(table.canWrite(2));
    try std.testing.expect(!table.canRead(1));
    try std.testing.expect(!table.isOpen(3));

    try std.testing.expect(table.close(1));
    try std.testing.expect(!table.canWrite(1));
    try std.testing.expect(!table.close(1));
    try std.testing.expect(!table.close(-1));
    try std.testing.expect(!table.close(99));
}
