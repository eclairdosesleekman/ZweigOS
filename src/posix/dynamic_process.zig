// SPDX-License-Identifier: BSD-2-Clause
//! Phase 11 dynamic-process transaction coordinator.
//!
//! This module owns request idempotency and process lifecycle ordering. The
//! RuntimeOps adapter is the only place that materializes kernel objects,
//! maps Frames, configures MCS TCB state, publishes a Badge, and resumes a TCB.
//! Runtime object identifiers are opaque generation-checked handles; no CPtr
//! is accepted or returned by this API.

const std = @import("std");
const process_manager = @import("process_manager.zig");
const process_lifecycle = @import("process_lifecycle.zig");
const process_resources = @import("process_resources.zig");
const object_authority = @import("../core/object_authority.zig");
const process_registry = @import("../core/process.zig");
const image_loader = @import("image_loader.zig");
const scheduling = @import("../core/scheduling.zig");

pub const max_processes = process_manager.max_processes;
pub const failed_spawn_exit_code: i32 = -125;

pub const RuntimeObjectHandle = struct {
    slot: u16,
    generation: u32,
};

/// These handles describe manager-owned objects, not seL4 CPtrs. The adapter
/// resolves them inside its own Authority Ledger / CSpace.
pub const RuntimeObjects = struct {
    cspace: RuntimeObjectHandle,
    vspace: RuntimeObjectHandle,
    tcb: RuntimeObjectHandle,
    scheduling_context: RuntimeObjectHandle,
    syscall_endpoint: RuntimeObjectHandle,
    fault_endpoint: RuntimeObjectHandle,
    ipc_buffer_frame: RuntimeObjectHandle,
};

pub const Registers = struct {
    rip: u64,
    rsp: u64,
    rflags: u64 = 0x202,
};

pub const SpawnRequest = struct {
    request_id: u32,
    arguments: image_loader.Arguments = .{},
    profile: scheduling.Profile,
    stack_size: u64 = 2 * 1024 * 1024,
    max_frame_pages: u32 = process_resources.default_max_frame_pages,
};

pub const RuntimeOps = struct {
    context: ?*anyopaque = null,

    /// Must be all-or-nothing: on error, no kernel object or cap may remain.
    materialize: *const fn (
        ?*anyopaque,
        process_manager.ProcessInfo,
        process_resources.Plan,
        object_authority.ReservationSet,
    ) anyerror!RuntimeObjects,

    /// Maps a staged PT_LOAD / stack Frame into this process's VSpace.
    /// The backing bytes are immutable for the duration of the callback.
    map_frame: *const fn (
        ?*anyopaque,
        RuntimeObjects,
        image_loader.Mapping,
        []const u8,
    ) anyerror!void,

    /// Maps a private, zero-filled one-page IPC buffer into the process.
    map_ipc_buffer: *const fn (?*anyopaque, RuntimeObjects, u64) anyerror!void,

    /// Installs CSpace/VSpace, IPC buffer, fault endpoint, MCS SC and registers.
    configure: *const fn (
        ?*anyopaque,
        RuntimeObjects,
        Registers,
        u64,
        scheduling.Profile,
    ) anyerror!void,

    /// Publish a process-specific Endpoint Badge before the TCB is resumed.
    /// Badge zero is reserved and is rejected.
    publish_badge: *const fn (
        ?*anyopaque,
        RuntimeObjects,
        process_manager.ProcessInfo,
    ) anyerror!u64,

    resume_tcb: *const fn (?*anyopaque, RuntimeObjects) anyerror!void,
    suspend_tcb: *const fn (?*anyopaque, RuntimeObjects) anyerror!void,
    unpublish_badge: *const fn (?*anyopaque, u64) anyerror!void,
    /// Must unmap every mapped ELF, stack and IPC Frame before destroy().
    unmap_all: *const fn (?*anyopaque, RuntimeObjects) anyerror!void,
    /// Must revoke child caps and destroy TCB/SC/CNode/VSpace/Frames in order.
    destroy: *const fn (?*anyopaque, RuntimeObjects) anyerror!void,
};

pub const State = enum(u8) {
    preparing,
    running,
    exited,
    failed,
    quarantined,
};

