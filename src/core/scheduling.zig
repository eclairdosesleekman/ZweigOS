// SPDX-License-Identifier: BSD-2-Clause
//! Validation helpers for MCS profiles declared in the Microkit system file.
//!
//! The kernel scheduling contexts are created by Microkit's static system
//! composition in this phase; this module validates policy values rather
//! than creating Scheduling Context objects at runtime.

pub const Profile = struct {
    priority: u8,
    budget_us: u64,
    period_us: u64,

    pub fn validate(
        self: Profile,
    ) error{InvalidPriority, InvalidPeriod, InvalidBudget}!void {
        if (self.priority > 254) return error.InvalidPriority;
        if (self.period_us == 0) return error.InvalidPeriod;
        if (self.budget_us == 0 or self.budget_us > self.period_us) {
            return error.InvalidBudget;
        }
    }

    pub fn utilizationPermille(
        self: Profile,
    ) error{InvalidPriority, InvalidPeriod, InvalidBudget}!u16 {
        try self.validate();
        const scaled: u128 = @as(u128, self.budget_us) * 1000;
        return @intCast(scaled / self.period_us);
    }
};

test "MCS profile accepts bounded budget and calculates utilization" {
    const std = @import("std");
    const profile = Profile{
        .priority = 99,
        .budget_us = 1000,
        .period_us = 10000,
    };
    try std.testing.expectEqual(
        @as(u16, 100),
        try profile.utilizationPermille(),
    );
}

test "MCS profile rejects invalid period and over-budget execution" {
    const std = @import("std");
    try std.testing.expectError(
        error.InvalidPeriod,
        (Profile{ .priority = 1, .budget_us = 1, .period_us = 0 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidBudget,
        (Profile{ .priority = 1, .budget_us = 11, .period_us = 10 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidPriority,
        (Profile{
            .priority = 255,
            .budget_us = 1,
            .period_us = 10,
        }).validate(),
    );
}
