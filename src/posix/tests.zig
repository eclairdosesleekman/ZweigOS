// SPDX-License-Identifier: BSD-2-Clause
//! Unit-test entry point for the first POSIX environment modules.

test {
    _ = @import("abi.zig");
    _ = @import("fd_table.zig");
    _ = @import("load_plan.zig");
}