pub const SpawnError = error{
    InvalidRequestId,
    ParentNotRunning,
    RequestIdConflict,
    ProcessTableFull,
    ProcessIdExhausted,
    RuntimeTableFull,
    InvalidImage,
    InvalidResourcePlan,
    ResourceReservationFailed,
    RuntimeMaterializationFailed,
    FrameMappingFailed,
    IpcBufferMappingFailed,
    TcbConfigurationFailed,
    BadgePublicationFailed,
    ResumeFailed,
    RollbackFailed,
};

pub const ExitError = error{
    UnknownProcess,
    InvalidState,
    SuspendFailed,
    BadgeRevocationFailed,
    LifecycleFailed,
};

pub const ReapError = error{
    UnknownProcess,
    ChildNotFound,
    ProcessNotExited,
    BadgeRevocationFailed,
    UnmapFailed,
    DestroyFailed,
    LifecycleFailed,
};

const Record = struct {
    active: bool = false,
    request_id: u32 = 0,
    request_digest: u64 = 0,
    process: process_manager.ProcessInfo = .{
        .id = .{ .slot = 0, .generation = 0 },
        .pid = 0,
    },
    parent: process_registry.Id = .{ .slot = 0, .generation = 0 },
    state: State = .preparing,
    objects: RuntimeObjects = undefined,
    materialized: bool = false,
    badge: u64 = 0,
    badge_published: bool = false,
    unmapped: bool = false,
    destroyed: bool = false,
};

