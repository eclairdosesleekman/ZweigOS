// SPDX-License-Identifier: BSD-2-Clause
//! Converts a Phase 5 staged image into a bounded kernel-object reservation plan.
//!
//! The plan is metadata for a future seL4 object service. Reserving it in the
//! authority ledger does not create kernel objects or install VSpace mappings.

const process = @import("../core/process.zig");
const object_authority = @import("../core/object_authority.zig");
const scheduling = @import("../core/scheduling.zig");
const image_loader = @import("image_loader.zig");
const address_space = @import("address_space.zig");

pub const page_size: u64 = image_loader.page_size;
pub const max_requests: usize = image_loader.max_mappings + 7;
pub const default_max_frame_pages: u32 = 256;

const user_min_address: u64 = 0x1_0000;
const user_address_end: u64 = 0x0000_8000_0000_0000;

pub const Error = error{
    InvalidOwner,
    InvalidSchedulingProfile,
    InvalidImage,
    InvalidMapping,
    WritableExecutableMapping,
    OverlappingMappings,
    EntryNotExecutable,
    StackNotWritable,
    FrameQuotaExceeded,
    TooManyResources,
};

pub const Plan = struct {
    pub const syscall_endpoint_request_index: usize = 4;
    pub const fault_endpoint_request_index: usize = 5;
    pub const ipc_buffer_request_index: usize = 6;
    owner: process.Id,
    entry: u64,
    stack_pointer: u64,
    scheduling_profile: scheduling.Profile,
    requests: [max_requests]object_authority.Request = undefined,
    request_count: usize = 0,
    total_frame_pages: u32 = 0,
    ipc_buffer_address: u64 = 0,

    /// Reserve every resource description and root capability as one atomic
    /// batch. On failure, the authority table is unchanged.
    pub fn reserve(
        self: *const Plan,
        authority: *object_authority.Table,
    ) object_authority.ReserveError!object_authority.ReservationSet {
        return authority.reserveBatch(self.owner, self.requests[0..self.request_count]);
    }
};

