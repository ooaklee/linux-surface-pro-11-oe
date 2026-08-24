---
id: how-to-migrate-to-native-audio
title: "How To: Migrate SP11 Audio to the Native v9+ Pairing"
# prettier-ignore
description: How-to guide for migrating from the legacy OE audio workarounds (CRD topology, OE UCM, and PipeWire speaker sink) to the native Golden v32 pairing used by the 7.2.0-jg-0sp11v9/v10 kernel line (canonical topology, geocausa UCM, and native sink), including rollback.
---

# How To: Migrate SP11 Audio to the Native v9+ Pairing

Use this procedure to replace the Surface Pro 11 legacy audio workaround stack
with the userspace pairing required by the `7.2.0-jg-0sp11v9` and
`7.2.0-jg-0sp11v10` kernels.

## Purpose

The v9+ kernel line replaces the OE-built CRD topology, OE-authored
`Surface11-HiFi.conf`, WSA routing enables, and manual PipeWire speaker sink
with geocausa's canonical Golden v32 topology and UCM. WirePlumber then creates
the native `Built-in Audio Pro` sink with the correct stereo mapping and
VI+CPS speaker-protection feedback.

The old `50-sp11-speakers.conf` is fatal on this kernel line. Its target,
`hw:X1E80100Microso,1`, does not exist under the canonical topology, so its
context-level adapter creation makes PipeWire exit with status 234 in a crash
loop. Remove the workaround as part of the pairing migration; do not carry it
forward as a fallback sink.

## Prerequisites

