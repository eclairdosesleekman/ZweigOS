/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Internal C ABI for the Phase 10 seL4 object backend.
 * CPtr values are CSpace-local and must never cross the userspace IPC ABI.
 */
#ifndef ZWEIG_KERNEL_H
#define ZWEIG_KERNEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum zweig_kernel_object_kind {
    ZWEIG_KERNEL_FRAME_4K = 1,
    ZWEIG_KERNEL_ENDPOINT = 2,
    ZWEIG_KERNEL_NOTIFICATION = 3,
    ZWEIG_KERNEL_TCB = 4,
    ZWEIG_KERNEL_CNODE = 5
};

enum zweig_cap_right_bits {
    ZWEIG_CAP_GRANT_REPLY = 1u << 0,
    ZWEIG_CAP_GRANT = 1u << 1,
    ZWEIG_CAP_READ = 1u << 2,
    ZWEIG_CAP_WRITE = 1u << 3
};

/*
 * Resolve the selected SDK's object type and allocation size. For a CNode,
 * requested_size_bits is its radix; retype_size_bits_out receives the radix
 * and allocation_size_bits_out includes the CSpace slot metadata size.
 */
int zweig_sel4_object_layout(uint32_t kind,
                             uint8_t requested_size_bits,
                             uint64_t *object_type_out,
                             uint8_t *retype_size_bits_out,
                             uint8_t *allocation_size_bits_out);

/* Thin wrappers around the corresponding libsel4 invocations. */
int zweig_sel4_retype(uint64_t untyped_cptr,
                      uint64_t object_type,
                      uint8_t retype_size_bits,
                      uint64_t destination_root_cnode,
                      uint64_t destination_node_index,
                      uint64_t destination_node_depth,
                      uint64_t destination_slot,
                      uint32_t count);

int zweig_sel4_cnode_copy(uint64_t destination_root,
                          uint64_t destination_index,
                          uint64_t destination_depth,
                          uint64_t source_root,
                          uint64_t source_index,
                          uint64_t source_depth,
                          uint8_t rights);

int zweig_sel4_cnode_mint(uint64_t destination_root,
                          uint64_t destination_index,
                          uint64_t destination_depth,
                          uint64_t source_root,
                          uint64_t source_index,
                          uint64_t source_depth,
                          uint8_t rights,
                          uint64_t badge);

int zweig_sel4_cnode_revoke(uint64_t cnode_root,
                            uint64_t cptr,
                            uint64_t depth);

int zweig_sel4_cnode_delete(uint64_t cnode_root,
                            uint64_t cptr,
                            uint64_t depth);

#ifdef __cplusplus
}
#endif

#endif
