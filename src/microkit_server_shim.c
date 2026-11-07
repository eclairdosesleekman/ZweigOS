/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Microkit declares protected() in terms of seL4_MessageInfo_t. Keep that
 * generated ABI in C and forward only fixed-width scalar values to Zig.
 */
#include <microkit.h>

#include <stdint.h>

extern uint32_t zweig_memory_dispatch(uint32_t channel,
                                      uint64_t operation,
                                      uint64_t argument,
                                      uint64_t *value_out);

microkit_msginfo protected(microkit_channel channel, microkit_msginfo message)
{
    uint64_t result = 0;
    uint32_t status = 1;

    if (microkit_msginfo_get_count(message) == 1) {
        status = zweig_memory_dispatch(
            channel,
            (uint64_t)microkit_msginfo_get_label(message),
            (uint64_t)microkit_mr_get(0),
            &result);
    }

    microkit_mr_set(0, (seL4_Word)status);
    microkit_mr_set(1, (seL4_Word)result);
    return microkit_msginfo_new(0, 2);
}
