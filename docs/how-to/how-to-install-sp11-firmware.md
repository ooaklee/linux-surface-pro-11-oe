---
id: how-to-install-sp11-firmware
title: "Install Surface Pro 11 Platform Firmware"
# prettier-ignore
description: Collect and apply same-device platform firmware through linux-armer's private Windows hand-off workflow.
---

# How To: Install Surface Pro 11 Platform Firmware

Last reviewed: 2026-08-30

Required platform firmware is proprietary and device-bound. The supported
workflow collects an exact closed set from Windows on the same Surface, imports
it into a private Linux store, and applies it through `linux-armer`. Do not
guess public download locations or substitute files from another device.

## Collect on the same Surface

From a private checkout on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\linux-armer\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff `
  -Components PlatformFirmware
```

The collector requires a fresh output directory and deliberately excludes
Windows Wi-Fi firmware. Keep the output private, off public issue trackers,
releases and ISO payloads.

## Import and diagnose

Move the collection privately to Linux on the same Surface:

```sh
linux-armer handoff import /path/to/sp11-handoff
linux-armer handoff list
linux-armer doctor userspace --feature firmware
```

Import verifies the hand-off before storing it. A userspace doctor failure is
expected until the material is applied to the selected root.

## Apply to a live or installed root

The aDSP policy is explicit because live media and an installed system have
different boot requirements.

For the installed NVMe system:

```sh
linux-armer handoff apply <id> \
  --target-root / \
  --feature firmware \
  --adsp-policy enabled \
  --dry-run
```

For a live USB root, use `--adsp-policy disabled`. For an installed system
mounted from live media, set `--target-root` to its absolute mount point and
use `enabled`.

Review the dry run, then repeat without `--dry-run` and enter the exact
confirmation printed by the CLI. Do not copy firmware paths manually.

## Verify

Reboot the target, then run:

```sh
linux-armer doctor userspace --feature firmware
linux-armer doctor hardware audio
```

Also verify the display, GPU acceleration, audio and suspend/resume on the
physical device. Static file validation alone is not hardware qualification.

## Recover

Preview restoration using the receipt created by the application:

```sh
linux-armer handoff restore <receipt-id> \
  --target-root / \
  --dry-run
```

Repeat with its exact confirmation only after checking the selected root and
receipt. Purging an import is a separate retention action and does not undo an
application.
