/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The worker may suspend only its own statically provisioned TCB. The
 * self-capability is explicitly installed by the Microkit system description.
 */
#include <microkit.h>
#include <sel4/sel4.h>

int zweig_process_slot_park(void)
{
    seL4_CPtr self_tcb = microkit_cspace_root_slot_to_cptr(1);
    if (self_tcb == seL4_CapNull) {
        return -1;
    }
    return seL4_TCB_Suspend(self_tcb);
}
