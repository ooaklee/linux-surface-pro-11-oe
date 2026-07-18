---
id: adr-0045-sp11-2p4mhz-dmic-clock-test-kernel
title: "ADR0045: Surface Pro 11 2.4 MHz DMIC Clock Test Kernel"
# prettier-ignore
description: Architecture Decision Record (ADR) for rebuilding the Surface Pro 11 Stubble-wrapped kernel with a 2.4 MHz digital microphone clock as a co-installable test kernel.
---

# ADR0045: Surface Pro 11 2.4 MHz DMIC Clock Test Kernel

## Status

Accepted (2026-07-18).

The package build and target comparison are validated. ADR-0046 adopts 2.4 MHz
as the Surface Pro 11 default; this ADR remains the record of the isolated test
kernel and its build procedure.

## Context

The Surface Pro 11 internal microphone path now records intelligible
two-channel audio, but quiet-room recordings contain persistent broadband
static. Raw ALSA recordings reproduce the noise, and changes to UCM gain,
decoder mode, PipeWire filtering, and WebRTC noise suppression did not remove
it without unacceptable loss of voice quality.

The Denali device tree configures the VA codec with:

```dts
qcom,dmic-sample-rate = <4800000>;
```

A 2.4 MHz DMIC clock is the next hardware-level comparison. Earlier attempts
to replace a loose DTB under `/boot`, load one through GRUB, or copy one to the
EFI System Partition did not change the live device tree. As established by
[ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md), this kernel's
Stubble EFI image contains the authoritative device tree. A useful experiment
therefore has to rebuild the complete `linux-image` package with the modified
Denali DTB embedded by `ukify`.

Installing that experiment under the same ABI as the working kernel would
overwrite its image and modules. The clock test must remain independently
installable and removable so the known-good kernel is always available.

## Decision

Add `patches/sp11-dmic-2p4mhz` as a second patch source layered after the JG
7.1.3 compatibility patches. Its first patch changes only the Denali DMIC
sample rate from 4.8 MHz to 2.4 MHz. Its second patch gives the build the
distinct Debian version and ABI token `7.1.3-jg-1dmic2p4` and updates
`CONFIG_VERSION_SIGNATURE` to match.

Build all four package roles with `binary-indep binary-qcom-x1e`. The image
package is therefore named:

```text
linux-image-7.1.3-jg-1dmic2p4-qcom-x1e
```

Use a dedicated Docker work volume and artifact directory so the experiment
does not reuse or overwrite the normal 7.1.3-jg-1 build output:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.1.3 patches/sp11-dmic-2p4mhz" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.3-dmic-2p4mhz \
  --linux-work-volume sp11-qcom-x1e-kernel-build-dmic-2p4mhz \
  --reset-source \
  --jobs 4
```

Do not use `--copy-to-payload` for this experimental build. The repository
payload remains pinned to the tested general-purpose kernel rather than a
single-purpose audio experiment.

Keep `7.1.3-jg-1-qcom-x1e` installed while testing. The clock experiment is
not a replacement kernel until target recordings demonstrate a clear benefit
without regressions.

## Alternatives Considered

**Replace a loose DTB at boot (rejected).** The Stubble-wrapped EFI image
provides the live DTB, so GRUB and filesystem DTB replacements do not exercise
the changed property.

**Reuse the `7.1.3-jg-1` ABI (rejected).** This would overwrite the known-good
kernel's files and make rollback unnecessarily fragile.

**Change the repository payload immediately (rejected).** The 2.4 MHz clock
has not yet been evaluated on the target. Shipping it as the default before
recording comparison data would turn an isolated diagnostic into an
unvalidated product change.

**Build only the image package (rejected).** Building the complete package set
keeps image, modules, and headers version-aligned and follows the already
validated JG build path.

## Consequences

- The clock experiment can be installed beside the working 7.1.3-jg-1 kernel.
- The ABI token makes the experimental purpose visible in package names,
  `/boot`, and `/usr/lib/modules`.
- The separate Docker volume prevents stale source or packages from another
  kernel build contaminating the result.
- The build takes the full kernel-package path because that is the only path
  that updates the authoritative Stubble-embedded DTB.
- A successful package build proves that the intended DTB is packaged; it
  does not prove that 2.4 MHz improves microphone capture.

## Validation

The completed build satisfied all of the following before target installation:

1. Ubuntu's `check-config` stage completed successfully.
2. The four image, modules, flavour-header, and common-header package roles
   use version `7.1.3-jg-1dmic2p4`.
3. The packaged
   `x1e80100-microsoft-denali-oled.dtb` reports
   `qcom,dmic-sample-rate = 2400000`.
4. Stubble construction uses that packaged Denali DTB as its device tree.

The four generated packages are:

- `linux-image-7.1.3-jg-1dmic2p4-qcom-x1e`
- `linux-modules-7.1.3-jg-1dmic2p4-qcom-x1e`
- `linux-headers-7.1.3-jg-1dmic2p4-qcom-x1e`
- `linux-qcom-x1e-headers-7.1.3-jg-1dmic2p4`

Package metadata reports version `7.1.3-jg-1dmic2p4`; the three
flavour-specific packages are ARM64 and the common headers package is
architecture-independent. Extracting the packaged Denali OLED DTB and reading
the live property path with `fdtget` returned `2400000`. The build log also
records `ukify build` with that Denali DTB supplied through
`--devicetree-auto`.

Target validation confirmed the running test release and a live value of
`2400000`. Compared with the 4.8 MHz kernel, the continuous feedback/static
was no longer audible and recorded speech was dramatically clearer, although
it retained a slightly tinny character. Music playback showed no audible
degradation. ADR-0046 records the decision and full device-side evidence.

## Related

- [ADR-0042: Touchscreen — Kernel Integration Troubleshooting and Remaining Blockers](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR-0043: Reproducible JG 7.1.3-jg-1 Kernel Builds](adr-0043-jglathe-qcom-7-1-3-jg-1-build-reproducibility.md)
- [ADR-0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels](adr-0044-sp11-ucm-single-wsa-macro-microphone.md)
- [ADR-0046: Default the Surface Pro 11 DMIC Clock to 2.4 MHz](adr-0046-sp11-default-2p4mhz-dmic-clock.md)
- [`patches/sp11-dmic-2p4mhz/README.md`](../../patches/sp11-dmic-2p4mhz/README.md)
