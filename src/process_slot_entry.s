// SPDX-License-Identifier: BSD-2-Clause
// TCB entry shim. The supervisor supplies a 16-byte-aligned stack top.
// A normal call establishes the SysV x86-64 function-entry stack alignment.
.text
.global zweig_process_slot_entry
.type zweig_process_slot_entry, @function
zweig_process_slot_entry:
    call zweig_process_slot_payload
1:
    hlt
    jmp 1b
.size zweig_process_slot_entry, .-zweig_process_slot_entry
