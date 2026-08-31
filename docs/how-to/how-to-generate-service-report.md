---
id: how-to-generate-service-report
title: "Collect a Private Surface Pro 11 Windows Hand-off"
# prettier-ignore
description: Collect and import the strict same-device Windows hand-off accepted by Lexr.sh.
---

# How To: Collect a Private Surface Pro 11 Windows Hand-off

Last reviewed: 2026-08-31

Use the canonical Windows collector to create the strict, device-bound input
accepted by `lexr handoff import`. This is not a general public service
report: its contents are private and proprietary.

## Before you begin

- Boot Windows on the Surface that will receive the material.
- [Initialise the Lexr submodule](../../README.md#build-the-cli) so that
  `cli/lexr/tools/collect-sp11-windows-handoff.ps1` is present. This requires
  authenticated repository access while Lexr remains private; once it is
  public, ordinary anonymous submodule initialisation is sufficient.
- In elevated PowerShell, follow Lexr's
  [protected-parent procedure](https://github.com/ooaklee/lexr.sh#collect-on-windows)
  to create a new private parent on the fixed local NTFS volume.
- Reserve a new directory on trusted removable storage for the completed
  transfer copy, not for the collector's live output transaction.

The collector can check its own deterministic fixtures without collecting
device material:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 `
  -SelfTest
```

## Collect

Run PowerShell on the target Surface:

```powershell
$privateParent = Join-Path $env:ProgramFiles 'lexr-private'
$handoff = Join-Path $privateParent `
  ('sp11-handoff-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory $handoff `
  -Components Both
if ($LASTEXITCODE -ne 0) {
  throw 'Windows hand-off collection failed.'
}
```

The output directory must not already contain a collection. The collector
closes the platform-firmware file set and same-device Bluetooth evidence. It
deliberately excludes Windows Wi-Fi firmware. After it succeeds, copy the
completed child to a new directory on trusted removable storage:

```powershell
$transferRoot = 'E:\lexr-private-transfer'
if ([System.IO.Directory]::Exists($transferRoot) -or
    [System.IO.File]::Exists($transferRoot)) {
  throw 'Choose a new empty transfer directory.'
}
[void][System.IO.Directory]::CreateDirectory($transferRoot)
Copy-Item -LiteralPath $handoff -Destination $transferRoot `
  -Recurse -ErrorAction Stop
```

The removable copy remains private even if its filesystem cannot retain the
Windows ACL. Do not use that copy as the live privileged output transaction.

## Import and report redacted state

Move the directory privately to Linux on the same device:

```sh
HANDOFF_STORE="${HOME}/.lexr-handoffs"
lexr handoff import /path/to/sp11-handoff --store "$HANDOFF_STORE"
lexr handoff list --store "$HANDOFF_STORE" --json > handoff-summary.json
```

The unprivileged shell expands `$HOME`, making `HANDOFF_STORE` the absolute
user-store path that later application commands must pass through `sudo` with
`--store "$HANDOFF_STORE"`. The JSON summary is redacted, but still review it
before sharing. Never share the collector output, the private store or
application receipts. Use `handoff apply` only after selecting the target root,
feature set and explicit aDSP policy described in the firmware and Bluetooth
guides.

Historical dated hardware reports in this repository remain evidence of their
original test runs; they are not instructions for the current collector.
