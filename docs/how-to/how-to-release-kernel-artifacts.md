---
id: how-to-release-kernel-artifacts
title: "Prepare and Validate Kernel Release Artefacts"
# prettier-ignore
description: How-to guide for preparing a closed, checksummed Surface Pro 11 kernel release from linux-armer's native build output.
---

# How To: Prepare and Validate Kernel Release Artefacts

Use `linux-armer kernel release prepare` to turn one exact native kernel build
into a new local release directory. Preparation is deliberately separate from
publication: it does not create a tag, contact GitHub, upload files, install a
kernel, obtain root privilege, or claim that the result has passed hardware
testing.

The current kernel carries the Surface Pro 11 touchscreen stack in-tree. The
old `sp11v3` packages and their separate `gpi.ko`, `spi-geni-qcom.ko`, and
`mshw0485_touch.ko` bundle are retired. The native release contract rejects
that ABI and those out-of-tree assets rather than preserving an obsolete
installation path.

## Prerequisites

- A built `linux-armer` executable on `PATH`.
- Docker when the kernel still needs to be built.
- Enough local storage for the kernel build, corresponding source archive, and
  release copies.
- One fresh output path for the native build and another fresh output path for
  release preparation. Existing directories are refused rather than merged or
  replaced.
- A corresponding-source archive for the exact Git revision recorded by the
  native build.
- Explicit licence text, normally the kernel source tree's `COPYING` file.

Corresponding-source and redistribution obligations require human legal
review. Structural validation proves what bytes were packaged; it does not
decide whether those bytes are legally sufficient to publish.

## 1. Produce one native build

Select unique output names so a previous build cannot be mistaken for the new
one:

```bash
build_dir=build/linux-armer/kernel-v19

linux-armer kernel build \
  --repository-root . \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11 \
  --git-branch sp11/integration-7.2.x \
  --output-dir "$build_dir" \
  --reset-source \
  --jobs 8
```

The command uses the compiled ARM64 container policy. Its output is a closed
directory containing only:

- one coherent `linux-image` and `linux-modules` package pair;
- either both header packages or neither;
- `SHA256SUMS` covering exactly the packages;
- `linux-armer-kernel-bundle.json`; and
- `linux-armer-kernel-build-provenance.json`.

Release preparation refuses additional files, missing files, mixed ABIs or
versions, changed package bytes, a mutable container image, unsafe source
URLs, and provenance that does not match this exact native-builder contract.

## 2. Materialise the recorded source

Read the immutable source identity from the private build provenance and
create an archive of that exact tree. This example uses a temporary checkout
and verifies both the commit and tree before archiving:

```bash
provenance="$build_dir/linux-armer-kernel-build-provenance.json"
git_url="$(jq -er .git_url "$provenance")"
revision="$(jq -er .revision "$provenance")"
expected_tree="$(jq -er .tree "$provenance")"

source_checkout="$(mktemp -d)"
trap 'rm -rf -- "$source_checkout"' EXIT

git -C "$source_checkout" init -q
git -C "$source_checkout" remote add origin "$git_url"
git -C "$source_checkout" fetch --depth=1 origin "$revision"
git -C "$source_checkout" checkout --detach FETCH_HEAD

test "$(git -C "$source_checkout" rev-parse HEAD)" = "$revision"
test "$(git -C "$source_checkout" rev-parse 'HEAD^{tree}')" = "$expected_tree"

mkdir -p build/linux-armer/release-source
source_archive="build/linux-armer/release-source/linux-$revision.tar.xz"
licence_file="build/linux-armer/release-source/LICENSE.kernel.txt"

git -C "$source_checkout" archive \
  --format=tar \
  --prefix="linux-$revision/" \
  "$revision" | xz -T0 > "$source_archive"
git -C "$source_checkout" show "$revision:COPYING" > "$licence_file"
```

Do not substitute a branch-tip archive: the release manifest records the exact
commit and tree from the build.

## 3. Review a dry run

Choose a tag-like release name and an absent output directory:

```bash
release_name=sp11-qcom-x1e-7.2.0-jg-0sp11v19
release_dir="build/release/$release_name"

linux-armer kernel release prepare \
  --build-dir "$build_dir" \
  --output-dir "$release_dir" \
  --release-name "$release_name" \
  --source "$source_archive" \
  --licence "$licence_file" \
  --dry-run
```

The dry run hashes and validates every input but creates neither the release
directory nor a missing parent. Add `--json` for a path-free machine-readable
receipt. Both output forms omit host paths and the private Docker work-volume
identity.

## 4. Prepare the local release

Run the same command without `--dry-run`:

```bash
linux-armer kernel release prepare \
  --build-dir "$build_dir" \
  --output-dir "$release_dir" \
  --release-name "$release_name" \
  --source "$source_archive" \
  --licence "$licence_file"
```

Preparation revalidates the closed build and every supplementary input, copies
into a private staging directory, verifies each copied size and digest, writes
the public contracts, validates the complete staged directory, flushes it, and
renames it into place atomically. The receipt distinguishes publication from
the final parent-directory durability flush.

The resulting flat directory contains:

- the coherent kernel packages;
- every named corresponding-source archive and licence file;
- `linux-armer-kernel-bundle.json`;
- `linux-armer-kernel-release-manifest.json`;
- `RELEASE-NOTES.md`; and
- `SHA256SUMS`, covering every other file exactly once.

There is no separate private build-provenance file in the public directory.
Its safe source, recipe, container, and toolchain fields are projected into the
release manifest; host paths and Docker volume identity are omitted.

## 5. Validate the exact directory

```bash
linux-armer kernel release validate "$release_dir"
linux-armer kernel release validate "$release_dir" --json
```

Validation is local and read-only. It rejects unknown or trailing JSON,
symbolic links, special files, subdirectories, extra or missing assets,
case-folded filename collisions, checksum or size drift, inconsistent roles,
mixed versions or ABIs, unpaired headers, source URLs outside the native
builder's bounded repository-URL contract, mutable container images, missing
source or licence evidence, modified generated notes, and the retired
out-of-tree touchscreen contract.

Passing means the directory is structurally self-consistent and safe to enter
the project's separate publication review. It does not verify a remote tag,
prove reproducibility, grant publication authority, or qualify the kernel on
Surface hardware.

## 6. Review before publication

Before using the repository's explicitly authorised release process:

1. Review `linux-armer-kernel-release-manifest.json` and `RELEASE-NOTES.md`.
2. Confirm the source archive and licence evidence are suitable for
   redistribution.
3. Confirm no firmware, Windows hand-off, diagnostic report, account name,
   hardware identifier, authenticated URL, or local path is present.
4. Keep the release experimental and unsigned until the separate hardware
   matrix has passed.
5. After publication, download every asset into a new empty directory and run
   `linux-armer kernel release validate` against those downloaded bytes.

Do not add or remove an asset after preparation. Any change requires a new
fresh output directory so the manifest, generated notes, and checksum set are
recreated together.

## Related Documents

- [ADR016: Native kernel release preparation and v3 retirement](../../cli/linux-armer/docs/adr/adr-016-native-kernel-release-preparation.md)
- [ADR026: Prebuilt kernel release artefacts](../adr/adr-0026-prebuilt-kernel-release-artifacts.md)
- [Build a patched qcom-x1e kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [Reinstall the patched kernel from USB or a release](how-to-reinstall-patched-kernel-from-usb.md)