pub const Manager = struct {
    lifecycle: process_lifecycle.Manager = .{},
    records: [max_processes]Record = @splat(.{}),
    next_domain_id: u32 = 0x8000,

    /// Spawn a static ET_EXEC image. Repeated outstanding request IDs return
    /// the existing ProcessInfo only when parent and input digest match.
    pub fn spawn(
        self: *Manager,
        processes: *process_manager.Table,
        authority: *object_authority.Table,
        ops: RuntimeOps,
        parent: process_registry.Id,
        request: SpawnRequest,
        image: []const u8,
        staging: []align(image_loader.page_size) u8,
    ) SpawnError!process_manager.ProcessInfo {
        if (request.request_id == 0) return error.InvalidRequestId;
        const parent_state = processes.state(parent) orelse return error.ParentNotRunning;
        if (parent_state != .running) return error.ParentNotRunning;

        const digest = requestDigest(parent, request, image);
        if (self.findRequest(request.request_id)) |existing| {
            if (!sameProcess(existing.parent, parent) or existing.request_digest != digest) {
                return error.RequestIdConflict;
            }
            return existing.process;
        }

        const free_record = self.freeRecord() orelse return error.RuntimeTableFull;
        if (self.next_domain_id > @as(u32, std.math.maxInt(u16))) return error.ProcessIdExhausted;

        const loaded = image_loader.load(image, staging, .{
            .stack_size = request.stack_size,
            .arguments = request.arguments,
        }) catch return error.InvalidImage;

        // Owner is patched to the real generation-checked process handle after
        // ProcessManager allocates the child record.
        var plan = process_resources.build(
            .{ .slot = 0, .generation = 1 },
            loaded,
            request.profile,
            request.max_frame_pages,
        ) catch return error.InvalidResourcePlan;

        const domain_id: u16 = @intCast(self.next_domain_id);
        self.next_domain_id += 1;
        const child = processes.spawn(parent, domain_id) catch return error.ProcessTableFull;
        plan.owner = child.id;

        self.lifecycle.prepare(
            processes,
            authority,
            child,
            plan,
        ) catch {
            _ = processes.fail(child.id, failed_spawn_exit_code) catch {};
            _ = processes.wait(parent, child.pid) catch {};
            return error.ResourceReservationFailed;
        };
        const record = free_record;
        record.* = .{
            .active = true,
            .request_id = request.request_id,
            .request_digest = digest,
            .process = child,
            .parent = parent,
            .state = .preparing,
        };

        const reservations = self.lifecycle.reservations(child.id) orelse {
            return self.rollbackPrepared(
                processes,
                authority,
                ops,
                record,
                error.RuntimeMaterializationFailed,
            );
        };
        const objects = ops.materialize(ops.context, child, plan, reservations) catch {
            return self.rollbackPrepared(
                processes,
                authority,
                ops,
                record,
                error.RuntimeMaterializationFailed,
            );
        };
        record.objects = objects;
        record.materialized = true;

        for (loaded.mappings[0..loaded.mapping_count]) |mapping| {
            const end = @addWithOverflow(mapping.backing_offset, @as(usize, @intCast(mapping.byte_length)));
            if (end[1] != 0 or end[0] > staging.len) {
                return self.rollbackPrepared(processes, authority, ops, record, error.FrameMappingFailed);
            }
            ops.map_frame(
                ops.context,
                objects,
                mapping,
                staging[mapping.backing_offset..end[0]],
            ) catch {
                return self.rollbackPrepared(processes, authority, ops, record, error.FrameMappingFailed);
            };
        }

        ops.map_ipc_buffer(ops.context, objects, plan.ipc_buffer_address) catch {
            return self.rollbackPrepared(processes, authority, ops, record, error.IpcBufferMappingFailed);
        };

        ops.configure(
            ops.context,
            objects,
            .{ .rip = loaded.entry, .rsp = loaded.stack_pointer },
            plan.ipc_buffer_address,
            request.profile,
        ) catch {
            return self.rollbackPrepared(processes, authority, ops, record, error.TcbConfigurationFailed);
        };

        const badge = ops.publish_badge(ops.context, objects, child) catch {
            return self.rollbackPrepared(processes, authority, ops, record, error.BadgePublicationFailed);
        };
        if (badge == 0) {
            return self.rollbackPrepared(processes, authority, ops, record, error.BadgePublicationFailed);
        }
        record.badge = badge;
        record.badge_published = true;

        self.lifecycle.commit(processes, child.id) catch {
            return self.rollbackPrepared(processes, authority, ops, record, error.TcbConfigurationFailed);
        };
        ops.resume_tcb(ops.context, objects) catch {
            // commit made the child waitable as a running policy object; record
            // a failed launch as exited and leave object destruction to reap.
            _ = ops.suspend_tcb(ops.context, objects) catch {};
            if (record.badge_published) {
                ops.unpublish_badge(ops.context, record.badge) catch {
                    record.state = .quarantined;
                    return error.RollbackFailed;
                };
                record.badge_published = false;
            }
            self.lifecycle.exit(processes, child.id, failed_spawn_exit_code) catch {
                record.state = .quarantined;
                return error.RollbackFailed;
            };
            record.state = .exited;
            return error.ResumeFailed;
        };

        record.state = .running;
        return child;
    }

    pub fn exit(
        self: *Manager,
        processes: *process_manager.Table,
        ops: RuntimeOps,
        id: process_registry.Id,
        exit_code: i32,
    ) ExitError!void {
        const record = self.findProcess(id) orelse return error.UnknownProcess;
        if (record.state != .running) return error.InvalidState;
        ops.suspend_tcb(ops.context, record.objects) catch return error.SuspendFailed;
        if (record.badge_published) {
            ops.unpublish_badge(ops.context, record.badge) catch return error.BadgeRevocationFailed;
            record.badge_published = false;
        }
        self.lifecycle.exit(processes, id, exit_code) catch return error.LifecycleFailed;
        record.state = .exited;
    }

    /// Release process runtime mappings and objects before the policy ledger
    /// reclaims resource reservations and ProcessManager removes the child.
    pub fn reap(
        self: *Manager,
        processes: *process_manager.Table,
        authority: *object_authority.Table,
        ops: RuntimeOps,
        parent: process_registry.Id,
        child_pid: u32,
    ) ReapError!process_manager.ExitInfo {
        const child = processes.childOf(parent, child_pid) orelse return error.ChildNotFound;
        const record = self.findProcess(child.id) orelse return error.UnknownProcess;
        const process_state = processes.state(child.id) orelse return error.UnknownProcess;
        if (process_state == .starting or process_state == .running) return error.ProcessNotExited;
        if (record.state == .quarantined) return error.UnmapFailed;

        if (record.badge_published) {
            ops.unpublish_badge(ops.context, record.badge) catch return error.BadgeRevocationFailed;
            record.badge_published = false;
        }
        if (record.materialized and !record.unmapped) {
            ops.unmap_all(ops.context, record.objects) catch return error.UnmapFailed;
            record.unmapped = true;
        }
        if (record.materialized and !record.destroyed) {
            ops.destroy(ops.context, record.objects) catch return error.DestroyFailed;
            record.destroyed = true;
        }

        const exit_info = self.lifecycle.reap(processes, authority, parent, child_pid) catch {
            return error.LifecycleFailed;
        };
        record.* = .{};
        return exit_info;
    }

    pub fn state(self: *const Manager, id: process_registry.Id) ?State {
        const record = self.findProcessConst(id) orelse return null;
        return record.state;
    }

    pub fn activeCount(self: *const Manager) usize {
        var count: usize = 0;
        for (self.records) |record| {
            if (record.active) count += 1;
        }
        return count;
    }

    fn rollbackPrepared(
        self: *Manager,
        processes: *process_manager.Table,
        authority: *object_authority.Table,
        ops: RuntimeOps,
        record: *Record,
        result: SpawnError,
    ) SpawnError!process_manager.ProcessInfo {
        if (record.badge_published) {
            ops.unpublish_badge(ops.context, record.badge) catch {
                record.state = .quarantined;
                return error.RollbackFailed;
            };
            record.badge_published = false;
        }
        if (record.materialized) {
            ops.unmap_all(ops.context, record.objects) catch {
                record.state = .quarantined;
                return error.RollbackFailed;
            };
            record.unmapped = true;
            ops.destroy(ops.context, record.objects) catch {
                record.state = .quarantined;
                return error.RollbackFailed;
            };
            record.destroyed = true;
        }
        self.lifecycle.abort(processes, authority, record.process.id) catch {
            record.state = .quarantined;
            return error.RollbackFailed;
        };
        record.state = .failed;
        return result;
    }

    fn freeRecord(self: *Manager) ?*Record {
        for (&self.records) |*record| {
            if (!record.active) return record;
        }
        return null;
    }

    fn findRequest(self: *Manager, request_id: u32) ?*Record {
        for (&self.records) |*record| {
            if (record.active and record.request_id == request_id) return record;
        }
        return null;
    }

    fn findProcess(self: *Manager, id: process_registry.Id) ?*Record {
        for (&self.records) |*record| {
            if (record.active and sameProcess(record.process.id, id)) return record;
        }
        return null;
    }

    fn findProcessConst(self: *const Manager, id: process_registry.Id) ?*const Record {
        for (&self.records) |*record| {
            if (record.active and sameProcess(record.process.id, id)) return record;
        }
        return null;
    }

};

