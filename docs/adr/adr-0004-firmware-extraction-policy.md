---
id: adrs-adr004
title: "ADR004: Firmware Extraction Policy"
# prettier-ignore
description: Architecture Decision Record (ADR) for obtaining Surface Pro 11 firmware from Windows or public driver CABs while keeping blobs out of git.
---

## Context

[ADR003](adr-0003-denali-dtb-and-grub-injection.md) covers the device tree
required for boot. The Surface Pro 11 also requires Qualcomm and
Microsoft-provided firmware files for display/audio DSP components and related
subsystems.

The target Windows install contains Denali firmware files in the DriverStore
and `System32`. The WOA Qualcomm reference driver repository also publishes
Surface Pro 11 driver CABs under `Surface/8380_DEN`.

Those firmware files are proprietary artifacts. Committing them to this repo
would make the project harder to redistribute and review.

The Surface Pro 11 Arch work also notes a first-boot hazard: enabling the aDSP
device tree while booted from USB can reset USB and break the live root device.

## Decision

We will provide a firmware helper that can either:

- download the latest matching WOA driver CABs and extract required files, or
- copy the latest matching files from a mounted Windows root.

The helper installs firmware under `/lib/firmware/qcom/x1e80100/microsoft/`
using a Denali subdirectory where appropriate.

We will not commit firmware blobs, CABs, or locally copied payloads. The helper
defaults to a USB-safe aDSP policy: disable `adsp_dtb.mbn` unless the root
filesystem appears to be on NVMe or the user explicitly enables it.

## Consequences

The live USB can carry scripts and an empty payload directory, but users must
obtain firmware legally from their own Windows install or the public driver CAB
source.

Some hardware may remain unavailable until firmware is installed after first
boot. This is acceptable for the first boot path, whose priority is display,
storage, USB, and installer access.

If the public driver layout changes, the helper's CAB and filename mapping must
be updated.
