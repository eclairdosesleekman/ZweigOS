// SPDX-License-Identifier: BSD-2-Clause
//! Microkit root for the statically provisioned Phase 8 execution slot.

pub const _start = {};

const worker = @import("process_slot/main.zig");

comptime {
    _ = worker.init;
    _ = worker.notified;
    _ = worker.zweig_process_slot_payload;
    _ = worker.zweig_process_slot_finish;
}