fn requestDigest(parent: process_registry.Id, request: SpawnRequest, image: []const u8) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    hashBytes(&hash, image);
    hashU64(&hash, parent.encode());
    hashU64(&hash, @as(u64, request.profile.priority));
    hashU64(&hash, request.profile.budget_us);
    hashU64(&hash, request.profile.period_us);
    hashU64(&hash, request.stack_size);
    hashU64(&hash, @as(u64, request.max_frame_pages));
    for (request.arguments.argv) |value| {
        hashU64(&hash, value.len);
        hashBytes(&hash, value);
        hashU64(&hash, 0xff);
    }
    hashU64(&hash, 0xfe);
    for (request.arguments.envp) |value| {
        hashU64(&hash, value.len);
        hashBytes(&hash, value);
        hashU64(&hash, 0xfd);
    }
    return hash;
}

fn hashBytes(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 1_099_511_628_211;
    }
}

fn hashU64(hash: *u64, value: u64) void {
    var word = value;
    for (0..8) |_| {
        hash.* ^= @as(u64, @as(u8, @truncate(word)));
        hash.* *%= 1_099_511_628_211;
        word >>= 8;
    }
}

fn sameProcess(left: process_registry.Id, right: process_registry.Id) bool {
    return left.slot == right.slot and left.generation == right.generation;
}


