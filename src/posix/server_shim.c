/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Microkit's protected() ABI stays in C; syscall policy stays in Zig.
 */
#include <microkit.h>

#include <stdint.h>

extern int64_t zweig_posix_dispatch(uint32_t channel,
                                    uint64_t syscall_number,
                                    uint64_t argument0,
                                    uint64_t argument1);

void zweig_console_putc(int character)
{
    microkit_dbg_putc(character);
}

microkit_msginfo protected(microkit_channel channel, microkit_msginfo message)
{
    const seL4_Word count = microkit_msginfo_get_count(message);
    int64_t result = -22; /* EINVAL */

    if (count <= 2) {
        const uint64_t argument0 = count >= 1 ? (uint64_t)microkit_mr_get(0) : 0;
        const uint64_t argument1 = count >= 2 ? (uint64_t)microkit_mr_get(1) : 0;
        result = zweig_posix_dispatch(
            (uint32_t)channel,
            (uint64_t)microkit_msginfo_get_label(message),
            argument0,
            argument1);
    }

    microkit_mr_set(0, (seL4_Word)result);
    return microkit_msginfo_new(0, 1);
}
