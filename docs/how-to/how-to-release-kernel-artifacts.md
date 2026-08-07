---
id: how-to-release-kernel-artifacts
title: "Release Prebuilt Kernel Artifacts"
# prettier-ignore
description: How-to guide for preparing optional Surface Pro 11 qcom-x1e kernel release assets with checksums, provenance, and source artifacts.
---

# How To: Release Prebuilt Kernel Artifacts

Use this procedure to prepare an optional GitHub prerelease containing prebuilt
Surface Pro 11 qcom-x1e kernel `.deb` packages.

## Purpose

Building the patched qcom-x1e kernel can take more than an hour on a capable
ARM64 host. A prerelease lets users download the same experimental package set
without rebuilding it, while keeping large binaries out of git.

This procedure follows [ADR026](../adr/adr-0026-prebuilt-kernel-release-artifacts.md):

- publish `.deb` packages as GitHub Release assets, not git-tracked files,
- keep `payload/kernel-debs/` as local USB staging only,
- include `SHA256SUMS`, sanitized manifests, and corresponding source assets,
- do not publish proprietary firmware, Windows driver extracts, diagnostics,
  service reports, or hardware identifiers.

## Prerequisites

- A clean repository checkout on the release branch.
- Built qcom-x1e kernel `.deb` files in `payload/kernel-debs/`.
- Build artifacts under `build/docker-sp11-qcom-x1e-kernel/artifacts/`, if
  available.
- Corresponding source assets for the binary packages. Use Debian source
  package artifacts for apt-source builds, or a patched source archive for
  git-fallback builds.
- For an `sp11v3` release, the exact-ABI `gpi.ko`, `spi-geni-qcom.ko`, and
  `mshw0485_touch.ko` bundle produced by
  `scripts/build-sp11-touchscreen-modules.sh`, including its build manifest.
- GitHub CLI (`gh`) authenticated for the target repository.
- A human review that the selected source assets are sufficient for the binary
  packages being released.

## Procedure

1. Confirm the repository is clean.

```bash
git status --short
```

Continue only when this prints nothing. The release helper refuses dirty
repositories by default so the manifest cannot point at a commit that does not
contain the release instructions, patch state, or helper behavior.

2. Confirm the package payload contains exactly one matching headers, image,
   and modules package.

```bash
find payload/kernel-debs -maxdepth 1 -type f -name '*.deb' -print | sort
```

Expected package shape:

```text
payload/kernel-debs/linux-headers-<abi>_<version>_arm64.deb
payload/kernel-debs/linux-image-<abi>_<version>_arm64.deb
payload/kernel-debs/linux-modules-<abi>_<version>_arm64.deb
```

3. Prepare or identify the corresponding source assets.

For apt-source builds, prefer Debian source package artifacts such as:

```text
linux-qcom-x1e_<version>.dsc
linux-qcom-x1e_<version>.orig.tar.*
linux-qcom-x1e_<version>.debian.tar.*
```

For git-fallback builds, use a patched source archive or another durable source
asset that contains the exact upstream source plus the project patches used for
the binary release.

If the kernel was built with the Docker workflow, create the source archive
from the tracked files in the patched worktree. Do not archive the whole
post-build directory: it also contains generated objects and packaging output
that are not corresponding source and can make the archive too large to
publish.

For the fresh `7.2-rc5-jg-0sp11v3` build, the source worktree is in the named
Docker volume used by the build command. The following command verifies the
immutable upstream commit and the expected patched tracked-file set, then
archives only files known to git. The volume is mounted read-only:

```bash
mkdir -p build/release-source

docker run --rm --platform linux/arm64 \
  -v sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3-r1:/linux-work:ro \
  -v "$PWD/build/release-source:/out" \
  ubuntu:26.04 \
  bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export XZ_OPT="-T0 -6"
    apt-get update
    apt-get install -y --no-install-recommends git tar xz-utils

    source_dir=/linux-work/source/git-jg-ubuntu-qcom-x1e-7.2-rc5-jg-0
    archive_root=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1-patched-source
    cd "$source_dir"

    test "$(git rev-parse HEAD)" = \
      8f953dd060bc6e8fb86ca2ea8a92f258141c0169
    git diff --check
    test "$(git diff --name-only HEAD)" = "$(printf "%s\n" \
      arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi \
      debian.qcom-x1e/changelog \
      debian.qcom-x1e/config/annotations)"
    test "$(git -c core.abbrev=40 diff --binary --full-index HEAD | \
      sha256sum | cut -d " " -f 1)" = \
      96004d57880b7827537f90c8820cdd46a9687519d669342f81d39e73d4b4c02b

    git ls-files -z | tar \
      --null \
      --verbatim-files-from \
      --no-recursion \
      --files-from=- \
      --format=gnu \
      --sort=name \
      --mtime=@0 \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --transform="flags=r;s|^|$archive_root/|" \
      -cJf "/out/$archive_root.tar.xz"
  '
```

