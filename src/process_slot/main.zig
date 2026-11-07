// SPDX-License-Identifier: BSD-2-Clause
//! One statically provisioned execution slot. Its TCB is controlled by the
//! POSIX supervisor through the cap_tcb capability in the Microkit SDF.

pub const _start = {};

const abi = @import("../core/process_slot_abi.zig");

extern fn zweig_console_puts(message: [*:0]const u8) void;
extern fn zweig_process_slot_park() c_int;
extern fn zweig_process_slot_entry() callconv(.c) noreturn;
extern fn zweig_process_slot_image_entry() callconv(.c) noreturn;

fn sharedState() *abi.SharedState {
    return @ptrFromInt(abi.state_address);
}

pub export fn init() void {
    const state = sharedState();
    @atomicStore(u64, &state.magic, 0, .monotonic);
    state.entry = @intFromPtr(&zweig_process_slot_entry);
    state.entry_page = state.entry & ~@as(u64, 4095);
    state.image_entry = @intFromPtr(&zweig_process_slot_image_entry);
    state.image_entry_page = state.image_entry & ~@as(u64, 4095);
    state.image_length = 0;
    state.run_count = 0;
    state.last_result = 0;
    state.completion = 0;
    @atomicStore(u64, &state.magic, abi.ready_magic, .release);
    zweig_console_puts("Zweig process slot: static TCB ready\r\n");
}

fn completeAndPark(result: u64) noreturn {
    const state = sharedState();
    @atomicStore(u64, &state.last_result, result, .release);
    _ = @atomicRmw(u64, &state.run_count, .Add, 1, .acq_rel);
    @atomicStore(u64, &state.completion, abi.completion_magic, .release);
    _ = zweig_process_slot_park();
    while (true) {
        asm volatile ("pause");
    }
}

/// Phase 8's built-in payload remains available through RUN_SLOT.
pub export fn zweig_process_slot_payload() callconv(.c) void {
    completeAndPark(abi.result_magic);
}

/// Phase 9's trusted shim forwards a staged image's RAX value here.
pub export fn zweig_process_slot_finish(result: u64) callconv(.c) noreturn {
    completeAndPark(result);
}

pub export fn notified(_: u32) void {}
