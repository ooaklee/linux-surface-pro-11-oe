---
id: how-to-release-kernel-artifacts
title: "Release Prebuilt Kernel Artifacts"
# prettier-ignore
description: How-to guide for preparing optional Surface Pro 11 qcom-x1e kernel release assets with checksums, provenance, and source artifacts.
---

# How To: Release Prebuilt Kernel Artifacts

Use this procedure to prepare and review a local candidate containing prebuilt
Surface Pro 11 qcom-x1e kernel `.deb` packages. It is not a publication
procedure.

## Purpose

Building the patched qcom-x1e kernel can take more than an hour on a capable
ARM64 host. A prerelease lets users download the same experimental package set
without rebuilding it, while keeping large binaries out of git.

This procedure follows [ADR026](../adr/adr-0026-prebuilt-kernel-release-artifacts.md):

- if future publication is separately authorized, use GitHub Release assets
  for `.deb` packages rather than tracking them in git,
- keep `payload/kernel-debs/` as local USB staging only,
- include `SHA256SUMS`, sanitized manifests, and corresponding source assets,
- do not publish proprietary firmware, Windows driver extracts, diagnostics,
  service reports, or hardware identifiers.

> **Current publication gate:** closed for newly built artifacts. Release mode
> emits a schema-v2 kernel manifest, the
> `sp11-kernel-apt-provenance-v1` sidecar, and the
> `sp11-kernel-build-inputs-v1` envelope. The kernel release preparer now
> validates and attaches those exact bytes and emits a
> `sp11-kernel-release-v1` completion attestation. The build envelope's literal
> `Publication schema propagation: incomplete` remains unchanged as its
> build-time state; the outer manifest records kernel-release propagation as
> complete while keeping `Publication state: blocked`. The preparer emits
> **NO-PUBLISH** and no publication command. One real immutable-input build is
> now recorded, but byte reproducibility, the signing policy,
> recovery/hardware evidence, corresponding-source/release-candidate review,
> and explicit release authorization remain open and still block this kernel
> release candidate. P0.3's final file-level licence/UCM reviews also remain
> open. [`LEGAL.md`](../../LEGAL.md) records the interim owner direction; those
> pending reviews alone no longer block pushes, merges, or publication of newly
> authored artifacts.

## Prerequisites

- A clean repository checkout on the release branch.
- Enough disk space and an ARM64 Docker environment for the fresh release-mode
  build performed below. Its package set, v2 kernel manifest, v1 APT sidecar,
  v1 build-inputs envelope, and canonical retained-evidence tar representing
  the full APT state must all come from the same `--release-build` run.
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
- A human review that the selected source assets are sufficient for the binary
  packages in the local candidate.

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
   creates and inspects the exact packages in the local candidate.

3. Prepare or identify the corresponding source assets.

If a future schema-v2 gate adds apt-source release support, its corresponding
source set should use Debian source package artifacts such as:

```text
linux-qcom-x1e_<version>.dsc
linux-qcom-x1e_<version>.orig.tar.*
linux-qcom-x1e_<version>.debian.tar.*
```

That is not the current path. The current candidate gate uses Git source and
requires the exact patched-tree archive described below; another durable link
or a checkout assembled from instructions is not a substitute.

Before preparing a local candidate, rerun the pinned kernel build command from
[How To: Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
with `--release-build`. A normal or historical build manifest is not accepted
by the current gate. Do not try to recreate or re-prepare the already-published
r1 artifacts with the current helper; r1 is immutable historical output created
before the schema-v2 gate. Use one new host artifact directory and one new
Linux Docker volume for the whole candidate workflow:

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
install -d -m 0700 "$RELEASE_WORK_DIR"
install -d -m 0700 "$ARTIFACTS_DIR"
ARTIFACTS_FIRST_ENTRY="$(
  find "$ARTIFACTS_DIR" -mindepth 1 -maxdepth 1 -print -quit
)" || exit 1
test -z "$ARTIFACTS_FIRST_ENTRY"
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

After the build, require the retained evidence record, its controller files,
and the complete flat provenance trio:

```bash
test -s "$RELEASE_WORK_DIR/sp11-kernel-retained-evidence.tar"
test -s "$RELEASE_WORK_DIR/docker-build-args.txt"
test -s "$RELEASE_WORK_DIR/docker-build-inside.sh"
test -s "$RELEASE_WORK_DIR/sp11-oci-index.json"
test -f "$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
test -f "$ARTIFACTS_DIR/sp11-kernel-apt-provenance.txt"
test -f "$ARTIFACTS_DIR/sp11-kernel-build-inputs.txt"
grep -Fx 'APT provenance complete: true' \
  "$ARTIFACTS_DIR/sp11-kernel-apt-provenance.txt"
grep -Fx 'Publication schema propagation: incomplete' \
  "$ARTIFACTS_DIR/sp11-kernel-build-inputs.txt"
```

