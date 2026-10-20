/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Compile-only Linux capability ABI check for Qualcomm FastRPC
 * a56e9d4de3614a8d8f4b0e15ff561350c4b686e3. No device access occurs.
 *
 * The default checks the real private upstream-adapter header, supplied
 * through the compiler's include path. Optionally define
 * LEXR_KERNEL_FASTRPC_UAPI_HEADER as a quoted header path to compare the
 * real, separately supplied Linux UAPI in the same translation unit.
 *
 * The kernel's first capability word is ignored; its name is not an ABI.
 * These assertions do not qualify ioctl 12 or any physical DSP behavior.
 */
#include <stddef.h>
#include <stdint.h>
#include <sys/ioctl.h>

#include "fastrpc_ioctl.h"

typedef struct fastrpc_ioctl_capability lexr_private_capability;

_Static_assert(sizeof(lexr_private_capability) == 28, "private capability size");
_Static_assert(_Alignof(lexr_private_capability) == 4, "private capability alignment");
_Static_assert(offsetof(lexr_private_capability, domain) == 0, "private first word");
_Static_assert(offsetof(lexr_private_capability, attribute_id) == 4, "private attribute");
_Static_assert(offsetof(lexr_private_capability, capability) == 8, "private result");
_Static_assert(offsetof(lexr_private_capability, reserved) == 12, "private reserved");
_Static_assert(sizeof(((lexr_private_capability *)0)->reserved) == 16,
               "private reserved word count");
_Static_assert(FASTRPC_IOCTL_GET_DSP_INFO ==
                   _IOWR('R', 13, lexr_private_capability), "private ioctl encoding");
_Static_assert(_IOC_TYPE(FASTRPC_IOCTL_GET_DSP_INFO) == 'R', "private ioctl type");
_Static_assert(_IOC_NR(FASTRPC_IOCTL_GET_DSP_INFO) == 13, "private ioctl number");
_Static_assert(_IOC_SIZE(FASTRPC_IOCTL_GET_DSP_INFO) == 28, "private ioctl size");
_Static_assert(_IOC_DIR(FASTRPC_IOCTL_GET_DSP_INFO) == (_IOC_READ | _IOC_WRITE),
               "private ioctl direction");

#ifdef LEXR_KERNEL_FASTRPC_UAPI_HEADER
/* Both headers intentionally use these two tags. Keep both real definitions. */
#define fastrpc_invoke_args lexr_kernel_fastrpc_invoke_args
#define fastrpc_ioctl_capability lexr_kernel_fastrpc_ioctl_capability

/* Avoid macro redefinition diagnostics: each real header is checked in turn. */
#undef FASTRPC_IOCTL_ALLOC_DMA_BUFF
#undef FASTRPC_IOCTL_FREE_DMA_BUFF
#undef FASTRPC_IOCTL_INVOKE
#undef FASTRPC_IOCTL_INIT_ATTACH
#undef FASTRPC_IOCTL_INIT_CREATE
#undef FASTRPC_IOCTL_MMAP
#undef FASTRPC_IOCTL_MUNMAP
#undef FASTRPC_IOCTL_INIT_ATTACH_SNS
#undef FASTRPC_IOCTL_INIT_CREATE_STATIC
#undef FASTRPC_IOCTL_MEM_MAP
#undef FASTRPC_IOCTL_MEM_UNMAP
#undef FASTRPC_IOCTL_GET_DSP_INFO

#include LEXR_KERNEL_FASTRPC_UAPI_HEADER

typedef struct lexr_kernel_fastrpc_ioctl_capability lexr_kernel_capability;

_Static_assert(sizeof(lexr_kernel_capability) == 28, "kernel capability size");
_Static_assert(_Alignof(lexr_kernel_capability) == 4, "kernel capability alignment");
_Static_assert(offsetof(lexr_kernel_capability, unused) == 0, "kernel ignored word");
_Static_assert(offsetof(lexr_kernel_capability, attribute_id) == 4, "kernel attribute");
_Static_assert(offsetof(lexr_kernel_capability, capability) == 8, "kernel result");
_Static_assert(offsetof(lexr_kernel_capability, reserved) == 12, "kernel reserved");
_Static_assert(sizeof(((lexr_kernel_capability *)0)->reserved) == 16,
               "kernel reserved word count");
_Static_assert(sizeof(lexr_kernel_capability) == sizeof(lexr_private_capability),
               "equal capability layouts");
_Static_assert(FASTRPC_IOCTL_GET_DSP_INFO ==
                   _IOWR('R', 13, lexr_private_capability), "equal ioctl encoding");
_Static_assert(_IOC_TYPE(FASTRPC_IOCTL_GET_DSP_INFO) == 'R', "kernel ioctl type");
_Static_assert(_IOC_NR(FASTRPC_IOCTL_GET_DSP_INFO) == 13, "kernel ioctl number");
_Static_assert(_IOC_SIZE(FASTRPC_IOCTL_GET_DSP_INFO) == 28, "kernel ioctl size");
_Static_assert(_IOC_DIR(FASTRPC_IOCTL_GET_DSP_INFO) == (_IOC_READ | _IOC_WRITE),
               "kernel ioctl direction");

#undef fastrpc_ioctl_capability
#undef fastrpc_invoke_args
#endif

int main(void)
{
    return 0;
}
