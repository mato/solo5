/* 
 * Copyright (c) 2015-2017 Contributors as noted in the AUTHORS file
 *
 * This file is part of ukvm, a unikernel monitor.
 *
 * Permission to use, copy, modify, and/or distribute this software
 * for any purpose with or without fee is hereby granted, provided
 * that the above copyright notice and this permission notice appear
 * in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
 * WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
 * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
 * OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
 * NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <assert.h>
#include <err.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <machine/vmm.h>
#include <sys/param.h>
#include <sys/cpuset.h>
#include <machine/vmm_dev.h>

#include "ukvm.h"
#include "ukvm_hv_bhyve.h"

struct ukvm_hv *ukvm_hv_init(size_t mem_size)
{
    int ret;

    struct ukvm_hv *hv = malloc(sizeof (struct ukvm_hv));
    if (hv == NULL)
        err(1, "malloc");
    memset(hv, 0, sizeof (struct ukvm_hv));
    struct ukvm_hvb *hvb = malloc(sizeof (struct ukvm_hvb));
    if (hvb == NULL)
        err(1, "malloc");
    memset(hvb, 0, sizeof (struct ukvm_hvb));
    hv->b = hvb;

    /* XXX This seems to fail every second time!? */
    sysctlbyname("hw.vmm.destroy", NULL, NULL, "ukvm", 4);
    ret = sysctlbyname("hw.vmm.create", NULL, NULL, "ukvm", 4);
    if (ret == -1)
	err(1, "sysctl(hw.vmm.create)");
    hvb->vmfd = open("/dev/vmm/ukvm", O_RDWR, 0);
    if (hvb->vmfd == -1)
	err(1, "vm_open");

    struct vm_capability vmcap = {
	.cpuid = 0, .captype = VM_CAP_HALT_EXIT, .capval = 1
    };
    ret = ioctl(hvb->vmfd, VM_SET_CAPABILITY, &vmcap);
    if (ret == -1)
	err(1, "set VM_CAP_HALT_EXIT");

    struct vm_memseg memseg = {
	.segid = 0, .len = mem_size
    };
    ret = ioctl(hvb->vmfd, VM_ALLOC_MEMSEG, &memseg);
    if (ret == -1)
	err(1, "VM_ALLOC_MEMSEG");

    struct vm_memmap memmap = {
	.gpa = 0, .len = mem_size, .segid = 0, .segoff = 0,
	.prot = PROT_READ | PROT_WRITE | PROT_EXEC, .flags = 0
    };
    ret = ioctl(hvb->vmfd, VM_MMAP_MEMSEG, &memmap);
    if (ret == -1)
	err(1, "VM_MMAP_MEMSEG");

    hv->mem = mmap(NULL, mem_size, PROT_READ | PROT_WRITE, MAP_SHARED,
	    hvb->vmfd, 0);
    if (hv->mem == MAP_FAILED)
	err(1, "mmap");
    hv->mem_size = mem_size;
    return hv;
}
