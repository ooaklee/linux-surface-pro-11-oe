---
id: how-to-bring-up-bluetooth
title: "Bring Up Bluetooth"
# prettier-ignore
description: Import and apply same-device Bluetooth material through linux-armer's private Windows hand-off workflow.
---

# How To: Bring Up Bluetooth

Last reviewed: 2026-08-30

Bluetooth needs a public controller address and supporting material collected
from the same Surface Pro 11. The maintained implementation is internal to
`linux-armer`; no separately compiled helper is required.

## Collect the private hand-off on Windows

From a private repository checkout on the same Surface, open PowerShell and
run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\linux-armer\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff `
  -Components Bluetooth
```

The collector creates a fresh, strict hand-off directory. Treat it as private,
device-bound and proprietary. Do not publish it, commit it, or include it in an
ISO or release. The collector deliberately excludes Windows Wi-Fi firmware.

## Import and inspect on Linux

Move the directory privately to the same device's Linux installation, then
run as a normal user:

```sh
linux-armer handoff import /path/to/sp11-handoff
linux-armer handoff list
linux-armer doctor hardware bluetooth
```

Import validates the closed manifest and stores only accepted material.
`handoff list` returns redacted summaries; keep import output private because
it identifies the private store. The stored material itself is never public.

## Apply the Bluetooth feature

Review a dry run first:

```sh
linux-armer handoff apply <id> \
  --target-root / \
  --feature bluetooth \
  --dry-run
```

Repeat without `--dry-run` and enter the exact confirmation printed by the
CLI. The application receipt is the recovery authority.

For an installed system mounted from live media, replace `/` with its absolute
mount point. Never apply one device's hand-off to another Surface.

## Verify

Reboot, then run:

```sh
linux-armer doctor userspace --feature bluetooth
linux-armer doctor hardware bluetooth
```

Confirm that the desktop can enable Bluetooth, discover a test device, pair,
reconnect after reboot and recover after suspend/resume. Diagnostics describe
observable state but do not replace those physical qualification steps.

## Recover or remove private material

Preview and restore a recorded application with:

```sh
linux-armer handoff restore <receipt-id> --target-root / --dry-run
```

Repeat with the exact confirmation after review. When the imported hand-off is
no longer needed, preview `handoff purge <id> --dry-run`, then repeat with its
confirmation. Purging the store does not undo an earlier application.
