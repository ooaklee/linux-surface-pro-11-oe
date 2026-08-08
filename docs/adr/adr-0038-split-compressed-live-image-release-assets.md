---
id: adr-0038-split-compressed-live-image-release-assets
title: "ADR0038: Split Compressed Live Image Release Assets"
# prettier-ignore
description: Architecture Decision Record (ADR) for publishing Surface Pro 11 live USB raw images as split compressed GitHub Release assets.
---

# ADR0038: Split Compressed Live Image Release Assets

## Status

Accepted — required for publishing the Surface Pro 11 direct-boot live USB
image through GitHub Releases (2026-06-27).

Release amendment (2026-08-07): the historical
`sp11-ubuntu-live-direct-jg-7.1.1` release and tag were removed because the tag
pointed to the parent of the support commit recorded by its manifest. The
split-image design remains valid, but a future image must bind its tag to the
exact manifest commit.

Corrective-release amendment (2026-08-07): the fresh image uses the new
immutable tag `sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1`. The project
owner authorized it as an experimental prerelease before completion of the
clean-install hardware matrix. It is not a hardware-qualified promotion, and
the exception does not relax checksum, provenance, explicit-target, or
fresh-download validation requirements.

Corresponding-source amendment (2026-08-07): an image that distributes the
v3 kernel packages and three GPL touchscreen modules must also distribute the
matching patched kernel source, exact touchscreen-module source, licence
notice, and source checksums. The r1 image received those assets additively;
future image preparation fails closed when any member of that source set is
missing.

Immutable-build-input amendment (2026-08-07): current image preparation also
requires the exact kernel APT-provenance sidecar and build-inputs envelope. It
attaches those files without rewriting them, validates them independently,
and cross-binds them through both the kernel and image release manifests. The
preparer now produces validation-complete or draft asset sets only; it never
prints or runs a publication command, and every generated outer manifest
records `Publication state: blocked`. Before any semantic validation, the
preparer also creates a private byte-exact snapshot of the raw image and uses
only that snapshot for validation, hashing, and compression.

## Context

The Surface Pro 11 bring-up can produce a direct-boot Ubuntu live USB raw disk
image:

```text
build/sp11-ubuntu-live-direct.img
```

For the Johan G. qcom-x1e 7.1.1 test image, the raw disk image is about 6.2 GB.
The image contains:

- a 512 MiB FAT32 EFI system partition labeled `SP11EFI`, containing only
  `README.txt`, `EFI`, `EFI/BOOT`, and `EFI/BOOT/BOOTAA64.EFI`
- an ext4 data partition labeled `SP11DATA`
- the direct GRUB boot path for the Surface Pro 11 Denali DTB
- the Ubuntu concept ISO payload
- the Surface Pro 11 support tree
- optional payloads such as audio files and qcom-x1e kernel `.deb` packages

The live image validator already records a useful release outline:

```text
== Image ==
== GPT ==
== ESP ==
== Data Partition ==
== Payload ==
== Support Helpers ==
```

That outline should travel with the image release so users can inspect the
partition layout, boot mode, payload contents, DTB checksum, and support-helper
markers without rebuilding the image.

GitHub Release uploads reject a single asset that is 2,147,483,648 bytes or
larger. Uploading the raw `.img` therefore fails with a validation error:

```text
size must be less than 2147483648
```

## Decision

Publish live USB image releases as split compressed assets rather than as a
single raw image.

The release helper:

```text
scripts/prepare-sp11-image-release-assets.sh
```

will:

1. validate the raw image with `scripts/build-sp11-live-usb-image.sh
   --validate-image`
2. save the validator output as `sp11-live-image-outline.txt`
3. compress the raw image with `zstd -6`
4. split the compressed `.zst` file into parts smaller than GitHub's asset
   limit
5. remove the temporary whole `.zst` file from the release directory
6. write `sp11-live-image-release-manifest.txt`
7. write `SHA256SUMS` for the uploaded parts and metadata files
8. write `RELEASE-NOTES.md` with reconstruct, verify, and write commands
9. verify the exact two-partition GPT, FAT32/ext4 labels, ESP allowlist and
   boot-file identities, embedded ISO, kernel-built DTB, exact committed
   `/support` tree, and exact `/payload/kernel-debs` inventory against their
   six attached provenance manifests
