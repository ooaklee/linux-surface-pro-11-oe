---
id: how-to-generate-service-report
title: "Collect a Private Surface Pro 11 Windows Hand-off"
# prettier-ignore
description: Collect and import the strict same-device Windows hand-off accepted by linux-armer.
---

# How To: Collect a Private Surface Pro 11 Windows Hand-off

Last reviewed: 2026-08-30

Use the canonical Windows collector to create the strict, device-bound input
accepted by `linux-armer handoff import`. This is not a general public service
report: its contents are private and proprietary.

## Before you begin

- Boot Windows on the Surface that will receive the material.
- Use a private checkout containing
  `cli/linux-armer/tools/collect-sp11-windows-handoff.ps1`.
- Choose a new output directory on private removable storage.

The collector can check its own deterministic fixtures without collecting
device material:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\linux-armer\tools\collect-sp11-windows-handoff.ps1 `
  -SelfTest
```

## Collect

Run PowerShell on the target Surface:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\linux-armer\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff `
  -Components Both
```

The output directory must not already contain a collection. The collector
closes the platform-firmware file set and same-device Bluetooth evidence. It
deliberately excludes Windows Wi-Fi firmware.

## Import and report redacted state

Move the directory privately to Linux on the same device:

```sh
linux-armer handoff import /path/to/sp11-handoff
linux-armer handoff list --json > handoff-summary.json
```

The JSON summary is redacted, but still review it before sharing. Never share
the collector output, the private store or application receipts. Use `handoff
apply` only after selecting the target root, feature set and explicit aDSP
policy described in the firmware and Bluetooth guides.

Historical dated hardware reports in this repository remain evidence of their
original test runs; they are not instructions for the current collector.
