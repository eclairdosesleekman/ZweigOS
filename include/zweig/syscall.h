/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Zweig OS stable userspace syscall numbers. These are not Linux syscall
 * numbers. Raw results are >= 0 on success or -errno on failure.
 */
#ifndef ZWEIG_SYSCALL_H
#define ZWEIG_SYSCALL_H

#include <stdint.h>

enum zweig_syscall_number {
    ZWEIG_SYS_READ = 1,
    ZWEIG_SYS_WRITE = 2,
    ZWEIG_SYS_CLOSE = 3,
    ZWEIG_SYS_GETPID = 4,
    ZWEIG_SYS_RUN_SLOT = 5
};

long zweig_syscall0(uint64_t number);
long zweig_syscall1(uint64_t number, uint64_t arg0);
long zweig_syscall2(uint64_t number, uint64_t arg0, uint64_t arg1);

#endif
