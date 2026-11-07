// SPDX-License-Identifier: BSD-2-Clause
//! Import all POSIX modules so their unit tests run under the unified root.

test {
    _ = @import("abi.zig");
    _ = @import("fd_table.zig");
    _ = @import("load_plan.zig");
    _ = @import("image_loader.zig");
    _ = @import("process_manager.zig");
}
