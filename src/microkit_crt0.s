/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Minimal x86-64 Microkit CRT entry point. The Microkit SDK supplies
 * main() and the passive/active handler loop in libmicrokit.
 */
.section .text.start,"ax",@progbits
.globl _start
.type _start,@function
_start:
    call main
.Lunexpected_return:
    hlt
    jmp .Lunexpected_return
.size _start, . - _start
