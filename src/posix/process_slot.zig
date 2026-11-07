// SPDX-License-Identifier: BSD-2-Clause
//! Runtime adapter for the single statically provisioned Phase 8 TCB slot.

const abi = @import("../core/process_slot_abi.zig");
const context = @import("x86_64_context.zig");

extern fn zweig_process_slot_start(entry: u64, stack_pointer: u64, rflags: u64) c_int;

fn sharedState() *abi.SharedState {
    return @ptrFromInt(abi.state_address);
}

/// Install and resume the worker's initial x86-64 context. The worker TCB,
/// stack region, and its CSpace/VSpace are statically provisioned in the SDF;
/// this call changes registers on that existing TCB rather than creating a new
/// kernel object.
pub fn run() i64 {
    const state = sharedState();
    if (@atomicLoad(u64, &state.magic, .acquire) != abi.ready_magic or state.entry == 0 or
        state.entry_page != (state.entry & ~@as(u64, 4095)))
    {
        return -11; // EAGAIN: worker has not published its entry point.
    }
    const previous_runs = @atomicLoad(u64, &state.run_count, .acquire);
    if (previous_runs >= abi.max_runs) return -11; // EAGAIN: bounded slot is exhausted.

    const code = context.Mapping{
        .virtual_address = state.entry_page,
        .byte_length = 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const stack = context.Mapping{
        .virtual_address = abi.stack_bottom,
        .byte_length = abi.stack_size,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    const initial = context.build(state.entry, abi.stack_top, code, stack) catch {
        return -22; // EINVAL: entry or stack does not fit the configured slot.
    };

    const status = zweig_process_slot_start(initial.rip, initial.rsp, initial.rflags);
    if (status != 0) return -100 - @as(i64, @intCast(status));

    // With a higher-priority static SC, the worker runs immediately, records
    // its completion, and self-suspends before the supervisor resumes here.
    const completed_runs = @atomicLoad(u64, &state.run_count, .acquire);
    const completion = @atomicLoad(u64, &state.last_result, .acquire);
    if (completed_runs != previous_runs + 1) return -101;
    if (completion != abi.result_magic) return -102;
    return @intCast(completed_runs);
}
