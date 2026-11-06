# NPU Bring-Up — Surface Pro 11 (Snapdragon X Elite X1E841GE)

## Current status / remaining blocker

**TL;DR:** QNN inference works end-to-end on the **CPU** backend (custom ReLU
model, exit 0, correct output). **NPU/HTP execution is blocked**: the DSP
rejects the unsigned `libQnnHtpV73Skel.so`
(`openSessionForPriority status=0x80000580`, `deviceCreate=14001`). Fixing
this requires signing the skel with a testsig (Hexagon signing tools and root)
— the documented hard blocker. See Round 4 below for full details.

## Getting QAIRT

QAIRT SDK 2.51.0.260929 was downloaded from the Qualcomm Software Center:
<https://softwarecenter.qualcomm.com/catalog/item/qualcomm_ai_engine_direct>
(page "Qualcomm® AI Engine Direct SDK"), selecting **OS type: Linux**,
**Arch: x86**, **Distribution: Debian**, which yields the Linux x86-64 `.zip`.
That archive was transferred to the device and installed under `~/qairt`
(see `install-qairt.sh`).

## Round 4 — 2026-11-06: FastRPC loads; HTP device creation fails

This section supersedes the earlier missing-`libcdsprpc.so` blocker and
sample-model next steps below. Device: `Larimar`, aarch64,
`7.3.0-jg-1sp11v3-qcom-x1e`. The firmware/DT uses the `x1e80100` family name.
All round-4 commands ran as `leon`, without sudo/root. Device writes were
confined to `~/qairt` and `/tmp`. No SDK files or binary libraries are committed.

**Result:** NPU execution is still blocked at opening the V73 skel/CDSP
transport during QNN device creation. No HTP context, graph, execution, or
output was produced. A valid tiny graph executed successfully on CPU as a
control; this does not establish NPU execution.

### Exact environment and skel discovery

`find ~/qairt/2.51.0.260929/lib/hexagon-v73 -name "*.so"` found the real
`libQnnHtpV73Skel.so` and `libCalculator_skel.so` in `unsigned/`. Ignore
`._*` AppleDouble sidecars. There is no `dsp/` skel directory in this subset.

```sh
export QNN_SDK_ROOT=$HOME/qairt/2.51.0.260929
export LD_LIBRARY_PATH=$HOME/qairt/lib-local:$QNN_SDK_ROOT/lib/aarch64-oe-linux-gcc11.2
export ADSP_LIBRARY_PATH="$QNN_SDK_ROOT/lib/hexagon-v73/unsigned;/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp"
export PATH=$QNN_SDK_ROOT/bin/aarch64-oe-linux-gcc11.2:$PATH
```

Expanded `ADSP_LIBRARY_PATH`:

```text
/home/leon/qairt/2.51.0.260929/lib/hexagon-v73/unsigned;/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp
```

The semicolon-separated DSP path is quoted and the SDK directory is first.
These settings enable library loading and V73 detection, but **do not fix
the unit test or enable HTP execution**. The requested device search entries
were retained even though the `/vendor` paths checked below are absent.

### FastRPC provenance and retained artifacts

No source/build tree was found in `~/src` (absent), the inspected `~/qairt`
tree, or the bounded searches of `$HOME` and `/tmp` (maximum depth four).
The embedded `/src/fastrpc-src/src` path and its parents are also absent.
`/tmp/fastrpc-libs.tar.gz` remains, as do the installed libraries.

Evidence collected with `strings .../libcdsprpc.so | head -40`, targeted
`strings`, `file`, `readelf --debug-dump=info`, `readelf -p .comment`, and `ldd`:

- ELF: aarch64 shared object, unstripped, with debug info; CDSP build ID
  `341402032747037e17e03238011a72592d6bfdaa`.
- DWARF: `DW_AT_comp_dir=/src/fastrpc-src/src`, source
  `fastrpc_apps_user.c`, GNU C17 13.3.0, `-g -O2 -fPIC -fno-short-enums`.