const Mock = struct {
    next_object: u32 = 1,
    map_calls: usize = 0,
    fail_map_call: usize = 0,
    materialize_calls: usize = 0,
    publish_calls: usize = 0,
    resume_calls: usize = 0,
    suspend_calls: usize = 0,
    unpublish_calls: usize = 0,
    unmap_calls: usize = 0,
    destroy_calls: usize = 0,
    ipc_map_calls: usize = 0,
    maps: [64]MapRecord = @splat(.{}),
    map_count: usize = 0,

    const MapRecord = struct {
        vspace: RuntimeObjectHandle = .{ .slot = 0, .generation = 0 },
        frame: RuntimeObjectHandle = .{ .slot = 0, .generation = 0 },
        virtual_address: u64 = 0,
    };

    fn runtimeOps(self: *Mock) RuntimeOps {
        return .{
            .context = self,
            .materialize = mockMaterialize,
            .map_frame = mockMapFrame,
            .map_ipc_buffer = mockMapIpcBuffer,
            .configure = mockConfigure,
            .publish_badge = mockPublishBadge,
            .resume = mockResume,
            .suspend = mockSuspend,
            .unpublish_badge = mockUnpublishBadge,
            .unmap_all = mockUnmapAll,
            .destroy = mockDestroy,
        };
    }

    fn nextHandle(self: *Mock) RuntimeObjectHandle {
        const value = self.next_object;
        self.next_object += 1;
        return .{ .slot = @truncate(value), .generation = 1 };
    }

    fn mockMaterialize(
        context: ?*anyopaque,
        process: process_manager.ProcessInfo,
        plan: process_resources.Plan,
        reservations: object_authority.ReservationSet,
    ) anyerror!RuntimeObjects {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        if (plan.owner.slot != process.id.slot or reservations.count != plan.request_count) {
            return error.InvalidPlan;
        }
        self.materialize_calls += 1;
        return .{
            .cspace = self.nextHandle(),
            .vspace = self.nextHandle(),
            .tcb = self.nextHandle(),
            .scheduling_context = self.nextHandle(),
            .syscall_endpoint = self.nextHandle(),
            .fault_endpoint = self.nextHandle(),
            .ipc_buffer_frame = self.nextHandle(),
        };
    }

    fn mockMapFrame(
        context: ?*anyopaque,
        objects: RuntimeObjects,
        mapping: image_loader.Mapping,
        bytes: []const u8,
    ) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        if (@as(u64, @intCast(bytes.len)) != mapping.byte_length or self.map_count == self.maps.len) {
            return error.InvalidBacking;
        }
        self.map_calls += 1;
        if (self.fail_map_call == self.map_calls) return error.InjectedMapFailure;
        const frame = self.nextHandle();
        self.maps[self.map_count] = .{
            .vspace = objects.vspace,
            .frame = frame,
            .virtual_address = mapping.virtual_address,
        };
        self.map_count += 1;
    }

    fn mockMapIpcBuffer(
        context: ?*anyopaque,
        objects: RuntimeObjects,
        virtual_address: u64,
    ) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        if (virtual_address % image_loader.page_size != 0) return error.UnalignedIpcBuffer;
        self.ipc_map_calls += 1;
    }

    fn mockConfigure(
        context: ?*anyopaque,
        objects: RuntimeObjects,
        registers: Registers,
        ipc_buffer_address: u64,
        profile: scheduling.Profile,
    ) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = self;
        _ = objects;
        try profile.validate();
        if (registers.rip < 0x1_0000 or registers.rsp % 16 != 0 or
            ipc_buffer_address % image_loader.page_size != 0)
        {
            return error.InvalidInitialContext;
        }
    }

    fn mockPublishBadge(
        context: ?*anyopaque,
        objects: RuntimeObjects,
        process: process_manager.ProcessInfo,
    ) anyerror!u64 {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        self.publish_calls += 1;
        return (@as(u64, process.pid) << 32) | process.id.encode();
    }

    fn mockResume(context: ?*anyopaque, objects: RuntimeObjects) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        self.resume_calls += 1;
    }

    fn mockSuspend(context: ?*anyopaque, objects: RuntimeObjects) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        self.suspend_calls += 1;
    }

    fn mockUnpublishBadge(context: ?*anyopaque, badge: u64) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        if (badge == 0) return error.InvalidBadge;
        self.unpublish_calls += 1;
    }

    fn mockUnmapAll(context: ?*anyopaque, objects: RuntimeObjects) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        self.unmap_calls += 1;
    }

    fn mockDestroy(context: ?*anyopaque, objects: RuntimeObjects) anyerror!void {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        _ = objects;
        self.destroy_calls += 1;
    }
};