The final `grep` preserves the envelope's immutable build-time state. It is not
a waiver or an instruction to edit the envelope. The outer release manifest
later validates the exact attached trio and records kernel-release propagation
as complete. That completion closes the propagation gap only; it does not open
publication.

Do not reuse either path from a prior build. The release gate rejects stale
package output, and the source archive must come from this same Linux
source/build volume rather than from the separate retained-state volume.
Inspect the newly generated package set in the same artifact directory:

```bash
find "$ARTIFACTS_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort
test -s "$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
```

Expect exactly one common-headers, architecture-headers, image, and modules
package, plus at most one manifest-recorded `modules-extra` package.

For a git-source release, use the committed deterministic generator with the
exact Git tree recorded as `Patched tree ID` in a fresh schema-v2 manifest. Do
not substitute a raw `git archive` pipeline, `git ls-files`, the whole post-build
directory, or any rewritten/postprocessed archive. Those alternatives bypass
the generator's toolchain, repeatability, exact-tree, metadata, resource, and
exclusive-output checks.

Run the generator only inside a fresh network-disabled container after replaying
and revalidating the retained immutable APT inputs and exact pre/post package
inventories. Mount the support checkout, build manifest, and named-volume source
read-only; mount only the release-source destination read-write; and provide a
fresh private `/tmp` tmpfs. Inside that already validated toolchain envelope,
the generator invocation is:

```bash
/usr/bin/python3 -I /repo/scripts/generate-sp11-kernel-source-archive.py \
  --baseline /repo/config/kernel-baselines/7.2-rc5-jg-0.env \
  --toolchain-contract /repo/config/kernel-source-archive-v1.env \
  --build-manifest /artifacts/sp11-kernel-build-manifest.txt \
  --source-repo \
    /linux-work/source/git-jg-ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --scratch-parent /tmp \
  --output \
    /release-source/sp11-qcom-x1e-future-sp11v3-patched-source.tar.xz
```

The retained 2026-08-08 four-patch tree cannot satisfy this gate: independent
validation correctly rejected its tracked `debian/scripts/misc/find-dtbs.py`
symbolic link because the target escapes the archive root. No archive was
installed. Do not weaken the validator or rewrite that tree under its existing
manifest. Only a fresh build whose ordered patches remove the stale link and
whose exact-tree symlink-containment preflight passes may continue through this
procedure.

That build-time preflight proves only bounded symlink containment in the exact
Git namespace under the pinned OCI/APT toolchain and trusted build-controller
envelope. It is not a sandbox against malicious or concurrent same-container
root/source-rule mutation, and it does not claim that every in-tree link
resolves. The independent generator and archive validator must still recompute
the exact tree and containment result before an archive candidate is accepted.

The host-side Docker launch assumes an exclusive, trusted host controller from
before private control/output-root creation or acquisition through bind-source
resolution and use. After a root is acquired, release-mode writes are confined
to held directory and creation-owned file descriptors; collisions, links,
special nodes, persistent mapping drift, and pathname deletion or overwrite are
rejected. This flow does not claim integrity, availability, or victim
preservation against a concurrent process with the same host credentials
racing root creation/acquisition or substituting a validated bind source. That
stronger guarantee requires privilege separation or a separately reviewed
supervisor and daemon-owned, content-addressed inputs.

That trusted-controller boundary also requires exclusive use of the selected
Docker context, socket, and daemon credentials, with no concurrent read-write
mount or mutation of the named release-state volume from creation through
evidence import. A daemon-owned volume is not itself immutable or
content-addressed. Any later forensic use of the retained volume requires the
same exclusive custody and a fresh validation; the imported evidence tar is
the bounded host-side record of the accepted run.

Host-side orchestration, including the release preparer, also assumes an
exclusive trusted checkout and a non-hostile process environment, system
toolchain, and `PATH`; it does not claim resistance to a malicious replacement
of ordinary host utilities. Security-critical retained release-evidence
helpers use absolute isolated interpreter authority and commit-bound code,
while legacy preparer utilities remain inside this explicit host-toolchain
boundary.

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

4. Prepare a local review candidate.