Review the archive before publishing. It must have one top-level directory,
must not contain `.git`, and must contain the patched versions of the three
tracked files checked above. The helper can enforce that a source file exists,
but it cannot prove the source asset is legally or technically sufficient.

For an `sp11v3` release, build the touchscreen bundle against the release ABI
and preserve the generated provenance manifest:

```bash
./scripts/build-sp11-touchscreen-modules.sh \
  --release 7.2-rc5-jg-0sp11v3-qcom-x1e \
  --out-dir build/sp11v3-touchscreen-modules-final
```

4. Prepare release assets.

```bash
./scripts/prepare-sp11-kernel-release-assets.sh \
  --release-name sp11-qcom-x1e-7.0.0-22.22-rfkill1 \
  --source-asset build/release-source/sp11-qcom-x1e-7.0.0-22.22-rfkill1-patched-source.tar.xz
```

An `sp11v3` release must also supply the ABI-matched module directory and its
immutable source provenance. The original v3 tag is retired and must not be
reused. The fresh corrective release keeps the package ABI
`7.2-rc5-jg-0sp11v3` but uses the new immutable release tag
`sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1`:

```bash
./scripts/prepare-sp11-kernel-release-assets.sh \
  --kernel-debs-dir payload/kernel-debs \
  --artifacts-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3-r1/artifacts \
  --patch-dir patches/jglathe-qcom-x1e-7.2-rc5 \
  --patch-dir patches/sp11-qcom-x1e-7.2-rc5-v3 \
  --release-name sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1 \
  --source-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --source-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --docker-image ubuntu:26.04 \
  --source-asset build/release-source/sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1-patched-source.tar.xz \
  --touchscreen-modules-dir build/sp11v3-touchscreen-modules-final \
  --touchscreen-source-url https://github.com/geocausa/SP11X1e-touchscreen.git \
  --touchscreen-source-ref 6bbcf7a4759a73014047a57e819219dd7f34951a
```

Repeat `--patch-dir` in the same order used for the kernel build. The release
manifest must list all four applied patches: the Johan G. annotation update
and the three Surface Pro 11 v3 patches. Supplying only the v3 directory makes
the source provenance incomplete.

The helper writes an ignored directory under:

```text
build/release/<release-name>/
```

It refuses to publish source-less output. Use `--allow-missing-source` only for
local rehearsal, never for a public binary release.

5. Review the generated release directory.

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1
find "build/release/$TAG" -maxdepth 1 -type f -print | sort
sed -n '1,220p' "build/release/$TAG/sp11-kernel-release-manifest.txt"
sed -n '1,220p' "build/release/$TAG/RELEASE-NOTES.md"
```

Check that the directory contains:

- the qcom-x1e `.deb` packages (three for standard builds, four for jglathe),
- `SHA256SUMS`,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- the corresponding source asset,
- for `sp11v3`, all three touchscreen modules and
  `sp11-touchscreen-modules-manifest.txt`,
- `RELEASE-NOTES.md`.

6. Verify checksums from inside the generated release directory.

```bash
(cd build/release/sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1 && \
  shasum -a 256 -c SHA256SUMS)
```

Then run the semantic validator. It checks package identities, exact asset and
checksum coverage, tag provenance, module metadata, and the packaged Denali
OLED touchscreen device tree:

```bash
./scripts/validate-sp11-touchscreen-release.sh \
  --dir build/release/<release-name> \
  --tag <release-name> \
  --remote origin
```

For a pre-tag local rehearsal, omit `--tag` and `--remote`. Run the full command
after creating the tag and again against a fresh directory containing exactly
the downloaded release assets. If `gh release create` created a new remote tag,
fetch that exact tag before invoking the validator, which checks both its local
and remote targets:

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1
git fetch origin "refs/tags/$TAG:refs/tags/$TAG"

./scripts/validate-sp11-touchscreen-release.sh \
  --dir build/release/$TAG \
  --tag "$TAG" \
  --remote origin
```

7. Review the generated publish command.

The helper prints a `gh release create` command when source assets are present.
It uses `RELEASE-NOTES.md` as `--notes-file` and uploads the generated assets
named by the command, including `SHA256SUMS`. `RELEASE-NOTES.md` becomes the
release body rather than a separate uploaded asset unless you deliberately add
it to the command.

Do not add extra assets to the command unless you also regenerate
`SHA256SUMS` and verify the files are safe to publish.

8. Publish as a prerelease.