fn writeTest16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeTest32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |index| {
        const shift: u5 = @intCast(index * 8);
        bytes[offset + index] = @truncate(value >> shift);
    }
}

fn writeTest64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |index| {
        const shift: u6 = @intCast(index * 8);
        bytes[offset + index] = @truncate(value >> shift);
    }
}

fn testStaticImage(code: []const u8, data: []const u8) [184]u8 {
    var image: [184]u8 = @splat(0);
    image[0] = 0x7f;
    image[1] = 'E';
    image[2] = 'L';
    image[3] = 'F';
    image[4] = 2;
    image[5] = 1;
    image[6] = 1;
    writeTest16(&image, 16, 2);
    writeTest16(&image, 18, 62);
    writeTest32(&image, 20, 1);
    writeTest64(&image, 24, 0x20_0100);
    writeTest64(&image, 32, 64);
    writeTest16(&image, 52, 64);
    writeTest16(&image, 54, 56);
    writeTest16(&image, 56, 2);

    writeTest32(&image, 64, 1);
    writeTest32(&image, 68, 5);
    writeTest64(&image, 72, 176);
    writeTest64(&image, 80, 0x20_0100);
    writeTest64(&image, 96, 4);
    writeTest64(&image, 104, 0x80);
    writeTest64(&image, 112, 1);

    writeTest32(&image, 120, 1);
    writeTest32(&image, 124, 6);
    writeTest64(&image, 128, 180);
    writeTest64(&image, 136, 0x20_2100);
    writeTest64(&image, 152, 4);
    writeTest64(&image, 160, 5000);
    writeTest64(&image, 168, 1);

    @memcpy(image[176..180], &code);
    @memcpy(image[180..184], &data);
    return image;
}

fn testProfile() scheduling.Profile {
    return .{ .priority = 90, .budget_us = 500, .period_us = 5000 };
}

test "two dynamic ELF processes have independent VSpaces and reap all kernel resources" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};
    var mock = Mock{};
    const ops = mock.runtimeOps();

    const hello = testStaticImage("HELO", "DATA");
    const counter = testStaticImage("CNTR", "VALU");
    var hello_staging: [64 * image_loader.page_size]u8 align(image_loader.page_size) = undefined;
    var counter_staging: [64 * image_loader.page_size]u8 align(image_loader.page_size) = undefined;

    const request = SpawnRequest{
        .request_id = 101,
        .arguments = .{ .argv = &.{"hello"}, .envp = &.{"MODE=test"} },
        .profile = testProfile(),
        .stack_size = 2 * image_loader.page_size,
        .max_frame_pages = 16,
    };
    const hello_process = try manager.spawn(
        &processes,
        &authority,
        ops,
        parent.id,
        request,
        &hello,
        hello_staging[0..],
    );
    const duplicate = try manager.spawn(
        &processes,
        &authority,
        ops,
        parent.id,
        request,
        &hello,
        hello_staging[0..],
    );
    try testing.expectEqual(hello_process.pid, duplicate.pid);
    try testing.expectEqual(@as(usize, 1), mock.materialize_calls);

    var counter_request = request;
    counter_request.request_id = 102;
    counter_request.arguments = .{ .argv = &.{"counter"}, .envp = &.{"MODE=count"} };
    const counter_process = try manager.spawn(
        &processes,
        &authority,
        ops,
        parent.id,
        counter_request,
        &counter,
        counter_staging[0..],
    );

    try testing.expect(hello_process.pid != counter_process.pid);
    try testing.expectEqual(process_manager.State.running, processes.state(hello_process.id).?);
    try testing.expectEqual(process_manager.State.running, processes.state(counter_process.id).?);
    try testing.expectEqual(@as(usize, 18), authority.activeObjectCount());

    const hello_record = manager.findProcess(hello_process.id).?;
    const counter_record = manager.findProcess(counter_process.id).?;
    try testing.expect(hello_record.objects.vspace.slot != counter_record.objects.vspace.slot);

    var hello_text: ?RuntimeObjectHandle = null;
    var counter_text: ?RuntimeObjectHandle = null;
    for (mock.maps[0..mock.map_count]) |mapped| {
        if (mapped.virtual_address != 0x20_0000) continue;
        if (mapped.vspace.slot == hello_record.objects.vspace.slot) hello_text = mapped.frame;
        if (mapped.vspace.slot == counter_record.objects.vspace.slot) counter_text = mapped.frame;
    }
    try testing.expect(hello_text != null and counter_text != null);
    try testing.expect(hello_text.?.slot != counter_text.?.slot);

    try manager.exit(&processes, ops, hello_process.id, 17);
    try testing.expectEqual(State.running, manager.state(counter_process.id).?);
    const hello_status = try manager.reap(&processes, &authority, ops, parent.id, hello_process.pid);
    try testing.expectEqual(@as(i32, 17), hello_status.exit_code);
    try testing.expectEqual(@as(usize, 9), authority.activeObjectCount());

    try manager.exit(&processes, ops, counter_process.id, 0);
    _ = try manager.reap(&processes, &authority, ops, parent.id, counter_process.pid);
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
    try testing.expectEqual(@as(usize, 0), authority.activeCapabilityCount());
    try testing.expectEqual(@as(usize, 0), manager.activeCount());
    try testing.expectEqual(@as(u32, 2), mock.unmap_calls);
    try testing.expectEqual(@as(u32, 2), mock.destroy_calls);
}

