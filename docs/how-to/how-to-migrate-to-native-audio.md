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

Select the target-visible home of the Linux user whose desktop audio
configuration must be checked, and retain the same value throughout the
migration:

```sh
USER_HOME="<absolute-target-visible-linux-user-home>"

linux-armer doctor userspace --feature audio --user-home "$USER_HOME"
linux-armer userspace show audio-fullio-v19c
linux-armer clean scan --root / --user-home "$USER_HOME"
```

The clean scanner uses a bounded allow-list. Unknown local customisations are
reported only through other diagnostics and are not silently removed.

## Create and review the clean-up plan

```sh
linux-armer clean plan \
  --root / \
  --user-home "$USER_HOME" \
  --output linux-armer-audio-cleanup.json
```

Read the whole JSON file. Stop if it includes a recognised change you still
need, or if an unrelated customisation needs separate investigation. The plan
does not mutate the system.

Apply the accepted plan:

```sh
sudo linux-armer clean apply \
  --root / \
  --user-home "$USER_HOME" \
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
with files from another release. Add `--root <absolute-mount-point>` to the
doctor, clean and install commands when repairing an installed system from live
media. `USER_HOME` remains the absolute path visible inside that target, not a
path prefixed by the host mount point.

## Verify

Reboot into the intended kernel:

```sh
linux-armer doctor userspace --feature audio --user-home "$USER_HOME"
linux-armer doctor hardware audio
wpctl status
```

Test left and right playback at low volume, microphone capture, reboot and
suspend/resume. These are intentional physical qualification steps rather than
capabilities claimed by the CLI; a passing static report does not itself
qualify the hardware.

## Roll back the clean-up

If the migration must be reversed, use the original receipt:

```sh
sudo linux-armer clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --user-home "$USER_HOME" \
  --yes
```

Restoration revalidates the receipt and captured content before changing the
target. It does not guess which files belonged to the previous configuration.
