// SPDX-License-Identifier: BSD-2-Clause
//! Runtime adapter for the statically provisioned Phase 8/9 TCB execution slot.

const abi = @import("../core/process_slot_abi.zig");
const context = @import("x86_64_context.zig");
const image_slot = @import("process_slot_image.zig");

extern fn zweig_process_slot_start(entry: u64, stack_pointer: u64, rflags: u64) c_int;

fn sharedState() *abi.SharedState {
    return @ptrFromInt(abi.state_address);
}

fn stackMapping() context.Mapping {
    return .{
        .virtual_address = abi.stack_bottom,
        .byte_length = abi.stack_size,
        .readable = true,
        .writable = true,
        .executable = false,
    };
}

/// Phase 8 built-in-payload path. The worker TCB, stack region, and its
/// CSpace/VSpace are statically provisioned in the SDF; this call changes
/// registers on that existing TCB rather than creating a new kernel object.
pub fn run() i64 {
    const state = sharedState();
    if (@atomicLoad(u64, &state.magic, .acquire) != abi.ready_magic or state.entry == 0 or
        state.entry_page != (state.entry & ~@as(u64, 4095)))
    {
        return -11; // EAGAIN: worker has not published its entry point.
    }
    const previous_runs = @atomicLoad(u64, &state.run_count, .acquire);
    if (previous_runs >= abi.max_runs) return -11;

    const code = context.Mapping{
        .virtual_address = state.entry_page,
        .byte_length = 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const initial = context.build(state.entry, abi.stack_top, code, stackMapping()) catch {
        return -22;
    };

    @atomicStore(u64, &state.last_result, 0, .release);
    @atomicStore(u64, &state.completion, 0, .release);
    const status = zweig_process_slot_start(initial.rip, initial.rsp, initial.rflags);
    if (status != 0) return -100 - @as(i64, @intCast(status));

    const completed_runs = @atomicLoad(u64, &state.run_count, .acquire);
    const completion = @atomicLoad(u64, &state.completion, .acquire);
    const result = @atomicLoad(u64, &state.last_result, .acquire);
    if (completed_runs != previous_runs + 1) return -101;
    if (completion != abi.completion_magic or result != abi.result_magic) return -102;
    return @intCast(completed_runs);
}

/// Stage a flat x86-64 leaf function in the supervisor's RW alias. The worker
/// sees the same physical page only through its RX mapping. A trusted worker
/// shim calls the image and forwards RAX to the completion routine.
pub fn runImage(image_bytes: []const u8) i64 {
    image_slot.validateLength(image_bytes.len) catch return -22;

    const state = sharedState();
    if (@atomicLoad(u64, &state.magic, .acquire) != abi.ready_magic or
        state.image_entry == 0 or
        state.image_entry_page != (state.image_entry & ~@as(u64, 4095)))
    {
        return -11;
    }
    const previous_runs = @atomicLoad(u64, &state.run_count, .acquire);
    if (previous_runs >= abi.max_runs) return -11;

    const image_mapping = context.Mapping{
        .virtual_address = image_slot.base_address,
        .byte_length = image_slot.page_size,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    context.validateExecutableEntry(image_slot.base_address, image_mapping) catch return -22;

    const shim_mapping = context.Mapping{
        .virtual_address = state.image_entry_page,
        .byte_length = 4096,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    const initial = context.build(
        state.image_entry,
        abi.stack_top,
        shim_mapping,
        stackMapping(),
    ) catch return -22;

    // This PD's SDF mapping is RW; the worker's mapping of this region is RX.
    const destination: [*]u8 = @ptrFromInt(image_slot.base_address);
    @memcpy(destination[0..image_bytes.len], image_bytes);
    @memset(destination[image_bytes.len..image_slot.max_image_size], 0);
    @atomicStore(u64, &state.image_length, @intCast(image_bytes.len), .release);
    @atomicStore(u64, &state.last_result, 0, .release);
    @atomicStore(u64, &state.completion, 0, .release);

    const status = zweig_process_slot_start(initial.rip, initial.rsp, initial.rflags);
    if (status != 0) return -100 - @as(i64, @intCast(status));

    const completed_runs = @atomicLoad(u64, &state.run_count, .acquire);
    const completion = @atomicLoad(u64, &state.completion, .acquire);
    const result = @atomicLoad(u64, &state.last_result, .acquire);
    if (completed_runs != previous_runs + 1) return -101;
    if (completion != abi.completion_magic) return -102;
    return @bitCast(result);
}
