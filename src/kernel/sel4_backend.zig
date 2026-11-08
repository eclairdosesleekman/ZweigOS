// SPDX-License-Identifier: BSD-2-Clause
//! C ABI adapter binding the policy manager to the selected Microkit SDK.
//!
//! Importing this module does not grant any authority. The caller must first
//! configure a CSpace window and register Untyped caps that were explicitly
//! transferred to this Protection Domain by trusted bootstrap code.

const manager = @import("object_manager.zig");

pub const SlotPath = struct {
    root: u64,
    index: u64,
    depth: u64,
};

extern fn zweig_sel4_object_layout(
    kind: u32,
    requested_size_bits: u8,
    object_type_out: *u64,
    retype_size_bits_out: *u8,
    allocation_size_bits_out: *u8,
) c_int;

extern fn zweig_sel4_retype(
    untyped_cptr: u64,
    object_type: u64,
    retype_size_bits: u8,
    destination_root_cnode: u64,
    destination_node_index: u64,
    destination_node_depth: u64,
    destination_slot: u64,
    count: u32,
) c_int;

extern fn zweig_sel4_cnode_copy(
    destination_root: u64,
    destination_index: u64,
    destination_depth: u64,
    source_root: u64,
    source_index: u64,
    source_depth: u64,
    rights: u8,
) c_int;

extern fn zweig_sel4_cnode_mint(
    destination_root: u64,
    destination_index: u64,
    destination_depth: u64,
    source_root: u64,
    source_index: u64,
    source_depth: u64,
    rights: u8,
    badge: u64,
) c_int;

extern fn zweig_sel4_cnode_revoke(cnode_root: u64, cptr: u64, depth: u64) c_int;
extern fn zweig_sel4_cnode_delete(cnode_root: u64, cptr: u64, depth: u64) c_int;

fn objectLayout(
    context: ?*anyopaque,
    kind: u32,
    requested_size_bits: u8,
    object_type_out: *u64,
    retype_size_bits_out: *u8,
    allocation_size_bits_out: *u8,
) callconv(.c) c_int {
    _ = context;
    return zweig_sel4_object_layout(
        kind,
        requested_size_bits,
        object_type_out,
        retype_size_bits_out,
        allocation_size_bits_out,
    );
}

fn retype(
    context: ?*anyopaque,
    untyped_cptr: u64,
    object_type: u64,
    retype_size_bits: u8,
    destination_root_cnode: u64,
    destination_node_index: u64,
    destination_node_depth: u64,
    destination_slot: u64,
    count: u32,
) callconv(.c) c_int {
    _ = context;
    return zweig_sel4_retype(
        untyped_cptr,
        object_type,
        retype_size_bits,
        destination_root_cnode,
        destination_node_index,
        destination_node_depth,
        destination_slot,
        count,
    );
}

fn revoke(
    context: ?*anyopaque,
    cnode_root: u64,
    cptr: u64,
    depth: u64,
) callconv(.c) c_int {
    _ = context;
    return zweig_sel4_cnode_revoke(cnode_root, cptr, depth);
}

fn delete(
    context: ?*anyopaque,
    cnode_root: u64,
    cptr: u64,
    depth: u64,
) callconv(.c) c_int {
    _ = context;
    return zweig_sel4_cnode_delete(cnode_root, cptr, depth);
}

pub fn kernelOps() manager.KernelOps {
    return .{
        .context = null,
        .object_layout = objectLayout,
        .retype = retype,
        .cnode_revoke = revoke,
        .cnode_delete = delete,
    };
}

/// These entry points are intentionally expressed in terms of local
/// CSpace paths. Rights attenuation must be checked by policy before calling.
pub fn rightsAreSubset(parent_rights: u8, child_rights: u8) bool {
    return (parent_rights & 0xf0) == 0 and
        (child_rights & 0xf0) == 0 and
        (child_rights & ~parent_rights) == 0;
}

pub fn copyCapability(
    destination: SlotPath,
    source: SlotPath,
    parent_rights: u8,
    rights: u8,
) c_int {
    if ((parent_rights & 0xf0) != 0 or (rights & 0xf0) != 0) return -22;
    if (!rightsAreSubset(parent_rights, rights)) return -13;
    return zweig_sel4_cnode_copy(
        destination.root,
        destination.index,
        destination.depth,
        source.root,
        source.index,
        source.depth,
        rights,
    );
}

pub fn mintCapability(
    destination: SlotPath,
    source: SlotPath,
    parent_rights: u8,
    rights: u8,
    badge: u64,
) c_int {
    if ((parent_rights & 0xf0) != 0 or (rights & 0xf0) != 0) return -22;
    if (!rightsAreSubset(parent_rights, rights)) return -13;
    return zweig_sel4_cnode_mint(
        destination.root,
        destination.index,
        destination.depth,
        source.root,
        source.index,
        source.depth,
        rights,
        badge,
    );
}

/// Revoke every capability derived from the target slot in the supplied CSpace.
pub fn revokeCapability(target: SlotPath) c_int {
    if (target.root == 0 or target.index == 0 or target.depth == 0 or target.depth > manager.cnode_word_depth) {
        return -22;
    }
    return zweig_sel4_cnode_revoke(target.root, target.index, target.depth);
}

/// Delete one capability slot. The caller must have revoked descendants first.
pub fn deleteCapability(target: SlotPath) c_int {
    if (target.root == 0 or target.index == 0 or target.depth == 0 or target.depth > manager.cnode_word_depth) {
        return -22;
    }
    return zweig_sel4_cnode_delete(target.root, target.index, target.depth);
}

test "capability backend rejects rights escalation before invoking seL4" {
    const std = @import("std");
    try std.testing.expect(rightsAreSubset(0x0f, 0x05));
    try std.testing.expect(rightsAreSubset(0x05, 0x01));
    try std.testing.expect(!rightsAreSubset(0x05, 0x07));
    try std.testing.expect(!rightsAreSubset(0xff, 0x01));
}