10. copy and hash the reviewed kernel source, touchscreen source, source
   notice, and all six manifests required by an image containing the v3
   binary payload
11. finish with an explicit `NO-PUBLISH` result while byte-reproducibility,
    signing, licensing, recovery/hardware, and release-authorization gates
    remain open

Snapshot creation compares the source image's size and SHA-256 before and
after the copy with the private snapshot's size and SHA-256. Clone or reflink
copying is preferred, sparse copying is the next fallback, and a full copy is
the final fallback. The original `build/*.img` path is retained only as the
public display identity after that proof; Docker extraction, image-manifest
validation, outline generation, release hashing, and compression all consume
the private snapshot.

The default part size is 2,000,000,000 bytes. The helper rejects any configured
part size that is greater than or equal to 2,147,483,648 bytes.

The generated release-manifest set records these values. GPT/ESP geometry and
file identities live in the attached image-build manifest; the release
manifest binds that exact file by name and SHA256:

- raw image size and SHA256
- compressed image size and SHA256
- per-part size and SHA256
- validator outline SHA256
- support repository commit and dirty state
- whether validation ran
- the exact kernel-build, kernel-release, APT-provenance, build-inputs,
  touchscreen-module, and image-build manifest names, sizes, and SHA-256
  identities
- the APT snapshot identity and immutable snapshot URI
- the kernel OCI index and ARM64 platform-manifest identities
- preserved build-envelope creation state and completed kernel-release and
  image-level kernel-provenance propagation
- an explicitly blocked publication state
- exact GPT geometry, type GUIDs, partition names and flags
- FAT32/ext4 filesystem labels and the ESP boot/README paths, sizes, and hashes
- corresponding-source asset names and hashes

The generated release notes instruct users to:

```bash
shasum -a 256 -c SHA256SUMS
cat sp11-ubuntu-live-direct.img.zst.part-* > sp11-ubuntu-live-direct.img.zst
printf '%s  %s\n' '<compressed-sha256>' 'sp11-ubuntu-live-direct.img.zst' | shasum -a 256 -c -
zstd -d --force sp11-ubuntu-live-direct.img.zst
printf '%s  %s\n' '<raw-image-sha256>' 'sp11-ubuntu-live-direct.img' | shasum -a 256 -c -
sudo dd if=sp11-ubuntu-live-direct.img of=/dev/diskX bs=16M conv=fsync status=progress
```

The exact hashes are generated into the release notes for each release.

For an image carrying an installed-system kernel payload, the notes and image
outline must also distinguish the two boot contexts. The live environment
continues to use the concept ISO's casper kernel. Kernel packages and
exact-ABI touchscreen modules under `SP11DATA/payload/kernel-debs` are consumed
only by the guarded installed-system flow; their presence does not add
touchscreen support to the live session.

A validation-complete release candidate requires all of:

```text
--kernel-source-asset <patched-kernel-source.tar.xz>
--touchscreen-source-asset <exact-module-source.tar.xz>
--source-notice <reviewed-SOURCE-NOTICE.md>
--kernel-build-manifest <schema-v2-release-build-manifest.txt>
--kernel-release-manifest <matching-kernel-release-manifest.txt>
--apt-provenance <matching-kernel-apt-provenance.txt>
--build-inputs <matching-kernel-build-inputs.txt>
--touchscreen-module-manifest <matching-module-release-manifest.txt>
--image-build-manifest <matching-image-build-manifest.txt>
```

The helper validates the two archives, cross-binds all six manifests to the
clean support commit and exact kernel/module package identities extracted from
the raw image, and attaches all nine provenance inputs plus
`SOURCE-SHA256SUMS` to the main asset inventory. It preserves the exact
`sp11-kernel-build-inputs-v1` bytes, including their build-time
`Publication schema propagation: incomplete` value. The outer
`sp11-live-image-release-v1` manifest separately records
`Build envelope creation propagation: incomplete`, verifies that the kernel
release completed its propagation, attests
`Kernel provenance propagation: complete`, and remains blocked from
publication. `--skip-validate` instead prepares a clearly nonpublishable
`sp11-live-image-draft-v1` asset set with incomplete propagation and never
emits a publication command.

The corrective r1 image is immutable historical output. It cannot be
re-prepared by the current schema-v2 gate. A future candidate uses a new tag
and supplies all nine provenance inputs:

```bash
TAG=sp11-ubuntu-live-direct-future-sp11vN-experimental-r2
ISO_URL=https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso
: "${ISO_SHA256:?set this from an independently verified public checksum}"
: "${KERNEL_DTB:?set this to the schema-v2 denali-oled-dtb output path}"

./scripts/build-sp11-live-usb-image.sh \
  --iso "$ISO_URL" \
  --expected-iso-sha256 "$ISO_SHA256" \
  --dtb "$KERNEL_DTB" \
  --payload payload/kernel-debs \
  --grub-mode direct \
  --work-dir build/work-future-sp11vN \
  --out build/sp11-ubuntu-live-direct.img \
  --build-manifest build/sp11-live-image-build-manifest.txt \
  --validate

./scripts/prepare-sp11-image-release-assets.sh \
  --image build/sp11-ubuntu-live-direct.img \
  --release-name "$TAG" \
  --kernel-source-asset build/release-source/future-patched-source-kernel.tar.xz \
  --touchscreen-source-asset build/release-source/sp11-touchscreen-modules-source-FUTURE_COMMIT.tar.xz \
  --source-notice build/release-source/SOURCE-NOTICE.md \
  --kernel-build-manifest build/future-provenance/sp11-kernel-build-manifest.txt \
  --kernel-release-manifest build/future-provenance/sp11-kernel-release-manifest.txt \
  --apt-provenance build/future-provenance/sp11-kernel-apt-provenance.txt \
  --build-inputs build/future-provenance/sp11-kernel-build-inputs.txt \
  --touchscreen-module-manifest build/future-provenance/sp11-touchscreen-modules-manifest.txt \
  --image-build-manifest build/sp11-live-image-build-manifest.txt
```

The preparer accepts the raw image only as a direct, regular, non-symlinked
`build/*.img` child of the support repository. This keeps the Docker bind-mount
source and the public repository-relative path within the builder's canonical
output location until the private snapshot is established.

The image manifest must name a public HTTPS ISO and its predeclared SHA-256,
use the digest-pinned ARM64 builder, and bind the embedded DTB to the
`denali-oled-dtb` output in the schema-v2 kernel manifest. The
validation-complete preparation path therefore builds with an explicit DTB
from that exact output; `--dtb auto` remains a local-image convenience, not a
publication provenance source. The
builder stages only `payload/kernel-debs` beneath `/payload/kernel-debs`.
For `gnome`, the embedded ISO must be byte-identical to the pinned input ISO.
The `kde` path intentionally remasters that ISO, so its manifest records and
the raw-image gate verifies the remastered ISO hash instead; its network-fed
package transaction remains an experimental reproducibility limitation and is
not suitable for a stable-release claim.

Only after exact raw-image ISO, DTB, support-tree, and payload extraction plus
source/manifest validation does the helper produce a validation-complete asset
set. It still reports `NO-PUBLISH` and never prints or runs a
`gh release create` command. A later, separately authorized publication step
must use the clean support commit as its explicit target. Retired image tags
must not be reused, and GitHub must not infer the target from the default
branch.
The raw gate also rejects unexpected SP11DATA root entries, payload siblings,
support files, symlinks, special files, unsafe modes, and hard links.
It additionally requires valid primary and backup GPT metadata with exactly the
builder's two partitions, fixed `SP11EFI` geometry, `SP11DATA` ending at the
final 1 MiB boundary before the backup-GPT region, exact type GUIDs/names/flags,
FAT32 and ext4 labels, and no unexpected ESP files. `BOOTAA64.EFI` must be
nonempty and match the image-build manifest; `README.txt` must match the
builder's exact public text bytes.

## Consequences

The split asset design can be published entirely through GitHub Releases
without relying on Google Drive, external object storage, or a separate
hosting account. Current preparation does not itself authorize or perform that
publication.

Users must download multiple part files and reconstruct the compressed image
before writing the USB disk. This adds one step, but keeps all release assets
under the same tag, with checksums and provenance in one place.

The raw `.img` is intentionally not uploaded as a release asset. The uploaded
payload is the split compressed archive, metadata files, and the
corresponding-source set for binary code carried by the image.

The release remains experimental. The raw image is unsigned, and users must
verify checksums and choose the correct removable disk before writing. The r1
authorization permits experimental distribution while the hardware matrix is
outstanding; it does not justify a stable or hardware-qualified claim.