Run the generated `gh release create ... --target <support-commit>
--prerelease ...` command only after the source, checksum, privacy, and
release-note reviews pass. The target must be the clean support commit recorded
in both generated manifests; never let GitHub infer the default branch tip.

The project owner authorized the fresh r1 kernel and image as explicitly
experimental prereleases while the complete clean-install hardware matrix is
still outstanding. This exception does not make either artifact
hardware-qualified and does not waive the clean-install gate for a stable or
promoted release. The release notes must disclose that distinction and retain
the fallback-kernel and recovery-media requirements.

9. Verify the published release.

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1
gh release view "$TAG" \
  --json tagName,targetCommitish,isPrerelease,assets

download_dir="$(mktemp -d)"
gh release download "$TAG" \
  --repo ooaklee/linux-surface-pro-11-oe \
  --dir "$download_dir"
git fetch origin "refs/tags/$TAG:refs/tags/$TAG"

./scripts/validate-sp11-touchscreen-release.sh \
  --dir "$download_dir" \
  --tag "$TAG" \
  --remote origin
```

Confirm the release is marked as a prerelease and that every uploaded binary or
source asset is listed in `SHA256SUMS`. Confirm the remote tag resolves to the
manifest support commit. Download the assets into a new empty directory, fetch
the new tag locally, and rerun `validate-sp11-touchscreen-release.sh` with
`--tag` and `--remote origin`.

## Expected Output

The local release directory should contain a flat asset set:

- `linux-headers-<abi>_<version>_arm64.deb`,
- `linux-image-<abi>_<version>_arm64.deb`,
- `linux-modules-<abi>_<version>_arm64.deb`,
- `SHA256SUMS`,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- one or more corresponding source assets,
- for `sp11v3`, `gpi.ko`, `spi-geni-qcom.ko`, `mshw0485_touch.ko`, and their
  provenance manifest,
- `RELEASE-NOTES.md`.

For the fresh r1 release, the exact upload set is:

```text
linux-headers-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb
linux-image-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb
linux-modules-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb
linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3_7.2-rc5-jg-0sp11v3_all.deb
gpi.ko
spi-geni-qcom.ko
mshw0485_touch.ko
sp11-touchscreen-modules-manifest.txt
sp11-kernel-release-manifest.txt
sp11-kernel-debs.txt
sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1-patched-source.tar.xz
SHA256SUMS
```

`RELEASE-NOTES.md` is the GitHub release body and is not an uploaded asset.

The published GitHub release should include the `.deb` packages, checksums,
manifests, and source assets. `RELEASE-NOTES.md` should normally be used as the
release body rather than uploaded as a separate asset.

## Validation

Run these checks before publishing:

```bash
git status --short
shasum -a 256 -c build/release/<release-name>/SHA256SUMS
./scripts/validate-sp11-touchscreen-release.sh --dir build/release/<release-name>
rg -n "/Users/|/home/|Workspace|GH_TOKEN|GITHUB_TOKEN|API_TOKEN|password|secret|BSSID|SSID|([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" \
  build/release/<release-name> README.md docs scripts
```

Passing validation means the local assets are internally consistent, the
repository state is clean, and common private paths, credentials, Wi-Fi scan
details, and hardware-address patterns were not found.

It does not prove that the source asset is legally sufficient. That still
requires human review before publishing.

## Privacy and Safety

Never commit generated release assets. `build/`, `payload/kernel-debs/`, and
`*.deb` are ignored intentionally.

Before publishing, check that release assets do not include:

- proprietary firmware blobs or Windows driver-store files,
- service reports, raw diagnostics, or screenshots with private data,
- local workstation paths,
- SSIDs, BSSIDs, MAC addresses, UUIDs, serial numbers, or account names,
- private apt source files or authenticated repository URLs,
- unsupported claims of bit-for-bit reproducibility.

Prebuilt kernel packages are experimental and unsigned. Keep a known-good
fallback qcom-x1e kernel installed on the Surface Pro 11 and keep recovery
media available.

## Troubleshooting

If the helper refuses a dirty repository, commit or stash changes and rerun it.
Use `--allow-dirty` only for local draft rehearsals.

If the helper refuses missing source assets, provide one or more
`--source-asset` values. Do not use `--allow-missing-source` for a public
binary release.

If the helper refuses the output directory, use the default
`build/release/<release-name>/` layout. The helper intentionally rejects
path traversal, dot-prefixed names, symlinked release roots, and outputs
outside `build/release/`.

If GitHub rejects an upload, confirm the asset size and retry with a fresh
release tag. Do not move large binary packages into git as a fallback.

## Related Documents

- [ADR026: Prebuilt Kernel Release Artifacts](../adr/adr-0026-prebuilt-kernel-release-artifacts.md)
- [How To: Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
