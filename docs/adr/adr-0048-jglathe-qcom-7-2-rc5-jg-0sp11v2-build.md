---
id: adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build
title: "ADR0048: JG 7.2-rc5-jg-0sp11v2 Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v2 (2.4 MHz DMIC) build of Johan G.'s qcom-x1e 7.2-rc5-jg-0 kernel and its exact Stubble-embedded DTB.
---

# ADR0048: JG 7.2-rc5-jg-0sp11v2 Kernel Build

## Status

Accepted (2026-08-02).

Corrected (2026-08-07): the original analysis below attributed the active
2.4 MHz value to GRUB's shared loose DTB. Earlier live-FDT testing in
[ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md) instead established
that the tested Stubble boot path uses the DTB embedded in each packaged
kernel image. [ADR-0055](adr-0055-retire-installed-loose-dtb-injection.md)
retires installed shared loose-DTB selection and injection. Any existing
`/boot/sp11-denali.dtb` is inert evidence and is not evidence of the live
device tree. The successful v2 result remains valid because its packaged
Stubble image embeds the 2.4 MHz Denali DTB.

Validated by a complete `binary-indep binary-qcom-x1e` Docker build that
produced the `7.2-rc5-jg-0sp11v2-qcom-x1e` kernel packages
(`linux-image`, `linux-modules`, `linux-headers`,
`linux-qcom-x1e-headers`) in `payload/kernel-debs/`, and by device-side
testing: the running kernel's active device tree requests a 2,400,000 Hz DMIC
rate and the microphone static heard on the plain `7.2-rc5-jg-0` build is
gone. The property is not a physical clock measurement at the microphone
pins.

## Context

[ADR-0047](adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md) introduced the plain
`7.2-rc5-jg-0` build from Johan G.'s `jg/ubuntu-qcom-x1e-7.2rc` branch. That
branch carries the Surface Pro 11 Wi-Fi `disable-rfkill` change and the Denali
DTB `disable-rfkill;` node upstream, so no local rfkill or DTS patches were
needed.

However, the upstream branch configures the Denali VA macro at
`qcom,dmic-sample-rate = <4800000>` (4.8 MHz), which reintroduces the
continuous broadband microphone static that the 7.1.3 v2 kernel
([ADR-0046](adr-0046-sp11-default-2p4mhz-dmic-clock.md)) had eliminated. The
7.2-rc5-jg-0 release notes explicitly warned that the 4.8 MHz clock could
reintroduce static and pointed users back to 7.1.3 v2.

### Legacy loose-DTB selection regression

The `7.2-rc5-jg-0` install also exposed a latent bug in the installer's
legacy `find_dtb` helper. It ranked candidate builds with
`sort -V | tail -n 1`, which orders `7.2-rc5-jg-0` **after**
`7.2-rc5-jg-0sp11v2` (a `sp11v2` suffix sorts before the plain token). The
helper therefore copied the plain 4.8 MHz build's DTB to the shared
`/boot/sp11-denali.dtb`. That was an incorrect compatibility fallback, but it
did not establish which DTB the kernel actually consumed. The original claim
that this shared file caused the live 4.8 MHz value is superseded by the
embedded-DTB evidence above.

## Decision

Build the `sp11v2` (2.4 MHz DMIC) variant of the 7.2-rc5-jg-0 baseline and
make it the standard Surface Pro 11 kernel:

1. Apply `patches/sp11-qcom-x1e-7.2-rc5-v2` after
   `patches/jglathe-qcom-x1e-7.2-rc5`. The set restores the validated 2.4 MHz
   Denali DMIC clock and gives the result the distinct Debian ABI
   `7.2-rc5-jg-0sp11v2`, preserving the plain `7.2-rc5-jg-0` packages as a
   co-installable rollback option.
2. Keep the plain `7.2-rc5-jg-0` build-policy support (annotations
   compatibility patch, `ubuntu:26.04` image, explicit version tokens) from
   [ADR-0047](adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md); the v2 patch set is
   layered on top of it.
3. Use only the DTB embedded in the exact Stubble-wrapped v2 image for the
   installed kernel's device-tree pairing. Do not select, copy, inject, or
   maintain a shared loose DTB for this tested path. If the historical
   `/boot/sp11-denali.dtb` exists, leave it untouched and inert.

## Decision details

The Docker build:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

The support installer retires the former `sp11-grub-inject-dtb` helper and its
kernel hooks. On the live root it uses normal GRUB generation and propagates
`update-grub` failures; an offline-root operation does not execute target
binaries or modify the target `grub.cfg`. Installed qcom-x1e DTB provenance
comes from the exact Stubble EFI image and the active FDT after boot.

## Consequences

- The v2 kernel's active device tree requests a 2,400,000 Hz DMIC clock and
  captured speech is clear; the 4.8 MHz static is gone.
- The v2 Stubble image embeds its own validated 2.4 MHz DTB. An older shared
  loose DTB, if present, remains inert and must not be used to infer live-FDT
  provenance or as a fallback guarantee.
- The plain `7.2-rc5-jg-0` ABI remains co-installable as a rollback option but
  is no longer the recommended Surface Pro 11 kernel.
- Co-installed Surface Pro 11 ABIs retain exact kernel/DTB pairing through
  their individual Stubble-wrapped images rather than a shared mutable file.
