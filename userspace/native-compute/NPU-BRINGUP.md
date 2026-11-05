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
