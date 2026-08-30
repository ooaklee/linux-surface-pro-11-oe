---
id: how-to-migrate-to-native-audio
title: "Migrate Legacy Surface Pro 11 Audio to FullIO v19c"
# prettier-ignore
description: Replace recognised legacy audio changes with the verified FullIO v19c release using linux-armer.
---

# How To: Migrate Legacy Surface Pro 11 Audio to FullIO v19c

Last reviewed: 2026-08-30

This migration uses two native, reversible workflows: `clean` removes only
recognised legacy changes under an exact reviewed plan, then `userspace install`
verifies and installs the maintained `audio-fullio-v19c` release.

## Inspect before changing anything

```sh
linux-armer doctor userspace --feature audio
linux-armer userspace show audio-fullio-v19c
linux-armer clean scan --root /
```

The clean scanner uses a bounded allow-list. Unknown local customisations are
reported only through other diagnostics and are not silently removed.

## Create and review the clean-up plan

```sh
linux-armer clean plan \
  --root / \
  --output linux-armer-audio-cleanup.json
```

Read the whole JSON file. Stop if it includes a recognised change you still
need, or if an unrelated customisation needs separate investigation. The plan
does not mutate the system.

Apply the accepted plan:

```sh
sudo linux-armer clean apply \
  --root / \
  --plan linux-armer-audio-cleanup.json \
  --yes
```

Record the durable receipt path printed by the command.

## Pull and install FullIO v19c

```sh
linux-armer userspace pull audio --cache-dir build/linux-armer/userspace
linux-armer userspace install audio \
  --from <verified-audio-release-directory> \
  --dry-run
sudo linux-armer userspace install audio \
  --from <verified-audio-release-directory> \
  --yes
```

Use the exact verified directory reported by `userspace pull`. Do not mix it
with files from another release. Add `--root <absolute-mount-point>` throughout
when repairing an installed system from live media.

## Verify

Reboot into the intended kernel:

```sh
linux-armer doctor userspace --feature audio
linux-armer doctor hardware audio
wpctl status
```

Test left and right playback at low volume, microphone capture, reboot and
suspend/resume. A passing static report does not itself qualify the hardware.

## Roll back the clean-up

If the migration must be reversed, use the original receipt:

```sh
sudo linux-armer clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --yes
```

Restoration revalidates the receipt and captured content before changing the
target. It does not guess which files belonged to the previous configuration.