- Surface Pro 11 with either `7.2.0-jg-0sp11v9-qcom-x1e` or
  `7.2.0-jg-0sp11v10-qcom-x1e` installed. See
  [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
  and
  [Repeat Patched Kernel Build for a New qcom-x1e Release](how-to-repeat-kernel-build-for-new-release.md).
- A current `geocausa/SP11X1e-audio` checkout containing
  `deploy/render-parity/X1E80100-Microsoft-Surface-Pro-11-Render-Parity-tplg.bin`
  and `deploy/ucm2/Qualcomm/x1e80100/`.
- `sudo` access for `/lib/firmware` and `/usr/share/alsa/ucm2`.
- The migration script saved with executable mode. From this repository root,
  set it explicitly with `chmod 0755 scripts/sp11-audio-migrate-to-native.sh`.

## Procedure

1. Clone the audio artifacts at the script's default location, or refresh an
   existing checkout.

```bash
git clone https://github.com/geocausa/SP11X1e-audio.git \
  /home/leon/Workspace/repos/SP11X1e-audio

# For an existing checkout instead:
git -C /home/leon/Workspace/repos/SP11X1e-audio pull --ff-only
```

2. Boot the native kernel and confirm its exact release.

```bash
uname -r
```

Continue only with `7.2.0-jg-0sp11v9-qcom-x1e` or
`7.2.0-jg-0sp11v10-qcom-x1e`. The script stops on other releases unless
`--force` is supplied.

3. Preview the migration without writing files or restarting services.

```bash
./scripts/sp11-audio-migrate-to-native.sh --install --dry-run
```

4. Install the native pairing using the default source checkout.

```bash
./scripts/sp11-audio-migrate-to-native.sh --install
```

To use a checkout elsewhere, override both artifact locations:

```bash
./scripts/sp11-audio-migrate-to-native.sh --install \
  --tplg /path/to/SP11X1e-audio/deploy/render-parity/X1E80100-Microsoft-Surface-Pro-11-Render-Parity-tplg.bin \
  --ucm-dir /path/to/SP11X1e-audio/deploy/ucm2/Qualcomm/x1e80100
```

The script verifies the topology's full SHA-256 identity before making a
backup or changing the system.

5. Reboot. This is required even if PipeWire restarts successfully because
   `audioreach_tplg_init` loads `qcom/<card>-tplg.bin` when the sound card
   probes at boot.

```bash
sudo reboot
```

## Expected Output

- The canonical topology is installed at
  `/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`
  with SHA-256
  `1b0c7217fc67bb11da002b06563dd8c411b0f0e35ac40778bff3d65093061c9d`.
- Geocausa's `SP11-HiFi.conf` and `MICROSOFT-Surface-Pro-11.conf` are installed
  under `/usr/share/alsa/ucm2/Qualcomm/x1e80100/`.
- User PipeWire `50-sp11-*.conf` and WirePlumber `51-sp11-*.conf` workaround
  files are removed.
- Pre-migration files are preserved under
  `/var/backups/sp11-audio-native-migration-<YYYYmmdd-HHMMSS>/`, retaining
  their original absolute-path layout below that directory.

## Validation

Confirm that the running kernel is the expected native audio line:

```bash
uname -r
```

This must show the v9 or v10 release. It proves the userspace pairing is being
tested with an allowlisted kernel.

Confirm that WirePlumber created the native sink and did not recreate the
legacy workaround sink:

```bash
wpctl status | grep -A6 Sinks
```

The output must show `Built-in Audio Pro` and must not show
`Surface Pro 11 Speakers`.

Test the physical left and right channels independently at a safe volume:

```bash
speaker-test -D default -c 2 -t sine -f 440 -s 1 -l 1
speaker-test -D default -c 2 -t sine -f 440 -s 2 -l 1
```

The first command must play only the left speaker; the second must play only
the right speaker. This proves the native sink's stereo channel mapping.

Check the protected graph's boot-time probe result:

```bash
sudo dmesg | grep -Ei 'SP11 stage|SPVI|no backend' | tail -15
```

The output must include `SP11 stage SP/SPVI enabled with VI+CPS feedback
accepted` and no `no backend DAIs` message. This proves that the canonical
topology created the protected SP/SPVI graph and its backend routes.

## Privacy and Safety

The script modifies system firmware and UCM paths and removes matching files
from the current user's PipeWire and WirePlumber configuration. It creates a
sudo-owned backup before changing those files and records which migration
outputs did not exist beforehand.

To preview rollback, then restore the newest backup and restart user audio
services, run:

```bash
./scripts/sp11-audio-migrate-to-native.sh --rollback --dry-run
./scripts/sp11-audio-migrate-to-native.sh --rollback
```

Use `--backup-dir /var/backups/sp11-audio-native-migration-<timestamp>` to
select a specific backup. Reboot after rollback so the restored topology is
loaded at card probe.

DMIC capture is not available on this kernel line. The canonical topology
defines no VA/DMIC capture graph, so migrating restores native protected
speaker playback but regresses the internal microphone. This accepted
limitation is tracked in ADR-0062 and
[linux-surface-pro-11-oe issue #48](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/48).

Do not commit the topology binary, backup directory, personal paths beyond the
documented defaults, credentials, or diagnostic archives to this repository.

## Troubleshooting

If the script rejects the kernel release, build and install the v9/v10 kernel,
reboot into it, and retry. Use `--force` only for a kernel independently known
to implement the same native audio interface.

If topology verification fails, refresh `geocausa/SP11X1e-audio` and confirm
that the render-parity artifact has the SHA-256 shown above. Do not install an
unverified topology under the canonical firmware filename.

If PipeWire is not running in a systemd user session, log out and back in after
the migration. A reboot is still required for every topology change.

## References

- [ADR-0062: SP11 7.2.0-jg-0sp11v9 Golden-v32 Audio Kernel Line](../adr/adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line.md)
- [linux-surface-pro-11-oe issue #48](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/48)
- [ooaklee/linux_ms_dev_kit-sp11 PR #17](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/17)
- [`sp11-audio-topology.sh`](../../scripts/sp11-audio-topology.sh) — legacy CRD topology and OE UCM installer
- [`sp11-pipewire-speaker-sink.sh`](../../scripts/sp11-pipewire-speaker-sink.sh) — legacy PipeWire speaker-sink workaround
