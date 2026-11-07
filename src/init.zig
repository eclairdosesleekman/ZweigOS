// SPDX-License-Identifier: BSD-2-Clause
//! Zweig OS Phase 2 bootstrap Protection Domain.

const capability = @import("core/capability.zig");
const protocol = @import("core/protocol.zig");
const scheduling = @import("core/scheduling.zig");

extern "c" fn zweig_console_puts(message: [*:0]const u8) void;
extern "c" fn zweig_memory_call(
    channel: u32,
    operation: u64,
    argument: u64,
    value_out: *u64,
) i32;

const memory_channel: u32 = 0;

fn log(message: [*:0]const u8) void {
    zweig_console_puts(message);
}

export fn init() void {
    const client_profile = scheduling.Profile{
        .priority = 99,
        .budget_us = 1000,
        .period_us = 10000,
    };
    client_profile.validate() catch {
        log("Zweig Phase 2: invalid client scheduling profile\r\n");
        return;
    };

    var service_caps = capability.Table{};
    service_caps.install(.{
        .service = .memory,
        .channel = memory_channel,
        .rights = .{ .call = true },
    }) catch {
        log("Zweig Phase 2: failed to install memory service handle\r\n");
        return;
    };

    const memory = service_caps.lookup(.memory, .{ .call = true }) catch {
        log("Zweig Phase 2: memory service capability denied\r\n");
        return;
    };

    var lease_token: u64 = 0;
    const alloc_status = zweig_memory_call(
        memory.channel,
        @intFromEnum(protocol.Operation.allocate_pages),
        4,
        &lease_token,
    );
    if (alloc_status != 0) {
        log("Zweig Phase 2: memory allocation RPC failed\r\n");
        return;
    }

    var free_pages_after_alloc: u64 = 0;
    const stats_status = zweig_memory_call(
        memory.channel,
        @intFromEnum(protocol.Operation.get_stats),
        0,
        &free_pages_after_alloc,
    );
    if (stats_status != 0 or free_pages_after_alloc != 252) {
        log("Zweig Phase 2: memory statistics RPC failed\r\n");
        return;
    }

    var release_result: u64 = 0;
    const release_status = zweig_memory_call(
        memory.channel,
        @intFromEnum(protocol.Operation.release_pages),
        lease_token,
        &release_result,
    );
    if (release_status != 0) {
        log("Zweig Phase 2: memory release RPC failed\r\n");
        return;
    }

    var free_pages_after_release: u64 = 0;
    const final_stats_status = zweig_memory_call(
        memory.channel,
        @intFromEnum(protocol.Operation.get_stats),
        0,
        &free_pages_after_release,
    );
    if (final_stats_status != 0 or free_pages_after_release != 256) {
        log("Zweig Phase 2: memory allocator did not return to its initial state\r\n");
        return;
    }

    log("Zweig Phase 2: memory RPC PASS\r\n");
}

export fn notified(_: u32) void {}
