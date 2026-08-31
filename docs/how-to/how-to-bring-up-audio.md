---
id: how-to-bring-up-audio
title: "Bring Up Current Surface Pro 11 Audio"
# prettier-ignore
description: Install and validate the checksum-pinned Surface Pro 11 audio userspace release with Lexr.sh.
---

# How To: Bring Up Current Surface Pro 11 Audio

Last reviewed: 2026-08-30

The maintained path pairs a compatible custom kernel with the audited
`audio-fullio-v19c` userspace component. It does not require an additional
audio-routing workaround.

## Before you begin

- Boot the intended Surface kernel and retain a known-good GRUB entry.
- Build `lexr` or copy its Linux ARM64 companion binary to a writable,
  executable filesystem.
- Use a normal user for inspection and download; elevate only the reviewed
  installation.

## Inspect the system

Select the target-visible home of the Linux user whose desktop audio
configuration must be checked, then keep that exact value for every doctor and
clean-up command in this guide:

```sh
USER_HOME="<absolute-target-visible-linux-user-home>"

lexr userspace show audio-fullio-v19c
lexr doctor userspace --feature audio --user-home "$USER_HOME"
lexr doctor hardware audio
```

`doctor userspace` checks the selected root and kernel pairing. `doctor
hardware` reports bounded live evidence; it does not claim that speakers or
microphones have been physically qualified.

If the userspace doctor reports recognised legacy conflicts, create a
reversible clean-up plan rather than changing files manually:

```sh
lexr clean scan --root / --user-home "$USER_HOME"
lexr clean plan \
  --root / \
  --user-home "$USER_HOME" \
  --output lexr-audio-cleanup.json
```

Review every plan entry. Apply only a plan whose complete scope you accept:

```sh
sudo lexr clean apply \
  --root / \
  --user-home "$USER_HOME" \
  --plan lexr-audio-cleanup.json \
  --yes
```

Keep the printed receipt for recovery.

## Pull and install the audited release

```sh
lexr userspace pull audio --cache-dir build/lexr/userspace
lexr userspace install audio \
  --from <verified-audio-release-directory> \
  --dry-run
```

Use the exact verified directory printed by `userspace pull`. After reviewing
the dry run:

```sh
sudo lexr userspace install audio \
  --from <verified-audio-release-directory> \
  --yes
```

For an installed system mounted below a live environment, add
`--root <absolute-mount-point>` to the doctor, clean and install commands.
`USER_HOME` remains the absolute path as seen from inside that target; do not
prefix it with the host mount point.

## Verify playback and capture

Reboot into the intended kernel, then run:

```sh
lexr doctor userspace --feature audio --user-home "$USER_HOME"
lexr doctor hardware audio
wpctl status
```

Select the built-in audio devices in the desktop settings. Test both speakers
at a low volume first, then make a short recording and play it back. A static
doctor pass is necessary evidence, but successful playback, capture and a
suspend/resume cycle are the hardware acceptance gates. Those exercises are an
intentional physical qualification boundary and are not capabilities claimed
by the CLI.

## Recover

If installation fails, do not combine files from different audio releases.
Re-run the doctor against the same root and inspect the installer result. To
reverse an earlier clean-up, validate and apply its receipt:

```sh
sudo lexr clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --user-home "$USER_HOME" \
  --yes
```

See [Migrate Legacy Audio](how-to-migrate-to-native-audio.md) for the complete
transition sequence.
