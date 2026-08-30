---
id: how-to-migrate-to-native-audio
title: "Migrate Legacy SP11 Audio to FullIO v19c"
# prettier-ignore
description: Replace recognised legacy Surface Pro 11 audio workarounds with the verified FullIO v19c topology and UCM set through linux-armer.
---

# How To: Migrate Legacy SP11 Audio to FullIO v19c

Last reviewed: 2026-08-30

This guide replaces the retired CRD topology, WSA routing and boot-race
helpers, and manual PipeWire sink with the maintained, checksum-pinned FullIO
v19c topology and UCM set.

Do not use the historical audio migration script for this path. It targeted an
older kernel and userspace pairing, accepted different file identities, and had
different rollback semantics from the current compiled installer.

## Before you begin

- Boot a Surface `qcom-x1e` kernel compatible with FullIO v19c. The supported
  userspace contract starts at `sp11v12` and is tested through `sp11v19`.
- Make the current `linux-armer` executable available on the installed system.
- Keep recovery media and a known-good kernel entry available.
- Expect one reboot after installing the topology because the AudioReach graph
  is loaded when the sound card probes.

The FullIO release contains protected vendor-derived bytes and is marked
redistribution-restricted. Do not republish the downloaded bundle or include it
in public installation media.

## 1. Record the starting state

Run the static audio doctor before changing anything:

```sh
linux-armer doctor userspace --feature audio
```

Save machine-readable evidence if this migration is part of a controlled test:

```sh
linux-armer doctor userspace --feature audio --json \
  > linux-armer-audio-before.json
```

Review the file before sharing it. The doctor avoids device identifiers, but
the surrounding test environment or filename may still reveal local context.

The doctor checks exact FullIO v19c file identities, kernel compatibility, the
persistent feedback-port boot argument, and known legacy conflict paths. It
does not inspect per-user PipeWire configuration or exercise the hardware.

## 2. Create and review a reversible clean-up plan

Scan without changing the system, then write a new private plan:

```sh
linux-armer clean scan --root /
linux-armer clean plan \
  --root / \
  --output linux-armer-audio-cleanup-plan.json
cat linux-armer-audio-cleanup-plan.json
```

The plan is not limited to audio. It can contain recognised touchscreen or pen
workarounds as well, so do not apply it until every recognised entry is
understood and intended. An entry marked `manual-review` is preserved by
`clean apply`.

For audio, the compiled allow-list is deliberately narrow. It recognises only
known system-wide WSA routing units and helpers, the known boot-race helper,
and the recognised system-wide manual PipeWire sink. It does not remove
per-user PipeWire or WirePlumber configuration, unfamiliar UCM files, locally
modified files, or arbitrary paths that merely look old.

Apply the exact reviewed plan only when it is correct:

```sh
sudo linux-armer clean apply \
  --root / \
  --plan linux-armer-audio-cleanup-plan.json \
  --yes
```

Record the receipt path printed by the command. Newly discovered or changed
targets are not silently added when the plan is applied.

If `doctor userspace` later reports a legacy UCM path that `clean` did not
recognise, stop for manual review. Do the same if PipeWire still exposes a
per-user manual sink, which the static doctor does not inspect. Do not run
retired helpers or delete a file merely to silence the report.

## 3. Pull and preview FullIO v19c

Download the exact audited release into a dedicated cache:

```sh
linux-armer userspace pull audio \
  --cache-dir ./linux-armer-userspace

AUDIO_RELEASE=./linux-armer-userspace/audio-fullio-v19c/sp11-audio-v19c
```

Preview the complete installation as a regular user:

```sh
linux-armer userspace install audio \
  --from "$AUDIO_RELEASE" \
  --dry-run
```

The preview verifies the release receipt, every checksum and size, and the four
compiled destination paths. It does not modify files or require root
privileges.

## 4. Install and reboot

After reviewing the plan, install the verified release explicitly:

```sh
sudo linux-armer userspace install audio \
  --from "$AUDIO_RELEASE" \
  --yes
sudo reboot
```

The installer copies any existing managed target to a timestamped backup below
`/var/lib/linux-armer/backups/userspace`, then publishes the complete four-file
set. It automatically restores already-changed targets if the transaction
fails before completion.

## 5. Validate the migrated system

After reboot, repeat the static check:

```sh
linux-armer doctor userspace --feature audio
```

The expected static state is:

- a compatible Surface kernel generation;
- the exact FullIO v19c topology and three UCM files;
- `soundwire_qcom.sp11_feedback_active_offset2_zero=1` in persistent GRUB
  configuration; and
- no known legacy audio conflict.

If a non-linux-armer installation path omitted the required boot argument, add
it using that distribution's bootloader procedure, regenerate the bootloader
configuration, and reboot. The current CLI reports the omission but does not
change existing bootloader configuration.

Confirm the live kernel received the setting and that PipeWire exposes the
current audio devices:

```sh
grep -o 'soundwire_qcom.sp11_feedback_active_offset2_zero=[^ ]*' /proc/cmdline
cat /sys/module/soundwire_qcom/parameters/sp11_feedback_active_offset2_zero
wpctl status
```

## 6. Complete the manual hardware gate

Set the desktop output volume low before playing a test tone. Keep the speakers
clear and stop immediately if the output is distorted, crackling, or louder
than expected.

```sh
speaker-test -D default -c 2 -t sine -f 440 -s 1 -l 1
speaker-test -D default -c 2 -t sine -f 440 -s 2 -l 1
```

The first test should reach only the left speaker and the second only the right
speaker. This audible check is required because static file and boot-argument
validation cannot prove physical channel routing.

If microphone coverage is required, record a short local sample:

```sh
arecord -D default -f S16_LE -r 48000 -c 2 -d 5 ./sp11-mic-test.wav
```

Treat the recording as private unless it has been reviewed and redacted.

## Recovery and rollback limits

The clean-up transaction and the supported audio installation have separate
recovery boundaries.

Restore recognised legacy workarounds removed by `clean apply` with its exact
receipt:

```sh
sudo linux-armer clean restore \
  <cleanup-receipt> \
  --root / \
  --yes
```

This does not uninstall FullIO v19c. It deliberately restores retired files
and may make the audio doctor fail again.

There is currently no supported `linux-armer userspace uninstall audio`
command. The installer's timestamped backup supports automatic rollback during
a failed transaction, but a successful install does not produce an uninstall
receipt. Do not copy those files back manually without a reviewed procedure
for the exact target state.

Per-user PipeWire or WirePlumber files are also outside `clean` and the audio
installer. If they still affect routing after the static doctor passes, review
them separately and preserve a recoverable copy before making any change.

## References

- [Bring Up Current Surface Pro 11 Audio](how-to-bring-up-audio.md)
- [ADR-0064: SP11 Audio Release Strategy](../adr/adr-0064-sp11-audio-release-strategy.md)
- [ADR-005: Reversible Legacy Clean-up](../../cli/linux-armer/docs/adr/adr-005-reversible-legacy-cleanup.md)
- [linux-armer userspace companion](../../cli/linux-armer/README.md#userspace-companion)
- [Audited userspace catalogue](../../cli/linux-armer/supported-userspace.json)
