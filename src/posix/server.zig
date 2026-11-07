// SPDX-License-Identifier: BSD-2-Clause
//! Microkit entry-point translation unit for the POSIX service.

// Microkit's libmicrokit supplies the actual _start symbol. This declaration
// tells Zig not to synthesize the hosted std.start entry point.
pub const _start = {};

const service = @import("service.zig");

comptime {
    _ = service.zweig_posix_dispatch;
    _ = service.init;
    _ = service.notified;
}