/// Build the resource requirements for one staged user image.
/// The request set contains VSpace, CNode, TCB, Scheduling Context, a
/// process syscall Endpoint, a Fault Endpoint, an IPC-buffer Frame, and one
/// Frame-region reservation for each ELF/stack mapping.
pub fn build(
    owner: process.Id,
    loaded: image_loader.LoadedImage,
    profile: scheduling.Profile,
    max_frame_pages: u32,
) Error!Plan {
    if (@as(usize, owner.slot) >= process.max_processes or owner.generation == 0) {
        return error.InvalidOwner;
    }
    profile.validate() catch return error.InvalidSchedulingProfile;
    if (loaded.mapping_count == 0 or loaded.mapping_count > image_loader.max_mappings or
        loaded.stack_pointer % 16 != 0 or max_frame_pages == 0)
    {
        return error.InvalidImage;
    }

    const address_mappings = toAddressSpaceMappings(loaded);
    const layout = address_space.validateInitialMappings(
        address_mappings[0..loaded.mapping_count],
        loaded.stack_pointer,
        loaded.stack_top,
        loaded.stack_top - loaded.stack_bottom,
    ) catch return error.InvalidMapping;

    var plan = Plan{
        .owner = owner,
        .entry = loaded.entry,
        .stack_pointer = loaded.stack_pointer,
        .scheduling_profile = profile,
        .ipc_buffer_address = layout.ipc_buffer.base,
    };

    try append(&plan, .{
        .spec = .{ .kind = .vspace },
        .rights = .{ .map = true, .manage = true, .grant = true },
    });
    try append(&plan, .{
        .spec = .{ .kind = .cnode },
        .rights = .{ .manage = true, .grant = true },
    });
    try append(&plan, .{
        .spec = .{ .kind = .tcb },
        .rights = .{ .manage = true },
    });
    try append(&plan, .{
        .spec = .{ .kind = .scheduling_context },
        .rights = .{ .manage = true },
    });
    // The syscall endpoint is invoked with MCS Call/Reply semantics.
    try append(&plan, .{
        .spec = .{ .kind = .endpoint },
        .rights = .{ .invoke = true, .grant = true },
    });
    // TCB fault delivery requires a writable fault endpoint with Grant or
    // GrantReply authority in the configuring service's CSpace.
    try append(&plan, .{
        .spec = .{ .kind = .endpoint },
        .rights = .{ .invoke = true, .grant = true },
    });
    try append(&plan, .{
        .spec = .{
            .kind = .frame_region,
            .units = 1,
            .mapping = .{
                .virtual_address = layout.ipc_buffer.base,
                .byte_length = page_size,
                .backing_offset = 0,
                .readable = true,
                .writable = true,
                .executable = false,
            },
        },
        .rights = .{ .read = true, .write = true, .map = true },
    });

    var total_pages: u64 = 1;
    var entry_is_executable = false;
    var stack_is_writable = false;

    for (loaded.mappings[0..loaded.mapping_count], 0..) |mapping, index| {
        if (mapping.byte_length == 0 or mapping.byte_length % page_size != 0 or
            mapping.virtual_address % page_size != 0 or
            @as(u64, @intCast(mapping.backing_offset)) % page_size != 0)
        {
            return error.InvalidMapping;
        }
        if (mapping.writable and mapping.executable) return error.WritableExecutableMapping;
        if (!(mapping.readable or mapping.writable or mapping.executable)) {
            return error.InvalidMapping;
        }

        const end_result = @addWithOverflow(mapping.virtual_address, mapping.byte_length);
        if (end_result[1] != 0) return error.InvalidMapping;
        const mapping_end = end_result[0];
        if (mapping.virtual_address < user_min_address or mapping_end > user_address_end) {
            return error.InvalidMapping;
        }

        for (loaded.mappings[0..index]) |previous| {
            const previous_end_result = @addWithOverflow(previous.virtual_address, previous.byte_length);
            if (previous_end_result[1] != 0) return error.InvalidMapping;
            if (mapping.virtual_address < previous_end_result[0] and
                previous.virtual_address < mapping_end)
            {
                return error.OverlappingMappings;
            }
        }

        const pages = mapping.byte_length / page_size;
        if (pages > @as(u64, max_frame_pages) - total_pages) {
            return error.FrameQuotaExceeded;
        }
        total_pages += pages;

        if (mapping.executable and loaded.entry >= mapping.virtual_address and
            loaded.entry < mapping_end)
        {
            entry_is_executable = true;
        }
        if (mapping.writable and !mapping.executable and
            loaded.stack_pointer >= mapping.virtual_address and
            loaded.stack_pointer < mapping_end)
        {
            stack_is_writable = true;
        }

        const frame_mapping = object_authority.FrameMapping{
            .virtual_address = mapping.virtual_address,
            .byte_length = mapping.byte_length,
            .backing_offset = @intCast(mapping.backing_offset),
            .readable = mapping.readable,
            .writable = mapping.writable,
            .executable = mapping.executable,
        };
        try append(&plan, .{
            .spec = .{
                .kind = .frame_region,
                .units = @intCast(pages),
                .mapping = frame_mapping,
            },
            .rights = .{
                .read = mapping.readable,
                .write = mapping.writable,
                .execute = mapping.executable,
                .map = true,
                .grant = true,
            },
        });
    }

    if (!entry_is_executable) return error.EntryNotExecutable;
    if (!stack_is_writable) return error.StackNotWritable;
    plan.total_frame_pages = @intCast(total_pages);
    return plan;
}

fn toAddressSpaceMappings(loaded: image_loader.LoadedImage) [image_loader.max_mappings]address_space.Mapping {
    var mappings: [image_loader.max_mappings]address_space.Mapping = @splat(.{
        .virtual_address = 0,
        .byte_length = 0,
        .readable = false,
        .writable = false,
        .executable = false,
    });
    for (loaded.mappings[0..loaded.mapping_count], 0..) |mapping, index| {
        mappings[index] = .{
            .virtual_address = mapping.virtual_address,
            .byte_length = mapping.byte_length,
            .readable = mapping.readable,
            .writable = mapping.writable,
            .executable = mapping.executable,
        };
    }
    return mappings;
}

fn append(plan: *Plan, request: object_authority.Request) Error!void {
    if (plan.request_count == max_requests) return error.TooManyResources;
    plan.requests[plan.request_count] = request;
    plan.request_count += 1;
}

