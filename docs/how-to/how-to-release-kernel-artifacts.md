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

If the kernel was built with the Docker workflow, the named build volume can be
used to create a local source archive. One draft pattern is:

```bash
mkdir -p build/release-source

docker run --rm --platform linux/arm64 \
  -v sp11-qcom-x1e-kernel-build:/linux-work:ro \
  -v "$PWD/build/release-source:/out" \
  ubuntu:25.10 \
  bash -lc '
    cd /linux-work/source/git-qcom-x1e-7.0
    tar --exclude=.git -caf /out/sp11-qcom-x1e-7.0.0-22.22-rfkill1-patched-source.tar.xz .
  '
```

Before publishing, review that archive for the intended source state. The
helper can enforce that a source file exists, but it cannot prove the source
asset is legally or technically sufficient.

4. Prepare release assets.

```bash
./scripts/prepare-sp11-kernel-release-assets.sh \
  --release-name sp11-qcom-x1e-7.0.0-22.22-rfkill1 \
  --source-asset build/release-source/sp11-qcom-x1e-7.0.0-22.22-rfkill1-patched-source.tar.xz
```

The helper writes an ignored directory under:

```text
build/release/<release-name>/
```

It refuses to publish source-less output. Use `--allow-missing-source` only for
local rehearsal, never for a public binary release.

5. Review the generated release directory.

```bash
find build/release/sp11-qcom-x1e-7.0.0-22.22-rfkill1 -maxdepth 1 -type f -print | sort
sed -n '1,220p' build/release/sp11-qcom-x1e-7.0.0-22.22-rfkill1/sp11-kernel-release-manifest.txt
sed -n '1,220p' build/release/sp11-qcom-x1e-7.0.0-22.22-rfkill1/RELEASE-NOTES.md
```

Check that the directory contains:

- the three qcom-x1e `.deb` packages,
- `SHA256SUMS`,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- the corresponding source asset,
- `RELEASE-NOTES.md`.

6. Verify checksums from inside the generated release directory.

```bash
cd build/release/sp11-qcom-x1e-7.0.0-22.22-rfkill1
shasum -a 256 -c SHA256SUMS
cd -
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

Run the generated `gh release create ... --prerelease ...` command only after
the source, checksum, privacy, and release-note reviews pass.

9. Verify the published release.

```bash
gh release view sp11-qcom-x1e-7.0.0-22.22-rfkill1 --json tagName,isPrerelease,assets
```

Confirm the release is marked as a prerelease and that every uploaded binary or
source asset is listed in `SHA256SUMS`.

## Expected Output

The local release directory should contain a flat asset set:

- `linux-headers-<abi>_<version>_arm64.deb`,
- `linux-image-<abi>_<version>_arm64.deb`,
- `linux-modules-<abi>_<version>_arm64.deb`,
- `SHA256SUMS`,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- one or more corresponding source assets,
- `RELEASE-NOTES.md`.

The published GitHub release should include the `.deb` packages, checksums,
manifests, and source assets. `RELEASE-NOTES.md` should normally be used as the
release body rather than uploaded as a separate asset.

## Validation

Run these checks before publishing:

```bash
git status --short
shasum -a 256 -c build/release/<release-name>/SHA256SUMS
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
