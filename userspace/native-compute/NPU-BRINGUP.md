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

## Remaining userspace steps (manual)
1. Download **Qualcomm AI Engine Direct SDK** (QAIRT), aarch64 Linux .run
   (qairt_<ver>_linux_AARCH64.run) from the Qualcomm software center:
   https://www.qualcomm.com/developer/software/qualcomm-ai-engine-direct-sdk
   (listing may show as "AI Engine Direct" or "AI Runtime SDK"; login + EULA;
   downloads go through qpm.qualcomm.com)
2. chmod +x qairt_<ver>_linux_AARCH64.run && ./qairt_<ver>_linux_AARCH64.run
3. Set QNN env vars per SDK docs (e.g. ADSP_LIBRARY_PATH, LD_LIBRARY_PATH to
   SDK lib/aarch64-windows... use lib/hexagon-npu-offload for CDSP skeletons).
4. Verify: run an SDK sample/benchmark against the CDSP via /dev/fastrpc-cdsp.
5. Optional app path: llama.cpp QNN backend — build with -DQNN=ON pointing at
   the QAIRT SDK (https://github.com/ggml-org/llama.cpp, docs/backend/QNN.md).

Copy this directory into the kernel repo when convenient.

## QAIRT 2.31 QIK attempt (2026-11-05)

**Blocked: the device was unreachable.** No SDK was transferred, extracted or
installed during this attempt. The kernel and permissions observations above
are prior bring-up notes, not fresh verification of the device. In particular,
no current fastrpc permissions, `ldd`, sample or dmesg results are available.

The manually downloaded `qualcomm_ai_engine_direct.2.31.0.250130.Linux-AnyCPU.qik`
is a proprietary chunked Qualcomm `QCC+` container, not a POSIX shell SFX.
The supplied investigation found no recognizable standard archive streams and
no feasible offline extraction on macOS. The Windows sibling mentions
`extractOnly`, but that does not establish Linux runner syntax. A Linux QIK/QPM
runtime or other device tooling is needed. The older `.run` instructions above
apply only if such an installer is obtained; they are not instructions for this
QIK.

`./install-qairt.sh /path/to/file.qik` currently reports the blocker and exits
without installing. With no argument it prints the manual download URL (Qualcomm
login and EULA required). No install path or environment values have been
verified. The intended destination is `/opt/qairt` using non-interactive sudo,
with `~/qairt` as fallback. Once the real SDK layout is known, set
`QNN_SDK_ROOT` to its root, add its actual aarch64 library directory to
`LD_LIBRARY_PATH`, and its actual binary directory to `PATH`. An x86_64 host
variant may provide host-independent headers and Hexagon v73/v75 skeletons;
its contents and compatibility have not been verified in this attempt.

### Command log and next checks

- `ssh -o BatchMode=yes -o ConnectTimeout=10 sp11 true` failed: hostname could
  not be resolved. `ssh -G sp11` returned `hostname sp11`, `user leon`, port 22;
  there is no `sp11` alias in the inspected SSH config.
- The same SSH connectivity check for `sp11.local`, `surface-pro-11.local`,
  `surfacepro11.local`, and `surface.local` failed to resolve. Configured hosts
  `192.168.50.235`, `192.168.50.21`, and `10.2.57.2` timed out on port 22
  with `-o BatchMode=yes -o ConnectTimeout=4`. Their device identity is unknown.
- The local QIK exists and is 1,157,603,080 bytes. Device `uname -a`, `df -h`
  for `/tmp`, `/opt`, `/home`, `nproc`, tooling, fastrpc devices and dmesg
  could not be checked; `scp` and all extraction attempts were not run.

After restoring SSH, check those prerequisites and available space before
copying the QIK to `/tmp`. On the device, check `qpm-cli`, `qpm`, `qik` and
`/opt/qualcomm`. Investigate the QIK runtime's documented extract-only mode;
if it can only install, use non-interactive sudo for `/opt/qairt` or fall back
to `~/qairt`. If no runner is available, inspect using already installed `7z`
(or `7zz`), `unsquashfs -s`, and `binwalk`; none has been shown to work on
this container. Do not install packages unless necessary and non-interactive
sudo works. Record exact commands and outputs before updating the script.
Finally inventory SDK libraries, headers, bins and examples; check fastrpc
access, run a short sample if available or inspect dependencies with `ldd`, and
check dmesg for fastrpc errors. Do not assume the device name has a `0` suffix:
the earlier notes report `/dev/fastrpc-cdsp`.
