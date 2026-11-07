/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Client-side syscall veneers. Data for write(2) is copied into the shared
 * page before the protected procedure call; pointers are never dereferenced
 * by the server in the client's address space.
 */
#include <microkit.h>

#include <stddef.h>
#include <stdint.h>

#include <zweig/syscall.h>
#include <zweig/unistd.h>

#define ZWEIG_POSIX_CHANNEL 1
#define ZWEIG_POSIX_BUFFER ((uintptr_t)0x41000000)
#define ZWEIG_POSIX_BUFFER_SIZE 4096

long zweig_syscall0(uint64_t number)
{
    microkit_msginfo reply = microkit_ppcall(
        ZWEIG_POSIX_CHANNEL,
        microkit_msginfo_new((seL4_Word)number, 0));

    if (microkit_msginfo_get_count(reply) != 1) {
        return -5;
    }
    return (long)(int64_t)microkit_mr_get(0);
}

long zweig_syscall1(uint64_t number, uint64_t arg0)
{
    microkit_mr_set(0, (seL4_Word)arg0);
    microkit_msginfo reply = microkit_ppcall(
        ZWEIG_POSIX_CHANNEL,
        microkit_msginfo_new((seL4_Word)number, 1));

    if (microkit_msginfo_get_count(reply) != 1) {
        return -5;
    }
    return (long)(int64_t)microkit_mr_get(0);
}

long zweig_syscall2(uint64_t number, uint64_t arg0, uint64_t arg1)
{
    microkit_mr_set(0, (seL4_Word)arg0);
    microkit_mr_set(1, (seL4_Word)arg1);
    microkit_msginfo reply = microkit_ppcall(
        ZWEIG_POSIX_CHANNEL,
        microkit_msginfo_new((seL4_Word)number, 2));

    if (microkit_msginfo_get_count(reply) != 1) {
        return -5;
    }
    return (long)(int64_t)microkit_mr_get(0);
}

long zweig_run_slot(void)
{
    return zweig_syscall0(ZWEIG_SYS_RUN_SLOT);
}

long zweig_getpid(void)
{
    return zweig_syscall0(ZWEIG_SYS_GETPID);
}

long zweig_write(int fd, const void *buffer, size_t length)
{
    volatile uint8_t *shared = (volatile uint8_t *)ZWEIG_POSIX_BUFFER;
    const uint8_t *source = (const uint8_t *)buffer;

    if (length > ZWEIG_POSIX_BUFFER_SIZE || (length != 0 && buffer == NULL)) {
        return -22; /* EINVAL */
    }

    for (size_t index = 0; index < length; ++index) {
        shared[index] = source[index];
    }

    return zweig_syscall2(ZWEIG_SYS_WRITE, (uint64_t)(uint32_t)fd, (uint64_t)length);
}

long zweig_read(int fd, void *buffer, size_t length)
{
    (void)buffer;
    return zweig_syscall2(ZWEIG_SYS_READ, (uint64_t)(uint32_t)fd, (uint64_t)length);
}

long zweig_close(int fd)
{
    return zweig_syscall1(ZWEIG_SYS_CLOSE, (uint64_t)(uint32_t)fd);
}
