// SPDX-License-Identifier: BSD-2-Clause
//! Stable Zweig userspace syscall ABI.
//!
//! Syscall numbers are Zweig ABI numbers, not Linux syscall numbers. Results
//! use the common raw-syscall convention: non-negative success values and
//! negative POSIX errno values on failure. A libc adapter converts these to
//! -1 plus thread-local errno.

pub const Syscall = enum(u64) {
    read = 1,
    write = 2,
    close = 3,
    getpid = 4,
};

pub const Errno = enum(u16) {
    permission = 1,
    no_entry = 2,
    interrupted = 4,
    io = 5,
    bad_fd = 9,
    try_again = 11,
    out_of_memory = 12,
    invalid = 22,
    not_implemented = 38,
};

pub fn failure(errno: Errno) i64 {
    return -@as(i64, @intCast(@intFromEnum(errno)));
}

pub fn isFailure(result: i64) bool {
    return result < 0 and result >= -4095;
}

test "Zweig syscall numbers and errno encoding are stable" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(Syscall.read));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(Syscall.write));
    try std.testing.expectEqual(@as(u64, 3), @intFromEnum(Syscall.close));
    try std.testing.expectEqual(@as(u64, 4), @intFromEnum(Syscall.getpid));
    try std.testing.expectEqual(@as(i64, -9), failure(.bad_fd));
    try std.testing.expect(isFailure(failure(.try_again)));
    try std.testing.expect(!isFailure(128));
}
