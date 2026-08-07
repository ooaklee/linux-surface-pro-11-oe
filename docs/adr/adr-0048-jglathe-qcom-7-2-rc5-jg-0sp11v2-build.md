---
id: adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build
title: "ADR0048: JG 7.2-rc5-jg-0sp11v2 Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v2 (2.4 MHz DMIC) build of Johan G.'s qcom-x1e 7.2-rc5-jg-0 kernel, and the installer DTB-selection fix that makes it authoritative.
---

# ADR0048: JG 7.2-rc5-jg-0sp11v2 Kernel Build

## Status

Accepted (2026-08-02).

Validated by a complete `binary-indep binary-qcom-x1e` Docker build that
produced the `7.2-rc5-jg-0sp11v2-qcom-x1e` kernel packages
(`linux-image`, `linux-modules`, `linux-headers`,
`linux-qcom-x1e-headers`) in `payload/kernel-debs/`, and by device-side
testing: the running kernel reports a 2,400,000 Hz DMIC clock and the
microphone static heard on the plain `7.2-rc5-jg-0` build is gone.

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

### DTB selection regression

The `7.2-rc5-jg-0` install also exposed a latent bug in the installer's
`find_dtb` helper. It ranked candidate builds with `sort -V | tail -n 1`,
which orders `7.2-rc5-jg-0` **after** `7.2-rc5-jg-0sp11v2` (a `sp11v2`
suffix sorts before the plain token). As a result the installer always picked
the plain 4.8 MHz build's DTB and injected it into `/boot/sp11-denali.dtb`,
which GRUB loads for **every** kernel entry. Even after the v2 kernel was
installed, GRUB continued to boot it with the 4.8 MHz DTB, so the static
persisted regardless of which kernel was selected.

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
3. Fix the installer's `find_dtb` so a `sp11v2` build is always preferred when
   it coexists with the plain build. The decision no longer depends on
   lexicographic ordering of version strings; it explicitly selects the
   Surface Pro 11 v2 build when present.

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

The `find_dtb` fix in `scripts/install-sp11-support.sh` prefers a
`sp11v2` build's DTB when one exists:

```bash
# Pick the newest candidate DTB, preferring Surface Pro 11 specific builds.
# The plain jglathe qcom-x1e builds use the upstream 4.8 MHz DMIC clock; the
# SP11 builds (suffixed sp11v2) carry the validated 2.4 MHz clock. Plain sort -V
# ranks the sp11v2 suffix below the plain name, so prefer it explicitly.
pick_dtb() {
  local sp11
  sp11="$(printf '%s\n' "$@" | grep -E 'sp11v2' || true)"
  if [ -n "$sp11" ]; then
    printf '%s\n' "$sp11" | sort -V | tail -n 1
  else
    printf '%s\n' "$@" | sort -V | tail -n 1
  fi
}
```

The chosen DTB is copied to `/boot/sp11-denali.dtb` and injected as
`devicetree /sp11-denali.dtb` in every GRUB kernel entry.

## Consequences

- The v2 kernel reports a live DMIC clock of 2,400,000 Hz and captured speech
  is clear; the 4.8 MHz static is gone.
- GRUB now boots the v2 kernel with the correct 2.4 MHz DTB even though
  `/boot/sp11-denali.dtb` is shared across all kernel entries.
- The plain `7.2-rc5-jg-0` ABI remains co-installable as a rollback option but
  is no longer the recommended Surface Pro 11 kernel.
- The installer's DTB selection is now deterministic and correct when multiple
  Surface Pro 11 kernel builds are installed side by side.
