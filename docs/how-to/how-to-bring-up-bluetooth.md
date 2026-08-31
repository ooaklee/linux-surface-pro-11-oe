---
id: how-to-bring-up-bluetooth
title: "Bring Up Bluetooth"
# prettier-ignore
description: Import and apply same-device Bluetooth material through Lexr.sh's private Windows hand-off workflow.
---

# How To: Bring Up Bluetooth

Last reviewed: 2026-08-30

Bluetooth needs a public controller address and supporting material collected
from the same Surface Pro 11. The maintained implementation is internal to
`lexr`; no separately compiled helper is required.

## Collect the private hand-off on Windows

From a private repository checkout on the same Surface, open PowerShell and
run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 `
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
HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
lexr handoff import /path/to/sp11-handoff --store "$HANDOFF_STORE"
lexr handoff list --store "$HANDOFF_STORE"
lexr doctor hardware bluetooth
```

Import validates the closed manifest and stores only accepted material.
`handoff list` returns redacted summaries; keep import output private because
it identifies the private store. The stored material itself is never public.
The unprivileged shell expands `$HOME`, making `HANDOFF_STORE` an absolute path
that remains unchanged when it is later passed through `sudo`.

## Apply the Bluetooth feature

Review a dry run first:

```sh
lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature bluetooth \
  --dry-run

sudo lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature bluetooth \
  --confirm '<exact phrase from the current dry run>'
```

The application receipt is the recovery authority.

For an installed system mounted from live media, replace `/` with its absolute
mount point. Never apply one device's hand-off to another Surface.

## Verify

Reboot, then run:

```sh
lexr doctor userspace --feature bluetooth
lexr doctor hardware bluetooth
```

Confirm that the desktop can enable Bluetooth, discover a test device, pair,
reconnect after reboot and recover after suspend/resume. Diagnostics describe
observable state but do not replace those intentional physical qualification
steps, which are not capabilities claimed by the CLI.

## Recover or remove private material

Preview and restore a recorded application with:

```sh
sudo lexr handoff restore <receipt-id> --target-root / --dry-run
sudo lexr handoff restore <receipt-id> \
  --target-root / \
  --confirm '<exact phrase from the current restore dry run>'
```

Restore uses its target receipt and does not accept a hand-off store. When the
imported hand-off is no longer needed, preview its removal from the same store:

```sh
lexr handoff purge <id> --store "$HANDOFF_STORE" --dry-run
```

Repeat with its confirmation and the same store. Purging the store does not
undo an earlier application.
