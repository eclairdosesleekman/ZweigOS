// SPDX-License-Identifier: BSD-2-Clause
//! Unified test root for all Zig modules under src/.

test {
    _ = @import("core/tests.zig");
    _ = @import("posix/tests.zig");
}
