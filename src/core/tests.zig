// SPDX-License-Identifier: BSD-2-Clause
//! Import all Phase 2 core modules so their unit tests run under `zig test`.

test {
    _ = @import("protocol.zig");
    _ = @import("page_allocator.zig");
    _ = @import("capability.zig");
    _ = @import("process.zig");
    _ = @import("scheduling.zig");
    _ = @import("elf64.zig");
}
