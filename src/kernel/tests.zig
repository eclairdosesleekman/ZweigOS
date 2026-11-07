// SPDX-License-Identifier: BSD-2-Clause
//! Unified unit-test imports for the Phase 10 kernel resource layer.

test {
    _ = @import("cspace_allocator.zig");
    _ = @import("untyped_pool.zig");
    _ = @import("object_manager.zig");
    _ = @import("sel4_backend.zig");
}
