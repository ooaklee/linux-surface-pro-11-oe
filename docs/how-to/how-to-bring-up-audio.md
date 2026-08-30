---
id: how-to-bring-up-audio
title: "Bring Up Current Surface Pro 11 Audio"
# prettier-ignore
description: Install, inspect, and validate the checksum-pinned FullIO v19c topology and UCM set with linux-armer.
---

# How To: Bring Up Current Surface Pro 11 Audio

Last reviewed: 2026-08-30

The maintained audio path uses the checksum-pinned `audio-fullio-v19c`
userspace release. Do not install the retired CRD topology, WSA routing or
boot-race services, or a manual PipeWire speaker sink on this path. Those
workarounds can conflict with the current topology and UCM set.

## Purpose

This procedure uses `linux-armer` to:

1. inspect the installed kernel, audio files, persistent boot argument, and
   known legacy conflicts;
2. review and reversibly remove only recognised obsolete workarounds;
3. download and verify the exact FullIO v19c release;
4. preview and install the complete four-file topology and UCM set; and
5. repeat static checks before carrying out a small manual hardware test.

`linux-armer doctor userspace` is deliberately static. It does not start audio
services, execute target binaries, play sound, record from microphones, or
prove physical speaker behaviour. The final hardware checks therefore remain
manual.

## Prerequisites

- A Surface Pro 11 booted with a Surface `qcom-x1e` kernel. FullIO v19c
  requires the interfaces introduced by the `sp11v12` generation and is
  currently tested through `sp11v19`.
- The current `linux-armer` executable available on the installed system.
- Network access for the release download.
- Sufficient privilege to install files below `/lib/firmware` and
  `/usr/share/alsa/ucm2`.
- Recovery media and a known-good kernel entry before changing system audio
  files.

The FullIO topology contains protected vendor-derived bytes and its catalogue
entry is redistribution-restricted. Use the verified release only within the
rights that apply to you; do not copy it into another published image or
release.

## 1. Inspect the current audio state

Run the audio-specific doctor as a regular user:

```sh
linux-armer doctor userspace --feature audio
```

A non-zero exit status is expected when audio support is missing or
inconsistent. The report checks:

- the selected Surface kernel generation;
- exact SHA-256 identities and sizes for the FullIO v19c topology and UCM set;
- the persistent
  `soundwire_qcom.sp11_feedback_active_offset2_zero=1` boot argument; and
- known system-wide legacy audio conflicts.

The report does not change the system.

## 2. Review obsolete workarounds

Start with a read-only scan, then write a private plan:

```sh
linux-armer clean scan --root /
linux-armer clean plan \
  --root / \
  --output linux-armer-audio-cleanup-plan.json
cat linux-armer-audio-cleanup-plan.json
```

Review every finding. The plan is not audio-filtered: it may also contain
recognised touchscreen or pen workarounds. Apply it only if every recognised
entry is one you intend to remove. Entries labelled `manual-review` are not
removed automatically.

The current audio allow-list covers only recognised system-wide WSA routing
units and helpers, the retired boot-race helper, and the recognised system-wide
manual PipeWire sink. It does not remove:

- per-user PipeWire or WirePlumber configuration;
- unfamiliar or locally modified files;
- retired UCM files that are outside the compiled clean-up allow-list; or
- the supported FullIO v19c files.

If the plan is correct, apply that exact reviewed plan:

```sh
sudo linux-armer clean apply \
  --root / \
  --plan linux-armer-audio-cleanup-plan.json \
  --yes
```

Keep the printed receipt path. The command backs up recognised entries before
removing them. Do not manually delete an unrecognised finding merely to make
the doctor pass.

## 3. Pull the verified FullIO v19c release

Choose a writable cache directory and download the exact audited release:

```sh
linux-armer userspace pull audio \
  --cache-dir ./linux-armer-userspace

AUDIO_RELEASE=./linux-armer-userspace/audio-fullio-v19c/sp11-audio-v19c
```

The pull fails if the remote asset set differs from the allow-list, GitHub's
publisher digests disagree with `SHA256SUMS`, or any required file is missing.
It writes a portable verification receipt into the release directory.

## 4. Preview and install the release

Verify the release and review every planned target without changing the
system:

```sh
linux-armer userspace install audio \
  --from "$AUDIO_RELEASE" \
  --dry-run
```

When the plan is correct, run the privileged installation explicitly:

```sh
sudo linux-armer userspace install audio \
  --from "$AUDIO_RELEASE" \
  --yes
sudo reboot
```

The installer verifies the bundle again and installs the complete topology and
UCM set as one transaction. Existing files at the four managed destinations
are copied to a timestamped directory below
`/var/lib/linux-armer/backups/userspace` before replacement. A failure during
the transaction triggers an automatic rollback of changes already applied.

## 5. Validate the installed state

After reboot, rerun the static doctor:

```sh
linux-armer doctor userspace --feature audio
```

If the boot argument is reported missing, media created by the current Ubuntu
adapter normally supplies it to both live and installed boot paths. For a
different installation path, add
`soundwire_qcom.sp11_feedback_active_offset2_zero=1` to that distribution's
persistent kernel command line, regenerate its bootloader configuration, and
reboot. `linux-armer` currently diagnoses this condition but does not edit an
existing system's bootloader configuration.

Confirm that the argument reached the running kernel:

```sh
grep -o 'soundwire_qcom.sp11_feedback_active_offset2_zero=[^ ]*' /proc/cmdline
cat /sys/module/soundwire_qcom/parameters/sp11_feedback_active_offset2_zero
```

The commands should show the value `1` and the module parameter `Y`.

## 6. Carry out the live hardware gates

First confirm that PipeWire exposes the built-in audio devices:

```sh
wpctl status
```

The static doctor cannot prove that a speaker is connected correctly. Before
using `speaker-test`, set the desktop output volume to a low level, keep the
speakers unobstructed, and stop immediately if you hear clipping, crackling, or
unexpectedly loud output.

```sh
speaker-test -D default -c 2 -t sine -f 440 -s 1 -l 1
speaker-test -D default -c 2 -t sine -f 440 -s 2 -l 1
```

Confirm that the first command reaches only the left speaker and the second
only the right speaker. Do not alter raw amplifier or DMA mixer controls as a
normal bring-up step.

If microphone validation is required, make a short local recording in a quiet
room:

```sh
arecord -D default -f S16_LE -r 48000 -c 2 -d 5 ./sp11-mic-test.wav
```

The recording may contain private conversation or background sound. Keep it
local unless it has been reviewed and redacted.

## Recovery and rollback limits

To restore workarounds removed by `clean apply`, use the exact receipt printed
by that command:

```sh
sudo linux-armer clean restore \
  <cleanup-receipt> \
  --root / \
  --yes
```

Restoring a retired workaround can make the FullIO audio doctor fail again, so
use this only to recover from the reviewed clean-up transaction.

There is no supported `linux-armer userspace uninstall audio` command yet. The
audio installer can automatically roll back a failed in-progress transaction,
but it does not issue a receipt that can uninstall a successful installation.
Its backup directory is recovery evidence, not an instruction to copy files
back by hand. If a successful v19c installation must be reversed, stop and
seek a reviewed recovery procedure for the exact system state.

## Troubleshooting

- If the doctor reports `audio-legacy-conflicts`, use the reviewed clean-up
  flow above. A remaining per-user or unfamiliar UCM conflict requires manual
  review because it is outside the clean-up allow-list.
- If `userspace pull audio` rejects the release, do not bypass verification or
  assemble a bundle from individual files. Retry into a new empty cache after
  checking network access and the published release state.
- If the doctor passes but PipeWire shows only a dummy output, reboot once,
  then collect `wpctl status` and relevant kernel logs. Do not reinstall the
  retired manual sink or WSA routing helpers.
- Passing static validation does not qualify headphones, DisplayPort audio,
  Bluetooth audio, microphones, suspend, or repeated reboot behaviour. Record
  each required hardware gate separately.

## References

- [Migrate Legacy Audio to FullIO v19c](how-to-migrate-to-native-audio.md)
- [ADR-0064: SP11 Audio Release Strategy](../adr/adr-0064-sp11-audio-release-strategy.md)
- [linux-armer userspace companion](../../cli/linux-armer/README.md#userspace-companion)
- [Audited userspace catalogue](../../cli/linux-armer/supported-userspace.json)