The preparer validates the canonical
`sp11-kernel-retained-evidence.tar`, the exact v2 build manifest, v1 APT
sidecar, v1 build-inputs envelope, and their bound controller files. The full
APT cache, indexes, list targets, and package inventories remain represented by
that tar rather than recreated as host directory trees. The preparer attaches
the three flat provenance files and records the retained tar identity in the
outer release manifest. It rejects missing, changed, extra, and legacy
publishable inputs. Legacy r1 output remains immutable and cannot be passed
back through this gate. An `sp11vN` candidate must also supply the ABI-matched
module directory and both validated source archives.

The output directory is publication authority, so create the exact private,
empty mode-`0700` directory before invoking the preparer. The preparer fills it
with exclusive no-follow writes and refuses an existing member instead of
overwriting or deleting it. Mode `0700` explicitly means incomplete. Only the
terminal descriptor-held commit changes the directory to mode `0500`, after
all bytes, membership, provenance, and pending-signal checks pass. Any run that
fails before that terminal commit may retain forensic files, but its directory
remains mode `0700`; never reuse, validate, or publish from that directory. A
successful mode change is the authoritative commit even if a later uncatchable
process or host failure prevents the best-effort success text or normal exit.
Mode `0500` is necessary but not sufficient for a candidate: exclusive custody
and the complete checksum and semantic validation below still apply. This
example uses a new candidate name and output directory:

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-experimental-r2
RELEASE_OUT="build/release/$TAG"
test ! -e "$RELEASE_OUT"
install -d -m 0700 "$RELEASE_OUT"
RELEASE_FIRST_ENTRY="$(
  find "$RELEASE_OUT" -mindepth 1 -maxdepth 1 -print -quit
)" || exit 1
test -z "$RELEASE_FIRST_ENTRY"

./scripts/prepare-sp11-kernel-release-assets.sh \
  --kernel-debs-dir "$ARTIFACTS_DIR" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --patch-dir patches/jglathe-qcom-x1e-7.2-rc5 \
  --patch-dir patches/sp11-qcom-x1e-7.2-rc5-v3 \
  --release-name "$TAG" \
  --out-dir "$RELEASE_OUT" \
  --source-asset "$RELEASE_SOURCE_DIR/sp11-qcom-x1e-future-sp11v3-patched-source.tar.xz" \
  --source-asset "$RELEASE_SOURCE_DIR/sp11-touchscreen-modules-source-6bbcf7a4759a73014047a57e819219dd7f34951a.tar.xz" \
  --touchscreen-modules-dir "$TOUCH_MODULES_DIR" \
  --touchscreen-source-url https://github.com/geocausa/SP11X1e-touchscreen.git \
  --touchscreen-source-ref 6bbcf7a4759a73014047a57e819219dd7f34951a
```

For a clean source-bound candidate, the preparer also checks any existing local
tag against the recorded support commit, requires an `origin` remote, and
performs a fail-closed remote tag lookup. A mismatched tag, missing origin, or
remote lookup failure stops preparation. Successful preparation still produces
only a local review directory and a **NO-PUBLISH** result; it never prints a
publication command.

Repeat `--patch-dir` in the exact order used for the fresh kernel build. The
committed patch paths and hashes must match every entry in its schema-v2
manifest. Supplying an incomplete directory list makes the source provenance
fail closed.

The helper writes only into the caller-created ignored directory under:

```text
build/release/<release-name>/
```

It refuses to prepare a source-less source-bound candidate. Use
`--allow-missing-source` only for a local draft rehearsal.

5. Review the generated release directory.

First require the terminal mode-`0500` commit marker. The preparer emits its
success text only after that transition while all output and evidence
descriptors are still held:

```bash
case "$(uname -s)" in
  Darwin)
    test "$(stat -f '%Lp' "$RELEASE_OUT")" = 500
    test "$(stat -f '%u' "$RELEASE_OUT")" = "$(id -u)"
    ;;
  *)
    test "$(stat -c '%a' -- "$RELEASE_OUT")" = 500
    test "$(stat -c '%u' -- "$RELEASE_OUT")" = "$(id -u)"
    ;;
