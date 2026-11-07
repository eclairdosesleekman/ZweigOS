// SPDX-License-Identifier: BSD-2-Clause
//! One statically provisioned execution slot. Its TCB is controlled by the
//! POSIX supervisor through the cap_tcb capability in the Microkit SDF.

pub const _start = {};

const abi = @import("../core/process_slot_abi.zig");

extern fn zweig_console_puts(message: [*:0]const u8) void;
extern fn zweig_process_slot_park() c_int;
extern fn zweig_process_slot_entry() callconv(.c) noreturn;

fn sharedState() *abi.SharedState {
    return @ptrFromInt(abi.state_address);
}

pub export fn init() void {
    const state = sharedState();
    @atomicStore(u64, &state.magic, 0, .monotonic);
    state.entry = @intFromPtr(&zweig_process_slot_entry);
    state.entry_page = state.entry & ~@as(u64, 4095);
    state.run_count = 0;
    state.last_result = 0;
    @atomicStore(u64, &state.magic, abi.ready_magic, .release);
    zweig_console_puts("Zweig process slot: static TCB ready\r\n");
}

/// Entered by the supervisor after it rewrites this TCB's RIP/RSP/RFLAGS.
/// It records a completion, then self-suspends. On the next dispatch the
/// supervisor installs a fresh context and resumes the same static TCB.
pub export fn zweig_process_slot_payload() callconv(.c) void {
    const state = sharedState();
    state.last_result = 0;
    state.run_count +%= 1;
    @atomicStore(u64, &state.last_result, abi.result_magic, .release);
    zweig_console_puts("Zweig Phase 8: worker TCB entered and self-suspended\r\n");

    _ = zweig_process_slot_park();
    while (true) {
        asm volatile ("pause");
    }
}

pub export fn notified(_: u32) void {}
