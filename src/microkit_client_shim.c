/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Thin C bridge for Microkit's static-inline API. The policy and service
 * protocol live in Zig; this file only adapts MessageInfo and message
 * registers to a stable C ABI.
 */
#include <microkit.h>

#include <stdint.h>

void zweig_console_puts(const char *message)
{
    microkit_dbg_puts(message);
}

int32_t zweig_memory_call(uint32_t channel,
                          uint64_t operation,
                          uint64_t argument,
                          uint64_t *value_out)
{
    if (value_out == 0) {
        return -1;
    }

    microkit_mr_set(0, (seL4_Word)argument);
    microkit_msginfo reply =
        microkit_ppcall(channel, microkit_msginfo_new((seL4_Word)operation, 1));

    if (microkit_msginfo_get_count(reply) != 2) {
        return -2;
    }

    *value_out = (uint64_t)microkit_mr_get(1);
    return (int32_t)microkit_mr_get(0);
}
