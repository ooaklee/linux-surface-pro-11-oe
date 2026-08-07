---
id: adr-0047-jglathe-qcom-7-2-rc5-jg-0-build
title: "ADR0047: JG 7.2-rc5-jg-0 Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for building Johan G.'s immutable qcom-x1e 7.2-rc5-jg-0 kernel baseline with this repository's Docker kernel builder.
---

# ADR0047: JG 7.2-rc5-jg-0 Kernel Build

## Status

Accepted (2026-08-02).

Validated by a complete `binary-indep binary-qcom-x1e` Docker build that
produced the `7.2-rc5-jg-0-qcom-x1e` kernel packages
(`linux-image`, `linux-modules`, `linux-headers`,
`linux-qcom-x1e-headers`) in `payload/kernel-debs/`.

## Context

Johan G. published a new qcom-x1e kernel baseline at
`7.2-rc5-jg-0` (tag `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`, branch
`jg/ubuntu-qcom-x1e-7.2rc`). Unlike the 7.1.x series, this branch:

- already carries the Surface Pro 11 Wi-Fi `disable-rfkill` ath12k change and
  the Denali DTB `disable-rfkill;` node upstream, so no rfkill or DTS patches
  are needed;
- already uses the packaged Stubble paths (`/usr/lib/stubble`,
  `/usr/share/stubble`) in `debian/rules.d`, so the [ADR-0037](adr-0037-jglathe-qcom-7-1-1-stubble-paths.md)
  path-fix patch is not needed;
- records rustc 1.93.1 / LLVM 21.1.8 in its annotations, which already match
  the `ubuntu:26.04` build toolchain, so the toolchain-drift part of
  [ADR-0043](adr-0043-jglathe-qcom-7-1-3-jg-1-build-reproducibility.md) does
  not apply.

The only remaining build-policy gap is the `CONFIG_VERSION_SIGNATURE` value,
which the regenerate helper refreshes into
`patches/jglathe-qcom-x1e-7.2-rc5/0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch`.

### Branch naming deviation

The branch is named `jg/ubuntu-qcom-x1e-7.2rc`, which does **not** encode the
full kernel version `7.2-rc5-jg-0`. The annotations regeneration helper
derives the version token and base version from the branch name
(`jg/ubuntu-qcom-x1e-<base>-jg-<n>`), so this branch would have produced a
wrong token. The helper therefore gained explicit `--version-token` and
`--base-version` options.

## Decision

Build the immutable tag with the existing Docker flow and verify its full
source commit before applying patches:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dir patches/jglathe-qcom-x1e-7.2-rc5 \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc \
  --copy-to-payload \
  --reset-source
```

The image default for all `jg/ubuntu-qcom-x1e-*` branches is now
`ubuntu:26.04`, matching the `gcc-15` requirement in the kernel's
`debian/rules.d/0-common-vars.mk`.

Touchscreen patches are intentionally excluded; the experimental
`sp11-touchscreen` HID-SPI series does not apply cleanly to 7.2-rc5, and
runtime touchscreen support was not working on 7.1.3 (see
[ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md)).

## Regenerating the annotations patch

Run the helper with explicit version tokens, since the branch name does not
encode them:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --version-token 7.2-rc5-jg-0 \
  --base-version 7.2-rc5 \
  --reset-source
```

The regenerated patch only changes `CONFIG_VERSION_SIGNATURE`. That symbol is
in `SKIP_CONFIGS` in `debian/scripts/misc/kconfig/run.py`, so it is not
compared by `check-config`; the patch is retained for consistency with the
real build's injected signature.

## Consequences

- The 7.2-rc5-jg-0 kernel builds cleanly with no rfkill/DTS/stubble patches.
- The regenerate helper accepts branch names that do not follow the
  `<base>-jg-<n>` convention.
- No further patches are required for a core Wi-Fi-capable build; only the
  annotations compatibility patch lives in `patches/jglathe-qcom-x1e-7.2-rc5/`.
