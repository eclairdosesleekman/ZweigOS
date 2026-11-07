/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Early C-facing Zweig syscall veneers. These use raw -errno results; they
 * are not a replacement for the POSIX libc contract (which sets errno).
 */
#ifndef ZWEIG_UNISTD_H
#define ZWEIG_UNISTD_H

#include <stddef.h>
#include <stdint.h>

long zweig_read(int fd, void *buffer, size_t length);
long zweig_write(int fd, const void *buffer, size_t length);
long zweig_close(int fd);
long zweig_getpid(void);
long zweig_run_slot(void);
long zweig_exec_slot(const void *image, size_t length);

#endif
