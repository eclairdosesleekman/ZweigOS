// SPDX-License-Identifier: BSD-2-Clause
// TCB entry shims. The supervisor supplies a 16-byte-aligned stack top.
.text
.global zweig_process_slot_entry
.type zweig_process_slot_entry, @function
zweig_process_slot_entry:
    call zweig_process_slot_payload
1:
    hlt
    jmp 1b
.size zweig_process_slot_entry, .-zweig_process_slot_entry

// Call the pre-mapped RX image as a normal SysV x86-64 leaf function. Its
// return value in RAX is passed to the trusted worker completion routine.
.global zweig_process_slot_image_entry
.type zweig_process_slot_image_entry, @function
zweig_process_slot_image_entry:
    movabs $0x44000000, %rax
    call *%rax
    mov %rax, %rdi
    call zweig_process_slot_finish
2:
    hlt
    jmp 2b
.size zweig_process_slot_image_entry, .-zweig_process_slot_image_entry
