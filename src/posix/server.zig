// SPDX-License-Identifier: BSD-2-Clause
//! Microkit entry-point translation unit for the POSIX service.

const service = @import("service.zig");

comptime {
    _ = service.zweig_posix_dispatch;
    _ = service.init;
    _ = service.notified;
}
