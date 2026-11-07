// SPDX-License-Identifier: BSD-2-Clause
//! Common-src module root for the POSIX Microkit Protection Domain.

pub const _start = {};

const component = @import("posix/server.zig");

comptime {
    _ = component.zweig_posix_dispatch;
    _ = component.init;
    _ = component.notified;
}