## Alternatives Considered

### Upload the raw image to GitHub Releases

This was rejected because GitHub rejects assets that are 2,147,483,648 bytes or
larger. The current raw image is much larger than that limit.

### Upload the image to a public Google Drive link

This was rejected as the default path because the image would no longer live
with the release tag, checksums, and generated provenance. External links can
also change, hit quota limits, or be harder to mirror.

An external mirror can still be added as a convenience later, but GitHub
Releases should remain the canonical artifact location.

### Split the raw image without compression

This would avoid a decompression step but would require more uploaded assets
and more total download bandwidth. Compression reduces the release size while
still allowing deterministic reconstruction and checksum verification.

### Compress without splitting

This was rejected because the compressed image can still exceed GitHub's per
asset limit. The Johan G. qcom-x1e 7.1.1 direct image compressed to about 4.2
GB, which still requires splitting.

## Verification

The split/compression behavior was originally validated against the direct
image generated for the Johan G. qcom-x1e 7.1.1 path. The nine-input
source-and-payload gate was added later and is covered by
`tests/test-sp11-image-release-source-gate.sh`, which uses synthetic complete
schema-v2 manifests, exact source-tree archives, and a mocked tiny payload
identity extraction. That regression is not evidence that a placeholder future
release was prepared. `tests/test-sp11-image-binding-extractor.sh` separately
builds genuine builder-shaped sparse GPT images with FAT32 and ext4 filesystems
under Linux. It exercises exact partition geometry and metadata, filesystem
labels, ESP contents and hashes, payload, support, ISO, DTB, modes, hard links,
and unexpected-entry rejection.

The source-gate regression also swaps the original raw-image path from one
byte identity to another and back while the mocked semantic extractor runs.
It requires the extractor to receive the private snapshot instead, rejects
the forged semantic result, and leaves no prepared output directory.

Current static and synthetic regression commands are:

```bash
bash -n scripts/prepare-sp11-image-release-assets.sh
./tests/test-sp11-image-release-source-gate.sh
./tests/test-sp11-support-tree-binding.sh
./tests/test-sp11-image-binding-extractor.sh
```

A genuine future candidate is expected to produce this asset shape after the
real raw-image payload, exact archives, and all six real manifests pass the
same gate:

```text
sp11-live-image-outline.txt
sp11-live-image-release-manifest.txt
SOURCE-NOTICE.md
SOURCE-SHA256SUMS
future-patched-source-kernel.tar.xz
sp11-touchscreen-modules-source-FUTURE_COMMIT.tar.xz
sp11-kernel-build-manifest.txt
sp11-kernel-release-manifest.txt
sp11-kernel-apt-provenance.txt
sp11-kernel-build-inputs.txt
sp11-touchscreen-modules-manifest.txt
sp11-live-image-build-manifest.txt
SHA256SUMS
sp11-ubuntu-live-direct.img.zst.part-aa
sp11-ubuntu-live-direct.img.zst.part-ab
sp11-ubuntu-live-direct.img.zst.part-ac
```

Every split part must be below GitHub's per-asset upload limit; the helper
checks that condition for the real candidate rather than relying on this
illustrative list.

The image payload extractor currently starts from a digest-pinned Ubuntu base
but installs `gdisk`, `parted`, and Sleuth Kit from the distribution repository at
validation time. This is acceptable for the experimental prerelease gate, but
the package repository is mutable; a future hardened validator image should
preinstall and pin those tools before stable-release use.

For the historical Johan G. qcom-x1e 7.1.1 image, the parts were also
stream-verified:

```bash
cat sp11-ubuntu-live-direct.img.zst.part-* | shasum -a 256
cat sp11-ubuntu-live-direct.img.zst.part-* | zstd -d -c | shasum -a 256
```

In that historical 7.1.1 run, the reconstructed compressed archive hash
matched its manifest, and the decompressed raw image hash matched its manifest.

## Related

- [ADR026: Prebuilt Kernel Release Artifacts](adr-0026-prebuilt-kernel-release-artifacts.md)
- [ADR037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1](adr-0037-jglathe-qcom-7-1-1-stubble-paths.md)
- [Prepare Surface Pro 11 live USB image release assets](../../scripts/prepare-sp11-image-release-assets.sh)