esac
```

The mode is not an immutability claim. Continue with the exact file and content
checks; any mismatch rejects the directory even when its mode is `0500`. This
is a local prepublication-candidate contract. Individually downloaded release
assets do not carry their parent directory mode. The explicit
`--downloaded-release` mode validates transported content only and confers no
local preparer transaction or publication authority; it cannot manufacture
the mode-`0500` local commit marker. Do not silently relax this local gate.

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
- the exact snapshotted `sp11-kernel-apt-provenance.txt`,
- the exact snapshotted `sp11-kernel-build-inputs.txt`,
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

Then run the semantic validator. It checks the exact immutable provenance trio,
outer release binding, package identities, exact asset and checksum coverage,
module metadata, and the packaged Denali OLED touchscreen device tree. The
validator requires Bash 4 and Linux package inspection tools, so run it in the
same digest-pinned ARM64 build image rather than directly under macOS Bash 3.2:

```bash
validate_release_dir() {
  local release_dir="$1"
  shift
  local release_abs release_mode release_owner
  test -d "$release_dir"
  test ! -L "$release_dir"
  release_abs="$(cd "$release_dir" && pwd -P)"
  case "$(uname -s)" in
    Darwin)
      release_mode="$(stat -f '%Lp' "$release_abs")"
      release_owner="$(stat -f '%u' "$release_abs")"
      ;;
    *)
      release_mode="$(stat -c '%a' -- "$release_abs")"
      release_owner="$(stat -c '%u' -- "$release_abs")"
      ;;
  esac
  test "$release_mode" = 500
  test "$release_owner" = "$(id -u)"
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
      ./scripts/validate-sp11-touchscreen-release.sh \
        --local-prepared-candidate --dir /release "$@"
    ' bash "$@"
}

validate_release_dir "build/release/$TAG"
```

The explicit `--local-prepared-candidate` mode requires the mode-`0500`
transaction marker in addition to complete content validation. The validator's
host-side precheck also requires a real, non-symlinked directory owned by the
current user. Downloaded-release mode intentionally does not treat directory
mode as transported provenance, because individual downloaded assets do not
preserve their original parent-directory metadata. Changing a downloaded
directory to mode `0500` does not turn it into a locally prepared candidate.

7. Review the explicit **NO-PUBLISH** result.

The helper emits no publication command. Confirm the outer manifest says
`Kernel release propagation: complete` and `Publication state: blocked`, and
confirm the release notes disclose the byte-reproducibility, signing,
recovery/hardware, corresponding-source, and authorization gates, plus the
pending final licence/UCM reviews recorded in [`LEGAL.md`](../../LEGAL.md). Do
not add, remove, or regenerate files after validation.

8. Record the offline review result.

Retain the candidate path, checksum result, semantic-validator result, and
human source/licence review with the
[real immutable-input build evidence](../sp11-kernel-immutable-build-evidence-20260808.md).
Do not create or move a tag, upload assets, or change the historical r1 release.

9. Stop at the publication boundary.

This procedure intentionally ends with a local candidate. Publication requires
a separately authorized future procedure after every remaining gate is closed;
successful preparation alone is not that authorization.

## Expected Output

The local release directory should contain a flat asset set:

- `linux-headers-<abi>_<version>_arm64.deb`,
- either `linux-image-<abi>_<version>_arm64.deb` or
  `linux-image-unsigned-<abi>_<version>_arm64.deb`,
- `linux-modules-<abi>_<version>_arm64.deb`,
- `linux-qcom-x1e-headers-<base-version>_<version>_all.deb`,
- `SHA256SUMS`,
- `sp11-kernel-build-manifest.txt`,
- `sp11-kernel-apt-provenance.txt`,
- `sp11-kernel-build-inputs.txt`,
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

For historical r1, `RELEASE-NOTES.md` supplied the release body and was not an
uploaded asset. That statement documents the immutable historical set; it is
not a current publication instruction.

The current local candidate includes the packages, checksums, manifests,
immutable provenance trio, source assets, and `RELEASE-NOTES.md` shown above.

## Validation

Run these checks before accepting the local candidate for offline review:

```bash
git status --short
shasum -a 256 -c build/release/<release-name>/SHA256SUMS
validate_release_dir build/release/<release-name>
./scripts/validate-sp11-public-content.sh
release_dir=build/release/<release-name>
public_args=()
for public_name in \
  RELEASE-NOTES.md SHA256SUMS SOURCE-SHA256SUMS \
  sp11-kernel-build-manifest.txt sp11-kernel-apt-provenance.txt \
  sp11-kernel-build-inputs.txt sp11-kernel-release-manifest.txt \
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
requires human review and a separately authorized future publication process.

## Privacy and Safety

Never commit generated release assets. `build/`, `payload/kernel-debs/`, and
`*.deb` are ignored intentionally.

During offline review, check that candidate assets do not include:

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
`--source-asset` values. Use `--allow-missing-source` only for a local draft.

If the helper refuses the output directory, use the default
`build/release/<release-name>/` layout. The helper intentionally rejects
path traversal, dot-prefixed names, symlinked release roots, and outputs
outside `build/release/`.

This procedure does not cover upload failures because publication is blocked.
Do not move large binary packages into git as a fallback.

## Related Documents

- [ADR026: Prebuilt Kernel Release Artifacts](../adr/adr-0026-prebuilt-kernel-release-artifacts.md)
- [How To: Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
