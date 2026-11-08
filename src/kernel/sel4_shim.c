/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Thin x86-64 seL4 ABI adapter. This file deliberately contains no allocation
 * policy; the Zig ObjectManager owns validation, quotas, and rollback.
 */
#include <sel4/sel4.h>

#include <stdint.h>

#include <zweig/kernel.h>

_Static_assert(sizeof(seL4_Word) == sizeof(uint64_t),
               "Zweig Phase 10 backend requires a 64-bit seL4_Word");
_Static_assert(sizeof(seL4_CPtr) == sizeof(uint64_t),
               "Zweig Phase 10 backend requires a 64-bit seL4_CPtr");

enum {
    ZWEIG_EINVAL = -22,
    ZWEIG_ENOTSUP = -95
};

static int zweig_decode_rights(uint8_t raw, seL4_CapRights_t *rights_out)
{
    if (rights_out == 0 || (raw & (uint8_t)~0x0fu) != 0) {
        return ZWEIG_EINVAL;
    }

    *rights_out = seL4_CapRights_new(
        (raw & ZWEIG_CAP_GRANT_REPLY) != 0,
        (raw & ZWEIG_CAP_GRANT) != 0,
        (raw & ZWEIG_CAP_READ) != 0,
        (raw & ZWEIG_CAP_WRITE) != 0);
    return 0;
}

int zweig_sel4_object_layout(uint32_t kind,
                             uint8_t requested_size_bits,
                             uint64_t *object_type_out,
                             uint8_t *retype_size_bits_out,
                             uint8_t *allocation_size_bits_out)
{
    if (object_type_out == 0 || retype_size_bits_out == 0 ||
        allocation_size_bits_out == 0) {
        return ZWEIG_EINVAL;
    }

    *object_type_out = 0;
    *retype_size_bits_out = 0;
    *allocation_size_bits_out = 0;

    switch (kind) {
    case ZWEIG_KERNEL_FRAME_4K:
        *object_type_out = (uint64_t)seL4_X86_4K;
        *allocation_size_bits_out = (uint8_t)seL4_PageBits;
        return 0;

    case ZWEIG_KERNEL_ENDPOINT:
        *object_type_out = (uint64_t)seL4_EndpointObject;
        *allocation_size_bits_out = (uint8_t)seL4_EndpointBits;
        return 0;

    case ZWEIG_KERNEL_NOTIFICATION:
        *object_type_out = (uint64_t)seL4_NotificationObject;
        *allocation_size_bits_out = (uint8_t)seL4_NotificationBits;
        return 0;

    case ZWEIG_KERNEL_TCB:
        *object_type_out = (uint64_t)seL4_TCBObject;
        *allocation_size_bits_out = (uint8_t)seL4_TCBBits;
        return 0;

    case ZWEIG_KERNEL_CNODE:
        /*
         * A CNode with radix r contains 2^r slots. Its allocation includes
         * one seL4_CSlot per slot, so bytes = 2^r * 2^seL4_SlotBits.
         */
        if (requested_size_bits == 0 ||
            (seL4_Word)requested_size_bits >=
                (seL4_Word)(seL4_WordBits - seL4_SlotBits)) {
            return ZWEIG_EINVAL;
        }
        *object_type_out = (uint64_t)seL4_CapTableObject;
        *retype_size_bits_out = requested_size_bits;
        *allocation_size_bits_out =
            (uint8_t)((seL4_Word)requested_size_bits + seL4_SlotBits);
        return 0;

    default:
        /* SC, Reply, ASID pool and paging objects need config-specific work. */
        return ZWEIG_ENOTSUP;
    }
}

int zweig_sel4_retype(uint64_t untyped_cptr,
                      uint64_t object_type,
                      uint8_t retype_size_bits,
                      uint64_t destination_root_cnode,
                      uint64_t destination_node_index,
                      uint64_t destination_node_depth,
                      uint64_t destination_slot,
                      uint32_t count)
{
    if (untyped_cptr == (uint64_t)seL4_CapNull ||
        destination_root_cnode == (uint64_t)seL4_CapNull ||
        count == 0 || destination_node_depth > seL4_WordBits) {
        return ZWEIG_EINVAL;
    }

    return seL4_Untyped_Retype(
        (seL4_Untyped)untyped_cptr,
        (seL4_Word)object_type,
        (seL4_Word)retype_size_bits,
        (seL4_CNode)destination_root_cnode,
        (seL4_Word)destination_node_index,
        (seL4_Word)destination_node_depth,
        (seL4_Word)destination_slot,
        (seL4_Word)count);
}

int zweig_sel4_cnode_copy(uint64_t destination_root,
                          uint64_t destination_index,
                          uint64_t destination_depth,
                          uint64_t source_root,
                          uint64_t source_index,
                          uint64_t source_depth,
                          uint8_t rights)
{
    seL4_CapRights_t cap_rights;
    if (destination_root == (uint64_t)seL4_CapNull ||
        source_root == (uint64_t)seL4_CapNull ||
        destination_depth == 0 || destination_depth > seL4_WordBits ||
        source_depth == 0 || source_depth > seL4_WordBits ||
        zweig_decode_rights(rights, &cap_rights) != 0) {
        return ZWEIG_EINVAL;
    }

    return seL4_CNode_Copy(
        (seL4_CNode)destination_root,
        (seL4_Word)destination_index,
        (seL4_Uint8)destination_depth,
        (seL4_CNode)source_root,
        (seL4_Word)source_index,
        (seL4_Uint8)source_depth,
        cap_rights);
}

int zweig_sel4_cnode_mint(uint64_t destination_root,
                          uint64_t destination_index,
                          uint64_t destination_depth,
                          uint64_t source_root,
                          uint64_t source_index,
                          uint64_t source_depth,
                          uint8_t rights,
                          uint64_t badge)
{
    seL4_CapRights_t cap_rights;
    if (destination_root == (uint64_t)seL4_CapNull ||
        source_root == (uint64_t)seL4_CapNull ||
        destination_depth == 0 || destination_depth > seL4_WordBits ||
        source_depth == 0 || source_depth > seL4_WordBits ||
        zweig_decode_rights(rights, &cap_rights) != 0) {
        return ZWEIG_EINVAL;
    }

    return seL4_CNode_Mint(
        (seL4_CNode)destination_root,
        (seL4_Word)destination_index,
        (seL4_Uint8)destination_depth,
        (seL4_CNode)source_root,
        (seL4_Word)source_index,
        (seL4_Uint8)source_depth,
        cap_rights,
        (seL4_Word)badge);
}

int zweig_sel4_cnode_revoke(uint64_t cnode_root,
                            uint64_t cptr,
                            uint64_t depth)
{
    if (cnode_root == (uint64_t)seL4_CapNull ||
        cptr == (uint64_t)seL4_CapNull ||
        depth == 0 || depth > seL4_WordBits) {
        return ZWEIG_EINVAL;
    }
    return seL4_CNode_Revoke(
        (seL4_CNode)cnode_root,
        (seL4_Word)cptr,
        (seL4_Uint8)depth);
}

int zweig_sel4_cnode_delete(uint64_t cnode_root,
                            uint64_t cptr,
                            uint64_t depth)
{
    if (cnode_root == (uint64_t)seL4_CapNull ||
        cptr == (uint64_t)seL4_CapNull ||
        depth == 0 || depth > seL4_WordBits) {
        return ZWEIG_EINVAL;
    }
    return seL4_CNode_Delete(
        (seL4_CNode)cnode_root,
        (seL4_Word)cptr,
        (seL4_Uint8)depth);
}
