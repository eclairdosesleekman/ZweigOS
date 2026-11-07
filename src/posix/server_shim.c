/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Microkit's protected() ABI stays in C; syscall policy stays in Zig.
 */
#include <microkit.h>
#include <sel4/sel4.h>

#include <stdint.h>

/*
 * The SDF grants this PD a capability to the one statically provisioned
 * process-slot TCB in CSpace slot 1. We can rewrite its x86-64 user context
 * but cannot create additional TCBs or change its CSpace/VSpace.
 */
int zweig_process_slot_start(uint64_t entry, uint64_t stack_pointer, uint64_t rflags)
{
    const seL4_CPtr worker_tcb = microkit_cspace_root_slot_to_cptr(1);
    if (worker_tcb == seL4_CapNull) {
        return -1;
    }

    int error = seL4_TCB_Suspend(worker_tcb);
    if (error != 0) {
        return error;
    }

    seL4_UserContext registers = {0};
    registers.rip = entry;
    registers.rsp = stack_pointer;
    registers.rflags = rflags;

    const seL4_Word register_count = sizeof(registers) / sizeof(seL4_Word);
    return seL4_TCB_WriteRegisters(
        worker_tcb,
        seL4_True,
        0,
        register_count,
        &registers);
}

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
