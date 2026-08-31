---
id: how-to-install-sp11-firmware
title: "Install Surface Pro 11 Platform Firmware"
# prettier-ignore
description: Collect and apply same-device platform firmware through Lexr.sh's private Windows hand-off workflow.
---

# How To: Install Surface Pro 11 Platform Firmware

Last reviewed: 2026-08-31

Required platform firmware is proprietary and device-bound. The supported
workflow collects an exact closed set from Windows on the same Surface, imports
it into a private Linux store, and applies it through `lexr`. Do not
guess public download locations or substitute files from another device.

## Collect on the same Surface

Before collecting, [initialise the Lexr submodule](../../README.md#build-the-cli)
on Windows. This requires authenticated repository access while Lexr remains
private; once it is public, ordinary anonymous submodule initialisation is
sufficient. From the root of that checkout, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff `
  -Components PlatformFirmware
```

The collector requires a fresh output directory and deliberately excludes
Windows Wi-Fi firmware. Keep the output private, off public issue trackers,
releases and ISO payloads.

## Import and diagnose

Move the collection privately to Linux on the same Surface:

```sh
HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
lexr handoff import /path/to/sp11-handoff --store "$HANDOFF_STORE"
lexr handoff list --store "$HANDOFF_STORE"
lexr doctor userspace --feature firmware
```

Import verifies the hand-off before storing it. A userspace doctor failure is
expected until the material is applied to the selected root. The unprivileged
shell expands `$HOME`, making `HANDOFF_STORE` an absolute path that remains
unchanged when it is later passed through `sudo`.

## Apply to a live or installed root

The aDSP policy is explicit because live media and an installed system have
different boot requirements.

For the installed NVMe system:

```sh
lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature firmware \
  --adsp-policy enabled \
  --dry-run

sudo lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature firmware \
  --adsp-policy enabled \
  --confirm '<exact phrase from the current dry run>'
```

For a live USB root, use `--adsp-policy disabled`. For an installed system
mounted from live media, set `--target-root` to its absolute mount point and
use `enabled`.

Review the dry run and exact confirmation before running the privileged command.
Do not copy firmware paths manually.

## Verify

Reboot the target, then run:

```sh
lexr doctor userspace --feature firmware
lexr doctor hardware audio
```

Also verify the display, GPU acceleration, audio and suspend/resume on the
physical device. These are intentional physical qualification steps rather
than capabilities claimed by the CLI; static file validation alone is not
hardware qualification.

## Recover

Preview restoration using the receipt created by the application:

```sh
sudo lexr handoff restore <receipt-id> \
  --target-root / \
  --dry-run

sudo lexr handoff restore <receipt-id> \
  --target-root / \
  --confirm '<exact phrase from the current restore dry run>'
```

Restore reads its receipt beneath the selected target and does not accept a
hand-off store. Purging an import is a separate retention action; pass
`--store "$HANDOFF_STORE"` to that command, and remember that it does not undo
an application.
