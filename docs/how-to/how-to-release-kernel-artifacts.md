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

> **Current publication gate:** closed for newly built artifacts. Release mode
> now emits a schema-v2 kernel manifest plus the
> `sp11-kernel-apt-provenance-v1` sidecar and
> `sp11-kernel-build-inputs-v1` envelope. The release and image preparers do
> not yet consume the envelope. Complete the build/evidence inspection below,
> but do not prepare, upload, or publish a new prerelease until a later schema
> propagates and validates all three artifacts. The signing policy is also
> still open. This is not an exhaustive blocker list: P0.3 independently keeps
> publication at **NO-PUBLISH** until the repository owner documents the
> project-code licence boundary and resolves UCM provenance.

## Prerequisites

- A clean repository checkout on the release branch.
- Enough disk space and an ARM64 Docker environment for the fresh release-mode
  build performed below. Its package set, v2 kernel manifest, v1 APT sidecar,
  v1 build-inputs envelope, and retained APT inputs must all come from the same
  `--release-build` run.
- A patched source archive for the current, Git-source schema-v2 release path.
  Debian source-package artifacts remain a possible future corresponding-source
  route, but the current release-build and preparation gates do not accept an
  apt-source build as publishable provenance.
- For an `sp11v3` release, a separate exact-commit source archive containing
  the touchscreen modules' licence, build files, C sources, and relative
  headers. An upstream link is useful provenance but is not a substitute for
  shipping corresponding source with the module binaries.
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

2. Reserve a fresh host work directory and Linux Docker volume. Do not seed
   either one from `payload/kernel-debs/` or a prior build. The next step
   creates and inspects the exact packages that will be released.

3. Prepare or identify the corresponding source assets.

If a future schema-v2 gate adds apt-source release support, its corresponding
source set should use Debian source package artifacts such as:

```text
linux-qcom-x1e_<version>.dsc
linux-qcom-x1e_<version>.orig.tar.*
linux-qcom-x1e_<version>.debian.tar.*
```

That is not the current path. Current publication uses Git source and requires
the exact patched-tree archive described below; another durable link or a
checkout assembled from instructions is not a substitute.