test "mapping failure rolls back the prepared process and leaves a waitable status" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};
    var mock = Mock{ .fail_map_call = 2 };
    const ops = mock.runtimeOps();
    const image = testStaticImage("FAIL", "ROLL");
    var staging: [64 * image_loader.page_size]u8 align(image_loader.page_size) = undefined;
    const request = SpawnRequest{
        .request_id = 202,
        .arguments = .{ .argv = &.{"failing"} },
        .profile = testProfile(),
        .stack_size = 2 * image_loader.page_size,
        .max_frame_pages = 16,
    };

    try testing.expectError(
        error.FrameMappingFailed,
        manager.spawn(&processes, &authority, ops, parent.id, request, &image, staging[0..]),
    );
    const record = manager.findRequest(request.request_id).?;
    try testing.expectEqual(State.failed, record.state);
    try testing.expectEqual(process_manager.State.failed, processes.state(record.process.id).?);
    try testing.expectEqual(@as(usize, 0), authority.activeObjectCount());
    try testing.expectEqual(@as(u32, 1), mock.unmap_calls);
    try testing.expectEqual(@as(u32, 1), mock.destroy_calls);

    const exit_info = try manager.reap(&processes, &authority, ops, parent.id, record.process.pid);
    try testing.expectEqual(failed_spawn_exit_code, exit_info.exit_code);
    try testing.expectEqual(@as(usize, 0), manager.activeCount());
}

test "request idempotency rejects reuse with a different image" {
    const testing = std.testing;
    var processes: process_manager.Table = .{};
    const parent = try processes.initialize(1);
    var authority: object_authority.Table = .{};
    var manager: Manager = .{};
    var mock = Mock{};
    const ops = mock.runtimeOps();
    const first = testStaticImage("ONE!", "DATA");
    const second = testStaticImage("TWO!", "DATA");
    var staging_a: [64 * image_loader.page_size]u8 align(image_loader.page_size) = undefined;
    var staging_b: [64 * image_loader.page_size]u8 align(image_loader.page_size) = undefined;
    const request = SpawnRequest{
        .request_id = 303,
        .profile = testProfile(),
        .stack_size = 2 * image_loader.page_size,
        .max_frame_pages = 16,
    };
    const child = try manager.spawn(&processes, &authority, ops, parent.id, request, &first, staging_a[0..]);
    try testing.expectEqual(child.pid, (try manager.spawn(
        &processes,
        &authority,
        ops,
        parent.id,
        request,
        &first,
        staging_b[0..],
    )).pid);
    try testing.expectError(
        error.RequestIdConflict,
        manager.spawn(&processes, &authority, ops, parent.id, request, &second, staging_b[0..]),
    );
}
