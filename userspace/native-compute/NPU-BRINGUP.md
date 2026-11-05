# NPU Bring-Up — Surface Pro 11 (Snapdragon X1E80100)

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

## QAIRT 2.31 QIK retry (2026-11-05)

**Extraction remains blocked.** The Linux device was reachable and the QIK was
transferred, but no tested extraction method succeeded. No SDK was installed;
there is no verified `QNN_SDK_ROOT`, library inventory, `ldd` result, or SDK
sample result. `install-qairt.sh /path/to/file.qik` detects the `QCC+` magic
and reports the blocker without modifying an installation. Obtain the SDK and
any required Qualcomm tooling through the [Qualcomm AI Engine Direct SDK page](https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk)
(login and EULA required). Do not assume the QIK is a `.run` installer.

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