- Compiler comment: `GCC: (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`.
  The device's current `gcc --version` reports Ubuntu 15.2.0-16ubuntu1.
  Thus an **on-device build is not established** by the remaining evidence;
  a separate build environment is plausible but unverified.
- Embedded strings include `Read fastrpc config file %s found at %s`,
  `listener_android.c:407:Error %x: fastrpc listener initialization error`,
  and `;/usr/lib/rfsa/adsp;/usr/lib/dsp;`.
- These source names, messages, Unix search paths, dependencies, and `.so.1.0.0`
  layout match the [Qualcomm FastRPC upstream family](https://github.com/qualcomm/fastrpc)
  represented by this repo's `source/upstream/fastrpc`. The vendored baseline
  is `a56e9d4de3614a8d8f4b0e15ff561350c4b686e3` per
  `source/SOURCE-PROVENANCE.json`; **the installed binary's exact revision,
  patch set, and original configure/make commands are unknown**. The SONAME
  suffix is not sufficient to identify a source release.
- `ldd libcdsprpc.so`: all dependencies resolve: `libm.so.6`,
  `libyaml-0.so.2`, `libbsd.so.0`, `libc.so.6`, `libmd.so.0`, and the
  aarch64 loader. No missing shared libraries were reported.

Condensed `ls -la ~/qairt/lib-local` (all owned by `leon:leon`, timestamp
2026-11-06 00:14, executable regular files):

| Regular file | Bytes | Symlinks pointing directly to that file |
| --- | ---: | --- |
| `libadsprpc.so.1.0.0` | 1,654,168 | `libadsprpc.so`, `libadsprpc.so.1` |
| `libcdsprpc.so.1.0.0` | 1,653,680 | `libcdsprpc.so`, `libcdsprpc.so.1` |
| `libadsp_default_listener.so.1.0.0` | 109,472 | `libadsp_default_listener.so`, `libadsp_default_listener.so.1` |
| `libcdsp_default_listener.so.1.0.0` | 109,472 | `libcdsp_default_listener.so`, `libcdsp_default_listener.so.1` |

The retained archive contains exactly those four regular files and eight
symlinks, with `root/root` archive metadata. Its SHA-256 is
`28a718aaa38ddbabfee8ca06b3d90a79a7d6084f778b6a1697b563d56c5c587a`.
`build-fastrpc.sh` pins this archive and the four installed-file hashes,
checks links and dependencies, sets the environment above, and runs the
validator. It intentionally contains no invented source-build recipe.

### Validator: full short output

```sh
qnn-platform-validator --backend dsp --libVersion --coreVersion --testBackend
```

Exit status **255**. No `--debug` was supplied; `PF_VALIDATOR: DEBUG` lines
are emitted by this build by default. Full 36-line combined output:

```text
PF_VALIDATOR: DEBUG: Calling PlatformValidator->setBackend
PF_VALIDATOR: DEBUG: Calling PlatformValidator->isBackendHardwarePresent
PF_VALIDATOR: DEBUG: Calling PlatformValidator->isBackendAvailable
PF_VALIDATOR: DEBUG: Should be able to access atleast one of libraries from : libc.so.6
PF_VALIDATOR: DEBUG: dlOpen successfull for library : libc.so.6
PF_VALIDATOR: DEBUG: Should be able to access atleast one of libraries from : libcdsprpc.so
PF_VALIDATOR: DEBUG: dlOpen successfull for library : libcdsprpc.so
Backend DSP Prerequisites: Present.
PF_VALIDATOR: DEBUG: Calling PlatformValidator->getLibVersion
PF_VALIDATOR: ERROR: The fastRPC library version is not implemented yet.

Library version of the backend DSP: Not Found.
PF_VALIDATOR: DEBUG: Calling PlatformValidator->getCoreVersion
Core Version of the backend DSP: Hexagon Architecture V73
PF_VALIDATOR: DEBUG: Calling PlatformValidator->backendCheck
PF_VALIDATOR: DEBUG: Should be able to access atleast one of libraries from : libc.so.6
PF_VALIDATOR: DEBUG: dlOpen successfull for library : libc.so.6
PF_VALIDATOR: DEBUG: Should be able to access atleast one of libraries from : libcdsprpc.so
PF_VALIDATOR: DEBUG: dlOpen successfull for library : libcdsprpc.so
PF_VALIDATOR: DEBUG: Starting calculator test
PF_VALIDATOR: DEBUG: Loading sample stub: libQnnHtpV73CalculatorStub.so
PF_VALIDATOR: DEBUG: Successfully loaded DSP library - 'libQnnHtpV73CalculatorStub.so'.  Setting up pointers.
Unable to destroy the handlePF_VALIDATOR: ERROR: -6 . Error while executing the sum function.
PF_VALIDATOR: ERROR: Please use testsig if using unsigned images.
PF_VALIDATOR: ERROR: Also make sure ADSP_LIBRARY_PATH points to directory containing skels.
Unit Test on the backend DSP: Failed.
QNN is NOT supported for backend DSP on the device.
*********** Results Summary ***********
Backend = DSP
{
  Backend Hardware  : Supported
  Backend Libraries : Found
  Library Version   : Not Found
  Core Version      : Hexagon Architecture V73
  Unit Test         : Failed
}
Error in saving the results
```

The library-version query is explicitly unimplemented; `Not Found` there
does not mean the now-loadable FastRPC library is absent.

### Testsig probes (no root)

| Command/check | Observed result |
| --- | --- |
| `ls -la /vendor/dsp/testsig* /vendor/firmware/ 2>/dev/null \| head -30` | No output. |
| `ls /sys/kernel/debug/fastrpc* 2>/dev/null` | No output with stderr suppressed. |
| `ls -ld /sys/kernel/debug /sys/kernel/debug/fastrpc* 2>&1` | `Permission denied` for the fastrpc glob; debugfs is `drwx------ root root`. |
| `cat /sys/module/fastrpc/parameters/* 2>/dev/null` | No output. |
| `ls /sys/module/fastrpc/parameters/ 2>/dev/null` | No output; an unsuppressed `ls -ld` confirms `No such file or directory`. |
| `find /vendor/dsp /vendor/firmware -name 'testsig*.so' -print` | Both search roots return `No such file or directory`; no existing testsig found there. |

Per the task's stated testsig prerequisites, the standard signing route
requires Hexagon SDK testsig tooling and a device configured to accept the
signed images. Those prerequisites were not established here. No testsig
was generated, no root-only paths were accessed, and no signing/security
settings were changed. The validator suggests testsig, but that message
alone does not prove authentication is the cause of the transport failure.

### qnn-net-run: invalid supplied artifact, then valid graph attempt

The aarch64 binary is
`$QNN_SDK_ROOT/bin/aarch64-oe-linux-gcc11.2/qnn-net-run`, build
`v2.51.0.260929181845`. Its help was inspected (first 60 lines plus the
context/logging flags). `--retrieve_context` reads an **existing saved
context** and is mutually exclusive with `--model`; it is not an output
path. No saved HTP context was available, so it was not supplied.

The exact supplied sample is `qnn_model_float.bin`, alongside
`qnn_model_float.cpp`, `input_list_float.txt`, and `input_data_float/`.
The list contains two relative raw input paths; the command ran from the
models directory so those paths resolve:

```sh
cd "$QNN_SDK_ROOT/examples/QNN/converter/models"
qnn-net-run --backend libQnnHtp.so --model "$PWD/qnn_model_float.bin" \
  --input_list "$PWD/input_list_float.txt" --output_dir /tmp/round4-bin-output
```

Exit **9**, `Initialization failure`, before any context or graph creation.
`file` identifies the `.bin` as a POSIX tar archive; `tar tf` shows only
`InceptionV3_InceptionV3_Conv2d_1a_3x3_Conv2D_bias.raw` and
`InceptionV3_InceptionV3_Conv2d_1a_3x3_Conv2D_weight.raw`. It is not a
loadable model `.so` or a serialized context. Retrying with
`--log_level verbose` produced the same four-line log and no further cause.

To make an actual runnable-model attempt, an original C smoke model was
written to `/tmp/round4-qnn-smoke/relu-model.c` and compiled on-device:

```sh
cd /tmp/round4-qnn-smoke
gcc -std=gnu11 -fPIC -shared -I"$QNN_SDK_ROOT/include/QNN" \
  relu-model.c -o relu-model.so
qnn-net-run --backend libQnnHtp.so --model "$PWD/relu-model.so" \
  --input_list "$PWD/input-list.txt" --output_dir "$PWD/htp-output"
```

The model exports `QnnModel_composeGraphs`/`QnnModel_freeGraphsInfo` using
the SDK graph-info ABI and builds a single `qti.aisw` `Relu` node. Input and
output tensors are float32, shape `[1,1,1,4]`; the input raw contains
`[-2,-1,1,2]`. No proprietary model source was copied into git.

HTP exit **11**, full short output (PID is run-specific):

```text
qnn-net-run pid:148390
qnn-net-run build version: v2.51.0.260929181845
qnn-net-run log level is : QNN_LOG_LEVEL_ERROR
Processing inference input(s):
/tmp/round4-qnn-smoke/input.raw
Device Creation failure

```

HTP did not enter the model's compose function: **device creation failed
before context creation, graph composition/finalization, or execution**.
No HTP output `.raw` files exist. A filtered `--log_level verbose` retry
gave the same failure, without additional backend diagnostics.

The identical model and input with `--backend libQnnCpu.so` exited **0**:
`composeGraphs` entered with a context, `graphCreate=0`, `graphAddNode=0`,
then `Finalizing Graphs`, `Executing Graphs`, `Finished Executing Graphs`.
`cpu-output/Result_0/output.raw` decoded as float32 `[0,0,1,2]`, verifying
the model ABI, graph, and inputs independently of the DSP transport.

A separate original `/tmp/round4-qnn-smoke/device-probe.c` called the QNN
interface directly with a verbose logger, exposing errors hidden by
net-run. It was built with `gcc -std=gnu11 -I"$QNN_SDK_ROOT/include/QNN"
device-probe.c -ldl -o device-probe`. Only selected diagnostics were printed:

```text
getProviders=0 count=1
logCreate=0
backendCreate=0
IDspTransport: Unknown rpc status 0x00000180
openSessionForPriority failed: ... status=0x80000580 uri=file:///libQnnHtpV73Skel.so?qnn_2_51_0_skel_handle_invoke&_modver=1.0&_dom=cdsp
DspTransport.openSession qnn_open failed, 0x80000580, prio 100
Failed to create transport instance: 1002
Failed to create transport for device, error: 1002
Failed to load skel, error: 1002
Transport layer setup failed: 14001
Failed to parse default platform info: 14001
Failed to load default platform info: 14001
Failed to parse platform config: 14001
deviceCreate=14001 hardware_unavailable=14002 access_denied=14004
```

`14001` is `QNN_DEVICE_ERROR_INVALID_CONFIG` in the installed SDK header;
the underlying observed failure is the skel/CDSP session open. This is not
an explicit QNN access-denied result. Authentication/signing remains a
candidate, not a confirmed diagnosis. No attempt was made to bypass it.

### Script verification and remaining blocker

The script's shell syntax and help were checked locally. It was transferred
to `/tmp/build-fastrpc-round4.sh` and exercised on-device with:

```sh
bash /tmp/build-fastrpc-round4.sh --install-archive /tmp/fastrpc-libs.tar.gz
```

All four digest checks passed, all eight links matched, and dependencies
resolved. The script returned **255**, propagating the same validator
unit-test failure after reinstallation. It reinstalls only the inspected
artifacts under `~/qairt/lib-local`. The source-build history remains
unknown; the verified install/verification procedure is now recorded.
Temporary model, probe, logs (`/tmp/round4-*.log`), and CPU results remain
on the device and are not committed.

**Single remaining execution blocker:** establishing a working V73
skel/CDSP session (`qnn_open=0x80000580`) so QNN device creation can finish.
Investigating device signing/firmware/transport compatibility needs further
evidence; the path correction alone did not resolve it.

## Historical observations (before round 4)

Kernel: 7.3.0-jg-1sp11v3-qcom-x1e. Status: **KERNEL-READY** (as of 2026-11-05).

## Kernel-side state
- CDSP remoteproc UP: firmware qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn
- fastrpc driver loaded (CONFIG_QCOM_FASTRPC=m in our tree); qrtr/qrtr_smd up.
- Devices: /dev/fastrpc-adsp, /dev/fastrpc-cdsp, /dev/fastrpc-cdsp-secure
- DT compute contexts: compute-cb@1..13 under 32300000 remoteproc glink edge.
- dmesg "no reserved DMA memory for FASTRPC" = benign (CMA fallback).
- qaic (CONFIG_DRM_ACCEL_QAIC) tested: AIC100 PCIe-only, no device on X1E.
  Module removed (rmmod qaic). Do not load at boot.

## Permissions (done)
- udev rule /etc/udev/rules.d/71-fastrpc.rules:
  KERNEL=="fastrpc-*", SUBSYSTEM=="misc", MODE="0660", GROUP="render"
  (note: subsystem is misc, not fastrpc — first attempt caught this)
- User leon added to render group; verified non-root open of
  /dev/fastrpc-cdsp: OPEN-OK.

## QAIRT 2.31 QIK retry (2026-11-05) — historical note

**Extraction remains blocked.** The Linux device was reachable and the QIK was
transferred, but no tested extraction method succeeded (the QIK container starts
with `QCC+` and is not a `.run` installer). Superseded by the 2.51 zip install
below. Obtain the SDK through the [Qualcomm AI Engine Direct SDK page](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk)
(login and EULA required).

## QAIRT 2.51.0.260929 zip install (2026-11-05) — VERIFIED

The full zip was extracted on the Mac at `~/Downloads/qairt/2.51.0.260929`
(6.9 GB). A subset was staged, transferred, and installed on the device.

### Staging and transfer (macOS)

Subset tarball (from the extracted zip, NOT the QIK):

    bin/aarch64-oe-linux-gcc11.2/     (75 MB)
    lib/aarch64-oe-linux-gcc11.2/     (469 MB)
    lib/hexagon-v73/ lib/hexagon-v75/ lib/hexagon-v79/
    include/                          (6.4 MB)
    examples/QNN/converter/models/    (2.1 MB)
    examples/QNN/NetRun/

- Tarball: 307 MB gz (789 MB extracted on device).
- Transfer: `scp -P 29327 -o StrictHostKeyChecking=accept-new` to device
  `/tmp/` — 40 s over the ngrok TCP tunnel.
- Install: `mkdir -p ~/qairt && tar xzf /tmp/qairt-subset.tar.gz -C ~/qairt`
  → `~/qairt/2.51.0.260929/...`; `du -sh ~/qairt` = 789 MB.
  (macOS bsdtar emits harmless `LIBARCHIVE.xattr.com.apple.quarantine`
  warnings on GNU tar.)

### Verified layout on device

`~/qairt/2.51.0.260929/lib/aarch64-oe-linux-gcc11.2/` contains libQnnHtp.so,
libQnnHtpPrepare.so, libQnnSystem.so, libQnnHtpV73/V75/V79Stub.so (stubs are
HERE, not under hexagon-*). `lib/hexagon-v73/unsigned/` contains the skels:
libQnnHtpV73Skel.so, libQnnHexagonSkel_dspApp.so, libcdsprc.so is NOT there.

### Environment (exact, verified paths)

    R=$HOME/qairt/2.51.0.260929
    export QNN_SDK_ROOT=$R
    export LD_LIBRARY_PATH=$R/lib/aarch64-oe-linux-gcc11.2
    export ADSP_LIBRARY_PATH=$R/lib/hexagon-v73/unsigned

There is no `lib/hexagon-v73/dsp` in this zip — the skel dir is
`lib/hexagon-v73/unsigned`. Android-only paths (/vendor/dsp/cdsp etc.) do not
exist on this OE image and were dropped from ADSP_LIBRARY_PATH.

### Validator result — DSP backend FAILS: libcdsprpc.so missing

    qnn-platform-validator --backend dsp
    → "Should be able to access atleast one of libraries from : libcdsprpc.so"
    → "Missing shared libraries: libcdsprpc.so"
    → Backend DSP Prerequisites: Absent.
    → Backend Hardware : Supported / Backend Libraries : Not Found

Hardware detection passes (fastrpc nodes visible), but the userspace FastRPC
RPC shim `libcdsprpc.so` does not exist anywhere on the device image or in the
SDK zip — it is normally shipped in the device OS (e.g. /vendor/lib on
Android) or as a separate QAIRT "linuxOE" companion, and is not present in
this zip distribution. This was the blocker at that round; round 4 above
supersedes it with locally installed FastRPC libraries.

`--backend cpu/gpu` are not accepted by this validator build (dsp/gpu/all only).

### qnn-net-run sample — no runnable prebuilt model in the zip

`examples/QNN/converter/models/qnn_model_float.bin` is a POSIX tar of two
`.raw` weight tensors for the converter sample, NOT a QNN model. Running it
yields `Initialization failure` (identical with libQnnCpu.so and libQnnHtp.so),
which is expected: the SDK zip ships no prebuilt, runnable model. A real test
needs a model compiled with qairt-converter (x86_64 host tool) or a
built sample-app .so.

### Next steps recorded before round 4 (superseded)

1. Obtain `libcdsprpc.so` for aarch64-oe-linux (check the QAIRT "linuxOE
   companion" / Poky distro packages, or build fastrpc userspace from source).
2. Compile a tiny model on the Mac with `qairt-converter` (x86_64 binaries are
   in the zip) or build examples/QNN/SampleApp on-device, then re-test with
   `qnn-net-run --backend libQnnHtp.so`.

### Transfer and device

The device reported `Linux Larimar 7.3.0-jg-1sp11v3-qcom-x1e aarch64`, 12
processors, and 15 GB free in `/tmp`. The following transfer completed in
139.32 seconds (8.31 MB/s, decimal); `stat` on the device reported the same
1,157,603,080 bytes as the source:

```sh
scp -P 29327 -o StrictHostKeyChecking=accept-new \
  qualcomm_ai_engine_direct.2.31.0.250130.Linux-AnyCPU.qik \
  leon@6.tcp.eu.ngrok.io:/tmp/
```

The tunnel address is specific to this session. The QIK remains in `/tmp`
because extraction did not succeed. Neither `/opt/qairt`, `~/qairt`, nor
`/tmp/qairt-ext` existed during the check. `sudo -n true` returned
`sudo: interactive authentication is required`; a future successful extraction
would therefore need a writable destination such as `~/qairt` unless sudo
access changes.

### Inspection and extraction probes

On the device, `file /tmp/*.qik` reported `data`. `head -c 512 ... | xxd`
started with `5143 432b 3100` (`QCC+1`); the first 2048 bytes inspected with
`strings` showed `QCC+`, with no shell or makeself header. Thus the tested
file is a QCC+ binary container on Linux too, not a shell SFX. In order:

```text
$ bash /tmp/qualcomm_ai_engine_direct.2.31.0.250130.Linux-AnyCPU.qik
...: cannot execute binary file
# exit 126
$ unsquashfs -s /tmp/qualcomm_ai_engine_direct.2.31.0.250130.Linux-AnyCPU.qik
FATAL ERROR: Can't find a valid SQUASHFS superblock on ...
# exit 1
$ sudo -n true
sudo: interactive authentication is required
```

`7z`, `7zz`, and `binwalk` were not installed; `qpm-cli`, `qpm`, and `qik`
were not on PATH and `/opt/qualcomm` was absent. No packages were installed.
There was no shell stub to invoke with makeself flags, and the conditional
sudo/direct-execution attempt was not run because sudo was unavailable. A
working extraction method or compatible Qualcomm tooling is still needed before
staging the SDK and determining its actual layout and environment variables.

### NPU checks

```text
crw-rw---- 1 root render 10, 266 ... /dev/fastrpc-cdsp
crw-rw---- 1 root render 10, 265 ... /dev/fastrpc-cdsp-secure
```

`leon` belongs to `render`, and Python `os.open('/dev/fastrpc-cdsp',
os.O_RDONLY)` printed `OPEN-OK`. `/dev/fastrpc-cdsp0` does not exist, so
`dd if=/dev/fastrpc-cdsp0 count=0` failed with `No such file or directory`.
`ctypes.CDLL('/usr/lib/libcdsprpc.so')` failed because that file was absent.
Without an SDK, `libQnnHtp.so`, SDK `libcdsprpc.so`, library directories, and
sample binaries could not be inventoried or tested. This device-node open does
not establish NPU execution.

Both `sudo -n dmesg` and plain `dmesg` were attempted: sudo required
interactive authentication and plain dmesg returned `read kernel buffer
failed: Operation not permitted`. No current fastrpc, qrtr, or cdsp kernel-log
results are available. The earlier kernel-side notes are prior observations.

## Round 7 (2026-11-06): root testsig/vendor-dsp route

Staged on device (as root, `/vendor/dsp/cdsp/`, from QAIRT 2.51.0.260929,
first placed 00:58, refreshed 01:11):

- `libQnnHtpV73.so`, `libQnnHtpV73Skel.so` (from `lib/hexagon-v73/unsigned/`)
- `libQnnHtpV73QemuDriver.so`

Environment:

```sh
export QNN_SDK_ROOT=$HOME/qairt/2.51.0.260929
export LD_LIBRARY_PATH=$QNN_SDK_ROOT/lib/aarch64-oe-linux-gcc11.2:$HOME/qairt/lib-local
export ADSP_LIBRARY_PATH="/vendor/dsp/cdsp;$QNN_SDK_ROOT/lib/hexagon-v73/unsigned"
# also tried: ADSP_LIBRARY_PATH=/vendor/dsp/cdsp alone
```

HTP run verdict: FAIL. `qnn-net-run --backend libQnnHtp.so` (relu model,
`/tmp/round4-qnn-smoke`) as user `leon` exits 11 with "Device Creation
failure"; `./device-probe` still reports `deviceCreate=14001` (near
`hardware_unavailable=14002`, `access_denied=14004`) and "PrepareLib isn't
loaded!". As root it gets further but fails exit 9 "Initialization failure".
Both `ADSP_LIBRARY_PATH` variants behave identically. CPU backend remains OK.

Diagnostics: `/dev/fastrpc-cdsp` and `-secure` exist (root:render, `leon` in
render); CDSP remoteproc is `running`; dmesg shows repeated
`qcom-apm gprsvc ... DSP returned error[1001006] 3` around probe attempts and
`no reserved DMA memory for FASTRPC` at boot. SecureBoot efivar reads
`\x06 \0 \0 \0 \0` (trailing byte 0 = Secure Boot disabled).
`/sys/module/fastrpc/parameters/` does not exist on this kernel (module
parameters not exposed).

Conclusion: with unsigned skels staged in `/vendor/dsp/cdsp` and Secure Boot
off, the cdsp domain still refuses the FastRPC session. Next candidates:
Qualcomm testsig route (dsp signatures), signed skels, or kernel/DSP-image
version matching (1001006 from the APM/gprsvc side suggests the DSP-side
audio-PDR path erroring, not file access).