Before preparing a future release, rerun the pinned kernel build command from
[How To: Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
with `--release-build`. A normal or historical build manifest is not
publishable. Do not try to recreate or re-prepare the already-published r1
artifacts with the current helper; r1 is immutable historical output created
before the schema-v2 gate. Use one new host artifact directory and one new
Linux Docker volume for the whole future release workflow:

```bash
RELEASE_WORK_DIR=build/docker-sp11-qcom-x1e-kernel-release-r2
LINUX_WORK_VOLUME=sp11-qcom-x1e-kernel-release-r2
ARTIFACTS_DIR="$RELEASE_WORK_DIR/artifacts"
RELEASE_SOURCE_DIR=build/release-source/release-r2
TOUCH_MODULES_DIR=build/release-r2-touchscreen-modules
TOUCH_BUILD_SOURCE="$RELEASE_SOURCE_DIR/SP11X1e-touchscreen-build"
RELEASE_ABI=7.2-rc5-jg-0sp11v3-qcom-x1e
BUILD_IMAGE=ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03

test ! -e "$RELEASE_WORK_DIR"
test ! -e "$RELEASE_SOURCE_DIR"
test ! -e "$TOUCH_MODULES_DIR"
if docker volume inspect "$LINUX_WORK_VOLUME" >/dev/null 2>&1; then
  echo "Choose a new LINUX_WORK_VOLUME; this one already exists." >&2
  exit 1
fi
mkdir -p "$RELEASE_SOURCE_DIR"

./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image "$BUILD_IMAGE" \
  --platform linux/arm64/v8 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir "$RELEASE_WORK_DIR" \
  --linux-work-volume "$LINUX_WORK_VOLUME" \
  --reset-source \
  --release-build \
  --jobs 8
```

After the build, require and inspect the complete provenance trio:

```bash
test -f "$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
test -f "$ARTIFACTS_DIR/sp11-kernel-apt-provenance.txt"
test -f "$ARTIFACTS_DIR/sp11-kernel-build-inputs.txt"
grep -Fx 'APT provenance complete: true' \
  "$ARTIFACTS_DIR/sp11-kernel-apt-provenance.txt"
grep -Fx 'Publication schema propagation: incomplete' \
  "$ARTIFACTS_DIR/sp11-kernel-build-inputs.txt"
```

The final `grep` is an intentional publication stop condition, not a waiver.
Preserve the work directory and complete only the evidence/source inspection
in the remainder of step 3. Steps 4 onward describe the intended flow after
release/image schema propagation is implemented; they are not authorized for
the current v1 envelope.

Do not reuse either path from a prior build. The release gate rejects stale
package output, and the source archive must come from this same volume.
Inspect the newly generated package set in the same artifact directory:

```bash
find "$ARTIFACTS_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort
test -s "$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
```

Expect exactly one common-headers, architecture-headers, image, and modules
package, plus at most one manifest-recorded `modules-extra` package.

For a git-source release, create the source archive from the exact Git tree
object recorded as `Patched tree ID` in that fresh schema-v2 manifest. Do not
use `git ls-files`: that lists the checkout/index and can omit ignored files
added by a patch even though those files are part of the recorded tree. Do not
archive the whole post-build directory either, because it contains generated
objects and packaging output.

The Docker workflow above leaves the patched source on its case-sensitive Linux
volume. Create the archive from the exact tree object there, mounting the volume
read-only and writing only to the host release-source directory:

```bash
BUILD_MANIFEST="$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
SOURCE_DIR_IN_VOLUME=/linux-work/source/git-jg-ubuntu-qcom-x1e-7.2-rc5-jg-0
ARCHIVE_ROOT=sp11-qcom-x1e-future-sp11v3-patched-source
PATCHED_TREE_ID="$(sed -n 's/^Patched tree ID: //p' "$BUILD_MANIFEST")"

test "$(sed -n 's/^Provenance schema: //p' "$BUILD_MANIFEST")" = \
  sp11-kernel-build-v2
test "$(sed -n 's/^Release build: //p' "$BUILD_MANIFEST")" = true
test "$(grep -c '^Patched tree ID: ' "$BUILD_MANIFEST")" = 1
test -n "$PATCHED_TREE_ID"
docker run --rm --platform linux/arm64/v8 \
  -e "ARCHIVE_ROOT=$ARCHIVE_ROOT" \
  -e "PATCHED_TREE_ID=$PATCHED_TREE_ID" \
  -e "SOURCE_DIR_IN_VOLUME=$SOURCE_DIR_IN_VOLUME" \
  -v "$LINUX_WORK_VOLUME:/linux-work:ro" \
  -v "$PWD/$RELEASE_SOURCE_DIR:/release-source" \
  "$BUILD_IMAGE" \
  bash -ceu '
    apt-get update >/dev/null
    apt-get install --yes --no-install-recommends git xz-utils >/dev/null
    git -C "$SOURCE_DIR_IN_VOLUME" cat-file -e "$PATCHED_TREE_ID^{tree}"
    git -C "$SOURCE_DIR_IN_VOLUME" archive \
      --format=tar --prefix="$ARCHIVE_ROOT/" "$PATCHED_TREE_ID" | \
      xz --threads=1 -6 > "/release-source/$ARCHIVE_ROOT.tar.xz"
  '
```

The release helper parses the archive without extracting host paths, rejects
malformed, multi-root, traversal, symlink-escape, unsafe-header, and appended
content, reconstructs the raw Git blob/tree identity including executable
modes and case-distinct names, and requires it to equal `Patched tree ID`. This
proves technical byte identity to the recorded tree. Human review is still
required for licence and corresponding-source sufficiency.

For an `sp11v3` release, build the touchscreen bundle against the release ABI
and preserve the generated provenance manifest:

```bash
common_header_candidates=(
  "$ARTIFACTS_DIR"/linux-qcom-x1e-headers-"${RELEASE_ABI%-qcom-x1e}"_*_all.deb
)
arch_header_candidates=(
  "$ARTIFACTS_DIR"/linux-headers-"$RELEASE_ABI"_*_arm64.deb
)
test "${#common_header_candidates[@]}" = 1
test "${#arch_header_candidates[@]}" = 1
test -f "${common_header_candidates[0]}"
test -f "${arch_header_candidates[0]}"
COMMON_HEADERS_DEB="${common_header_candidates[0]}"
ARCH_HEADERS_DEB="${arch_header_candidates[0]}"

docker run --rm --platform linux/arm64/v8 \
  -e "RELEASE_ABI=$RELEASE_ABI" \
  -e "COMMON_HEADERS_DEB=$COMMON_HEADERS_DEB" \
  -e "ARCH_HEADERS_DEB=$ARCH_HEADERS_DEB" \
  -e "TOUCH_BUILD_SOURCE=$TOUCH_BUILD_SOURCE" \
  -e "TOUCH_MODULES_DIR=$TOUCH_MODULES_DIR" \
  -v "$PWD:/repo" -w /repo \
  "$BUILD_IMAGE" \
  bash -ceu '
    apt-get update >/dev/null
    apt-get install --yes --no-install-recommends \
      build-essential ca-certificates git kmod >/dev/null
    ./scripts/build-sp11-touchscreen-modules.sh \
      --release "$RELEASE_ABI" \
      --source-dir "$TOUCH_BUILD_SOURCE" \
      --kernel-common-headers-deb "$COMMON_HEADERS_DEB" \
      --kernel-headers-deb "$ARCH_HEADERS_DEB" \
      --out-dir "$TOUCH_MODULES_DIR"
  '
```

The release mode never consumes an arbitrary host KDIR. It extracts the exact
common and architecture header Debs into a disposable pristine tree and builds
against that tree. The module manifest records this input mode and binds those
Deb hashes, kernel configuration, `Module.symvers`, tool identities, source
subtree, and licence blob. Publication rejects a module manifest that does not
match the schema-v2 kernel package hashes.

Create a deterministic archive of the exact module source used by that build.
The pinned tree has twelve build/source files below `phase55/modules/`; archive
the complete directory plus the repository licence so relative includes and
Kbuild inputs remain available:

```bash
TOUCH_COMMIT=6bbcf7a4759a73014047a57e819219dd7f34951a
TOUCH_SOURCE="$RELEASE_SOURCE_DIR/SP11X1e-touchscreen"
TOUCH_ARCHIVE_ROOT="sp11-touchscreen-modules-source-$TOUCH_COMMIT"

git clone --filter=blob:none --no-checkout \
  https://github.com/geocausa/SP11X1e-touchscreen.git \
  "$TOUCH_SOURCE"
git -C "$TOUCH_SOURCE" fetch --depth 1 origin "$TOUCH_COMMIT"
test "$(git -C "$TOUCH_SOURCE" rev-parse FETCH_HEAD^{commit})" = \
  "$TOUCH_COMMIT"
test "$(git -C "$TOUCH_SOURCE" ls-tree -r --name-only "$TOUCH_COMMIT" -- \
  LICENSE phase55/modules | wc -l | tr -d ' ')" = 13

git -C "$TOUCH_SOURCE" archive \
  --format=tar \
  --prefix="$TOUCH_ARCHIVE_ROOT/" \
  "$TOUCH_COMMIT" \
  LICENSE phase55/modules | \
  xz --threads=1 -6 > "$RELEASE_SOURCE_DIR/$TOUCH_ARCHIVE_ROOT.tar.xz"
```

Inspect the archive and confirm it contains no objects, modules,
`Module.symvers`, captures, or research evidence. Pair it with the patched
kernel source archive because the out-of-tree modules require the exact kernel
headers and configuration.

4. Blocked future step: prepare release assets after schema propagation.

The current preparer's older gate accepts a fresh schema-v2 `--release-build`
manifest, but that is no longer sufficient: it does not consume the new APT
sidecar or build-inputs envelope. Do not run it for a new publication until the
schema-propagation work above is complete. Legacy r1 build artifacts also
cannot be passed back through this gate. After that future update, an `sp11vN`
release must supply the ABI-matched module directory and both validated source
archives. This future-candidate example deliberately uses a new tag and build
directory:

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2

./scripts/prepare-sp11-kernel-release-assets.sh \
  --kernel-debs-dir "$ARTIFACTS_DIR" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --patch-dir patches/jglathe-qcom-x1e-7.2-rc5 \
  --patch-dir patches/sp11-qcom-x1e-7.2-rc5-v3 \
  --release-name "$TAG" \
  --source-asset "$RELEASE_SOURCE_DIR/sp11-qcom-x1e-future-sp11v3-patched-source.tar.xz" \
  --source-asset "$RELEASE_SOURCE_DIR/sp11-touchscreen-modules-source-6bbcf7a4759a73014047a57e819219dd7f34951a.tar.xz" \
  --touchscreen-modules-dir "$TOUCH_MODULES_DIR" \
  --touchscreen-source-url https://github.com/geocausa/SP11X1e-touchscreen.git \
  --touchscreen-source-ref 6bbcf7a4759a73014047a57e819219dd7f34951a
```

For a clean publishable run, the preparer also checks any existing local tag
against the recorded support commit, requires an `origin` remote, and performs
a fail-closed remote tag lookup. A mismatched tag, missing origin, or remote
lookup failure stops preparation before a publish command is printed. Keep
network access to the public release remote available for this preflight.

Repeat `--patch-dir` in the exact order used for the fresh kernel build. The
committed patch paths and hashes must match every entry in its schema-v2
manifest. Supplying an incomplete directory list makes the source provenance
fail closed.

The helper writes an ignored directory under:

```text
build/release/<release-name>/
```

It refuses to publish source-less output. Use `--allow-missing-source` only for
local rehearsal, never for a public binary release.

5. Review the generated release directory.

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2
find "build/release/$TAG" -maxdepth 1 -type f -print | sort
sed -n '1,220p' "build/release/$TAG/sp11-kernel-release-manifest.txt"
sed -n '1,220p' "build/release/$TAG/RELEASE-NOTES.md"
```

Check that the directory contains:

- the four required qcom-x1e `.deb` packages, plus the optional
  `modules-extra` package only when recorded by schema v2,
- `SHA256SUMS`,
- the exact snapshotted `sp11-kernel-build-manifest.txt` used by the preparer,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- the corresponding source assets,
- for `sp11v3`, both the patched kernel source and exact touchscreen-module
  source archive,
- for `sp11v3`, all three touchscreen modules and
  `sp11-touchscreen-modules-manifest.txt`,
- `RELEASE-NOTES.md`.

6. Verify checksums from inside the generated release directory.

```bash
(cd build/release/sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2 && \
  shasum -a 256 -c SHA256SUMS)
```

Then run the semantic validator. It checks package identities, exact asset and
checksum coverage, tag provenance, module metadata, and the packaged Denali
OLED touchscreen device tree. The validator requires Bash 4 and Linux package
inspection tools, so run it in the same digest-pinned ARM64 build image rather
than directly under macOS Bash 3.2:

```bash
validate_release_dir() {
  local release_dir="$1"
  shift
  local release_abs
  release_abs="$(cd "$release_dir" && pwd -P)"
  docker run --rm --platform linux/arm64/v8 \
    -v "$PWD:/repo:ro" \
    -v "$release_abs:/release:ro" \
    -w /repo \
    "$BUILD_IMAGE" \
    bash -ceu '
      apt-get update >/dev/null
      apt-get install --yes --no-install-recommends \
        coreutils device-tree-compiler dpkg git kmod python3 tar xz-utils \
        >/dev/null
      ./scripts/validate-sp11-touchscreen-release.sh --dir /release "$@"
    ' bash "$@"
}

validate_release_dir "build/release/$TAG"
```

For a pre-tag local rehearsal, omit `--tag` and `--remote`. Run the full command
after creating the tag and again against a fresh directory containing exactly
the downloaded release assets. If `gh release create` created a new remote tag,
fetch that exact tag before invoking the validator, which checks both its local
and remote targets:

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2
git fetch origin "refs/tags/$TAG:refs/tags/$TAG"

validate_release_dir "build/release/$TAG" --tag "$TAG" --remote origin
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

The project owner authorized the historical r1 kernel and image as explicitly
experimental prereleases while the complete clean-install hardware matrix was
still outstanding. The same disclosure is required for any future
experimental candidate that has not completed that matrix. This exception
does not make an artifact
hardware-qualified and does not waive the clean-install gate for a stable or
promoted release. The release notes must disclose that distinction and retain
the fallback-kernel and recovery-media requirements.

9. Verify the published release.

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2
gh release view "$TAG" \
  --json tagName,targetCommitish,isPrerelease,assets

download_dir="$(mktemp -d)"
gh release download "$TAG" \
  --repo ooaklee/linux-surface-pro-11-oe \
  --dir "$download_dir"
git fetch origin "refs/tags/$TAG:refs/tags/$TAG"

validate_release_dir "$download_dir" --tag "$TAG" --remote origin
```

Confirm the release is marked as a prerelease and that every uploaded binary or
source asset is listed in `SHA256SUMS`. Confirm the remote tag resolves to the
manifest support commit. Download the assets into a new empty directory, fetch
the new tag locally, and rerun `validate-sp11-touchscreen-release.sh` with
`--tag` and `--remote origin`.

## Expected Output

The local release directory should contain a flat asset set:

- `linux-headers-<abi>_<version>_arm64.deb`,
- either `linux-image-<abi>_<version>_arm64.deb` or
  `linux-image-unsigned-<abi>_<version>_arm64.deb`,
- `linux-modules-<abi>_<version>_arm64.deb`,
- `linux-qcom-x1e-headers-<base-version>_<version>_all.deb`,
- `SHA256SUMS`,
- `sp11-kernel-build-manifest.txt`,
- `sp11-kernel-release-manifest.txt`,
- `sp11-kernel-debs.txt`,
- one or more corresponding source assets,
- for `sp11v3`, `gpi.ko`, `spi-geni-qcom.ko`, `mshw0485_touch.ko`, and their
  provenance manifest,
- `RELEASE-NOTES.md`.

For reference only, the already-published historical r1 upload set was the
following. It is not a current preparation recipe and must not be regenerated
or replaced:

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
sp11-touchscreen-modules-source-6bbcf7a4759a73014047a57e819219dd7f34951a.tar.xz
SOURCE-NOTICE.md
SOURCE-SHA256SUMS
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
validate_release_dir build/release/<release-name>
./scripts/validate-sp11-public-content.sh
release_dir=build/release/<release-name>
public_args=()
for public_name in \
  RELEASE-NOTES.md SHA256SUMS SOURCE-SHA256SUMS \
  sp11-kernel-build-manifest.txt sp11-kernel-release-manifest.txt \
  sp11-touchscreen-modules-manifest.txt sp11-kernel-debs.txt; do
  test ! -e "$release_dir/$public_name" ||
    public_args+=(--file "$release_dir/$public_name")
done
./scripts/validate-sp11-public-content.sh "${public_args[@]}"
```

Passing validation means the local assets are internally consistent, the
repository state is clean, and the public-content validator did not find its
covered private-path, private-tool, credential, or key-material patterns in
tracked public text or the generated release text. The SSID, BSSID, MAC address,
and other hardware-identifier checks in the manual review list below remain a
human responsibility. Corresponding-source archive metadata is checked by the
release preparer rather than scanned as arbitrary binary data.

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
