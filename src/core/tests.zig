// SPDX-License-Identifier: BSD-2-Clause
//! Import all core modules so their unit tests run under the unified root.

test {
    _ = @import("protocol.zig");
    _ = @import("page_allocator.zig");
    _ = @import("capability.zig");
    _ = @import("process.zig");
    _ = @import("scheduling.zig");
    _ = @import("elf64.zig");
    _ = @import("object_authority.zig");
}
