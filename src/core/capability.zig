// SPDX-License-Identifier: BSD-2-Clause
//! Typed handles for services whose actual seL4 endpoint capabilities are
//! installed by the static Microkit system description.
//!
//! This table is a user-space policy layer, not a CSpace allocator or a
//! capability-minting mechanism.

pub const Service = enum(u8) {
    memory = 1,
};

pub const Rights = packed struct(u8) {
    call: bool = false,
    notify: bool = false,
    receive: bool = false,
    reserved: u5 = 0,

    pub fn allows(self: Rights, requested: Rights) bool {
        return self.reserved == 0 and requested.reserved == 0 and
            (!requested.call or self.call) and
            (!requested.notify or self.notify) and
            (!requested.receive or self.receive);
    }
};

pub const ServiceCapability = struct {
    service: Service,
    channel: u32,
    rights: Rights,
};

const max_entries = 8;

pub const Table = struct {
    entries: [max_entries]?ServiceCapability = @splat(null),

    pub fn install(self: *Table, capability: ServiceCapability) error{ AlreadyInstalled, TableFull }!void {
        for (self.entries) |entry| {
            if (entry) |installed| {
                if (installed.service == capability.service) return error.AlreadyInstalled;
            }
        }

        for (&self.entries) |*entry| {
            if (entry.* == null) {
                entry.* = capability;
                return;
            }
        }
        return error.TableFull;
    }

    pub fn lookup(
        self: *const Table,
        service: Service,
        requested: Rights,
    ) error{ NotFound, PermissionDenied }!ServiceCapability {
        for (self.entries) |entry| {
            if (entry) |installed| {
                if (installed.service == service) {
                    if (!installed.rights.allows(requested)) return error.PermissionDenied;
                    return installed;
                }
            }
        }
        return error.NotFound;
    }
};

test "service handle lookup enforces least-privilege rights" {
    const std = @import("std");
    var table = Table{};
    try table.install(.{
        .service = .memory,
        .channel = 0,
        .rights = .{ .call = true },
    });

    const memory = try table.lookup(.memory, .{ .call = true });
    try std.testing.expectEqual(@as(u32, 0), memory.channel);
    try std.testing.expectError(error.PermissionDenied, table.lookup(.memory, .{ .receive = true }));
    try std.testing.expectError(
        error.AlreadyInstalled,
        table.install(.{ .service = .memory, .channel = 1, .rights = .{ .call = true } }),
    );
}
