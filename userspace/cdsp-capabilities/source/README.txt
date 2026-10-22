Native Linux CDSP advertised-capability query
===========================================

This small raw-source utility prepares a missing hardware-qualification step:
querying the firmware-advertised unsigned-PD and architecture attributes without
loading libcdsprpc or executing the unqualified SDK-linked compute worker.
It does not implement NPU inference or establish device-feature parity.
Only the normal Linux C runtime/loader are linked, not the SDK. The software
checks allow libc and the exact standard ARM64 loader, and verify ELF machine
and interpreter before execution; ordinary C-runtime startup code remains.

An actual query is ACTIVE, not a passive file inventory or a read-only promise.
The reviewed Linux driver reserves a FastRPC session at open. GET_DSP_INFO may
send an internal control RPC and cache the complete firmware attribute vector.
Close also attempts an internal process-release RPC. Its driver return ignores
the firmware-release result, so close success does not prove DSP acknowledgement.
No userspace INIT_CREATE, INIT_ATTACH, DMA allocation, firmware loading, module
loading or arbitrary service INVOKE is issued by this utility. The kernel's
own control RPCs are not removed or hidden by avoiding the SDK.

Build as an ordinary nonroot user on native Linux ARM64 with a C11 compiler,
make, libc and Linux UAPI headers. No SDK or Windows payload is required:

  make

The optional finite offline checks also require Python 3 and a GNU-compatible
linker. Run them ONLY in an isolated environment with both named FastRPC device
nodes absent (no device passthrough). The test refuses existing nodes:

  make check

query-unit wraps every device operation at link time and never delegates to a
real device. check-cli.py runs help/invalid intent and actual ENOENT paths only.
It also directs help to Linux's standard /dev/full output-failure sink.
These software checks cannot establish capabilities of a physical DSP.

No installation, permission changes, service activation or hardware access is
part of make or the guarded offline checks. Do not run the following active
command on a physical device without a separately agreed test window:

  ./cdsp-capabilities --query-cdsp --device /dev/fastrpc-cdsp

Alternatively an operator may explicitly select /dev/fastrpc-cdsp-secure. The
utility never automatically tries another device, changes device permissions,
uses a signed/unsigned-PD fallback, creates a user PD, or copies firmware.
O_NOFOLLOW rejects a final symlink and fstat requires a character device after
open. These checks do not authenticate the device/channel or physical SoC.
The device manager and selected names are trusted; the UAPI's first unused word
does not select a domain. A future hardware report needs independent device/
sysfs/channel and boot identity evidence before attributing it to physical CDSP.

The single JSON report retains raw 32-bit values, per-query ioctl returns and
errno, partial successful observations, earliest error and a separate close
error. A positive ioctl failure is not incorrectly converted into stale errno.
kernel_cache_freshness is always unknown: the reviewed query can serve values
cached by the channel from an earlier client, shared by that channel's device
files. This UAPI supplies no cache-age, firmware-epoch or refresh guarantee.
Neither ioctl nor close is retried after interruption. A completed query returns
zero even for raw values that are not usable by our current compute candidate:
query success means information was returned, not that deployment is allowed.
No value is silently masked to v73 or presented as runtime qualification.

There is no whole-command timeout guarantee. The reviewed kernel's completion
wait begins only after its send path; a userspace timeout cannot prove firmware
quiescence. Output-write failure is a command failure, not a capability result.
--help and rejected arguments do not call the device-query function.

Provenance and licences
----------------------

Authored utility, build instructions and tests: BSD-3-Clause; see LICENSES.
include/fastrpc.h is the unchanged public Linux UAPI header, GPL-2.0 WITH
Linux-syscall-note. Its syscall exception and GPL text are retained.
Attribute IDs are documented in the public Qualcomm FastRPC remote.h at:

  https://github.com/qualcomm/fastrpc/tree/a56e9d4de3614a8d8f4b0e15ff561350c4b686e3

The IDs are UNSIGNED_PD_SUPPORT=1 and ARCH_VER=6. Their copied declarations
are not firmware observations. The source manifest records exact inputs and
the separate validation receipt records any actual build/test evidence.
No proprietary SDK, Windows DLL, firmware image or device factory data is
included in this source delivery.