fn testOwner() process.Id {
    return .{ .slot = 0, .generation = 1 };
}

fn testImage() image_loader.LoadedImage {
    var loaded = image_loader.LoadedImage{
        .entry = 0x20_0100,
        .stack_pointer = 0x70_1ff0,
        .stack_bottom = 0x70_0000,
        .stack_top = 0x70_2000,
        .stack_guard_bottom = 0x6f_f000,
        .program_header_address = 0x70_1c00,
        .program_header_entry_size = 56,
        .program_header_count = 2,
        .mappings = @splat(.{}),
        .mapping_count = 2,
        .argument_count = 1,
        .environment_count = 0,
        .arena_used_bytes = 4 * @as(usize, image_loader.page_size),
    };
    loaded.mappings[0] = .{
        .virtual_address = 0x20_0000,
        .byte_length = 2 * page_size,
        .backing_offset = 0,
        .readable = true,
        .writable = false,
        .executable = true,
    };
    loaded.mappings[1] = .{
        .virtual_address = 0x70_0000,
        .byte_length = 2 * page_size,
        .backing_offset = 2 * image_loader.page_size,
        .readable = true,
        .writable = true,
        .executable = false,
    };
    return loaded;
}

test "ELF mappings become a bounded resource batch with frame permissions" {
    const std = @import("std");
    const loaded = testImage();
    const profile = scheduling.Profile{
        .priority = 90,
        .budget_us = 500,
        .period_us = 5000,
    };
    const plan = try build(testOwner(), loaded, profile, 8);

    try std.testing.expectEqual(@as(usize, 9), plan.request_count);
    try std.testing.expectEqual(@as(u32, 5), plan.total_frame_pages);
    try std.testing.expectEqual(object_authority.Kind.vspace, plan.requests[0].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.cnode, plan.requests[1].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.tcb, plan.requests[2].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.scheduling_context, plan.requests[3].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.endpoint, plan.requests[4].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.endpoint, plan.requests[5].spec.kind);
    try std.testing.expectEqual(object_authority.Kind.frame_region, plan.requests[6].spec.kind);
    try std.testing.expect(plan.requests[6].rights.write);
    try std.testing.expect(!plan.requests[6].rights.execute);
    try std.testing.expectEqual(object_authority.Kind.frame_region, plan.requests[7].spec.kind);
    try std.testing.expect(plan.requests[7].rights.execute);
    try std.testing.expect(!plan.requests[7].rights.write);
    try std.testing.expectEqual(object_authority.Kind.frame_region, plan.requests[8].spec.kind);
    try std.testing.expect(plan.requests[8].rights.write);
    try std.testing.expect(!plan.requests[8].rights.execute);
    try std.testing.expectEqual(
        address_space.default_stack_top - address_space.default_stack_size - 3 * page_size,
        plan.ipc_buffer_address,
    );

    var authority = object_authority.Table{};
    const reservations = try plan.reserve(&authority);
    try std.testing.expectEqual(plan.request_count, reservations.count);
    try std.testing.expectEqual(plan.request_count, authority.activeObjectCount());
    try std.testing.expectEqual(plan.request_count, authority.activeCapabilityCount());
}

test "resource planner rejects invalid entry, stack, W plus X, overlap, and quotas" {
    const std = @import("std");
    const profile = scheduling.Profile{
        .priority = 90,
        .budget_us = 500,
        .period_us = 5000,
    };

    var image = testImage();
    image.mappings[0].executable = false;
    try std.testing.expectError(error.EntryNotExecutable, build(testOwner(), image, profile, 8));

    image = testImage();
    image.stack_pointer = 0x20_0100;
    try std.testing.expectError(error.StackNotWritable, build(testOwner(), image, profile, 8));

    image = testImage();
    image.mappings[0].writable = true;
    try std.testing.expectError(error.WritableExecutableMapping, build(testOwner(), image, profile, 8));

    image = testImage();
    image.mappings[1].virtual_address = 0x20_1000;
    try std.testing.expectError(error.OverlappingMappings, build(testOwner(), image, profile, 8));

    image = testImage();
    try std.testing.expectError(error.FrameQuotaExceeded, build(testOwner(), image, profile, 3));
}
