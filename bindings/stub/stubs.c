#include "../bindings.h"
#include "elf_abi.h"

#define U __attribute__((unused))

void _start(const void *arg U)
{
}

uintptr_t SSP_GUARD;

void SSP_FAIL(void)
{
}

DECLARE_ELF_INTERP

void solo5_console_write(const char *buf U, size_t size U)
{
}

void solo5_exit(int status U) {
    for(;;);
}

void solo5_abort(void) {
    for(;;);
}

solo5_time_t solo5_clock_monotonic(void) {
    return ~0;
}

solo5_time_t solo5_clock_wall(void) {
    return ~0;
}

void solo5_yield(solo5_time_t deadline U, solo5_handle_set_t *ready_set U)
{
    return;
}

solo5_result_t solo5_net_acquire(const char *name U, solo5_handle_t *handle U, struct solo5_net_info *info U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_net_write(solo5_handle_t handle U, const uint8_t *buf U, size_t size U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_net_read(solo5_handle_t handle U, uint8_t *buf U, size_t size U, size_t *read_size U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_block_acquire(const char *name U, solo5_handle_t *handle U, struct solo5_block_info *info U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_block_write(solo5_handle_t handle U, solo5_off_t offset U, const uint8_t *buf U, size_t size U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_block_read(solo5_handle_t handle U, solo5_off_t offset U, uint8_t *buf U, size_t size U)
{
    return SOLO5_R_EUNSPEC;
}

solo5_result_t solo5_set_tls_base(uintptr_t base U) 
{
    return SOLO5_R_EUNSPEC;
}
