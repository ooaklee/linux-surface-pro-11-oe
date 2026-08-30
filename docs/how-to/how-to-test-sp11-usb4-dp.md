---
id: how-to-test-sp11-usb4-dp
title: "Test SP11 USB4 and DisplayPort"
# prettier-ignore
description: How-to guide for safely building the Surface Pro 11 v20 USB4 PHY integration, preserving direct DisplayPort fallback, and collecting passive evidence for later USB4-tunnel qualification.
---

# How To: Test SP11 USB4 and DisplayPort

Use this procedure to build the v20 USB4 integration, verify the working
direct-DisplayPort baseline, and collect comparable top- and bottom-port
snapshots. The current v20 increment does not enable the production USB4 path.

## Purpose

Direct USB-C DisplayPort Alt Mode and DisplayPort tunneled through USB4 are
different tests. A monitor appearing through a direct USB-C cable does not
prove that a USB4 router or DisplayPort tunnel exists. This guide keeps those
results separate and establishes the evidence needed for a later USB4-tunnel
gate.

## Prerequisites

- Surface Pro 11 X1E80100 with AC power connected.
- A known-good qcom-x1e kernel retained in GRUB and recovery media nearby.
- Secure Boot disabled for the experimental package.
- The USB4 v20 support and kernel branches checked out separately from pen
  work.
- A direct USB-C DisplayPort cable or monitor for the regression baseline.
- A known USB4 dock, display, and certified cable for passive topology
  snapshots. Record whether the physical top or bottom connector is used.
- A cold shutdown between any future active USB4 experiments. Do not use
  driver unbind/rebind as a substitute. This is a conservative X1E safety
  rule derived from the X1P hard-lock observations in issue 52, not a claim
  that the two variants share a verified controller register map.

## Build the v20 kernel

From the support repository, run:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/integration-7.2.x-usb4-support \
  --image ubuntu:26.04 \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-usb4-v20 \
  --linux-work-volume sp11-qcom-x1e-kernel-usb4-v20 \
  --copy-to-payload --reset-source --jobs 8
```

The branch name is mutable. Reject the build unless its generated provenance
manifest resolves to the exact kernel PR head accepted by ADR0068:

```bash
grep -Fx \
  'Source HEAD: e056649b9b56622fedd806134d4f79dcf251a2f0' \
  build/docker-sp11-qcom-x1e-kernel-usb4-v20/artifacts/sp11-kernel-build-manifest.txt
```

The four packages must share version `7.2.0-jg-0sp11v20`; the installed image
ABI is `7.2.0-jg-0sp11v20-qcom-x1e`. Reject mixed-version package sets.

Before installing, run the existing read-only package preflight with the v20
ABI and an explicitly selected known-good fallback:

```bash
sudo ./scripts/preflight-sp11-kernel-test.sh \
  --deb-dir payload/kernel-debs \
  --target-abi 7.2.0-jg-0sp11v20-qcom-x1e \
  --fallback-abi YOUR_KNOWN_GOOD_QCOM_X1E_ABI
```

Install with the existing kernel helper, reboot, and confirm the ABI:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir payload/kernel-debs --install-only
sudo reboot
uname -r
```

## Verify the direct-DisplayPort baseline

Connect the monitor directly, without a USB4 dock. Test both physical ports
and both cable orientations. Record resolution, refresh rate, hotplug, unplug,
and one suspend/resume cycle.

Passing this phase proves that v20 did not regress Direct USB-C DisplayPort Alt
Mode. It does not prove a USB4 router or DisplayPort tunnel.

## Collect passive USB4 snapshots

With the dock disconnected, collect a baseline for the port under test:

```bash
./scripts/collect-sp11-usb4-diagnostics.sh \
  --out "build/usb4-diagnostics/top-baseline-$(date -u +%Y%m%dT%H%M%SZ)" \
  --port-label top --phase baseline \
  --expected-kernel-commit e056649b9b56622fedd806134d4f79dcf251a2f0
```

Connect the dock, wait 15 seconds, then collect the attached state:

```bash
./scripts/collect-sp11-usb4-diagnostics.sh \
  --out "build/usb4-diagnostics/top-attached-$(date -u +%Y%m%dT%H%M%SZ)" \
  --port-label top --phase attached \
  --expected-kernel-commit e056649b9b56622fedd806134d4f79dcf251a2f0
```

Repeat from a cold boot for the bottom port. Do not infer a controller port
number from the physical label; retain the label until a live Type-C event
correlates it with a router port.

The collector uses standard read-only kernel interfaces and commands. It does
not access raw MMIO or device registers. The output can still include hardware
topology and kernel log details, so review and redact it before sharing.

## USB4-tunnel gate

A later experimental DTB may pass the USB4-tunnel gate only when all of these
are present in one matched attach:

```text
USB4 domain and Qualcomm host router
downstream dock router
USB 3 tunnel
PCIe tunnel where the dock exposes PCIe devices
DisplayPort tunnel and connected DRM display
clean detach and reattach
```

`boltctl list`, `/sys/bus/thunderbolt/devices`, `lspci -nnk`, `lsusb -t`, and
the DRM connector state must agree. A firmware-ready message, a parsed DROM,
QMP TBT mode, or a retimer TBT notification is not sufficient by itself.

## Expected Output

For the production v20 DTB, expect:

- the v20 kernel and Denali DTB to boot;
- direct DisplayPort Alt Mode to remain functional;
- both PS8830 nodes to retain the USB4-disable fallback; and
- no USB4 domain or tunneled DisplayPort claim.

Each collector run writes `metadata.txt`, allowlisted Type-C, Thunderbolt, and
DRM state, optional `lsusb`, `lspci`, and redacted `boltctl` output, command
availability and exit status, the current kernel log, and a verified
`SHA256SUMS` manifest into the selected private output directory. The expected
kernel commit is metadata; compare it with the package build manifest because
the running kernel cannot prove its source commit by itself.

## Privacy and Safety

Do not use `devmem`, `/dev/mem`, raw register tools, debugfs write controls,
or arbitrary interrupt and clock writes during this procedure. In particular,
do not copy the X1P controller-window probes from issue 52 onto X1E; their
addresses are not a verified X1E register map. Follow the conservative safety
boundary in [ADR0068](../adr/adr-0068-sp11-usb4-dp-integration.md).

Do not commit or publish Windows driver binaries, extracted controller
firmware, raw ETL captures, firmware memory, or unredacted diagnostic
directories. Preserve a known-good GRUB entry and cold-power the device after
an active experiment. If the device stops producing USB4 events, do not cycle
the USB4 GDSC or reload an experimental router driver in the same boot.

## Troubleshooting

If direct DisplayPort regresses, boot the known-good kernel and stop USB4
testing. Save the passive v20 and fallback snapshots for comparison.

If the dock provides USB 2/3 devices but no Thunderbolt domain, that does not
show partial USB4 success; it may be the ordinary USB fallback path.

If the controller waits for sideband receive connection or link training never
starts, record the passive state and continue in
[issue 52](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/52).
Do not replay the hard-locking probes.

## Related Documents

- [Kernel USB4 PHY integration PR 24](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/24)
- [ADR0068: SP11 USB4 and DisplayPort Integration](../adr/adr-0068-sp11-usb4-dp-integration.md)
- [ADR0004: Firmware Extraction Policy](../adr/adr-0004-firmware-extraction-policy.md)
- [ADR0026: Prebuilt Kernel Release Artifacts](../adr/adr-0026-prebuilt-kernel-release-artifacts.md)
- [Release Kernel Artifacts](how-to-release-kernel-artifacts.md)
