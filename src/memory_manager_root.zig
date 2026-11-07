// SPDX-License-Identifier: BSD-2-Clause
//! Keep the memory service inside the common src/ Zig module root so imports
//! of ../core resolve within the module boundary on Zig 0.17.

pub const _start = {};

const component = @import("memory_manager/main.zig");

comptime {
    _ = component.zweig_memory_dispatch;
    _ = component.init;
    _ = component.notified;
}
