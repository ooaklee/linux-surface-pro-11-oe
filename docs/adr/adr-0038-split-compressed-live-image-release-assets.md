---
id: adr-0038-split-compressed-live-image-release-assets
title: "ADR0038: Split Compressed Live Image Release Assets"
# prettier-ignore
description: Architecture Decision Record (ADR) for publishing Surface Pro 11 live USB raw images as split compressed GitHub Release assets.
---

> **Current operator notice (2026-08-30):** This raw-image release flow and
> every former builder or preparation command below are historical,
> non-prescriptive evidence. Current operators use `image create`,
> `image validate`, `image write`, `image release prepare`, and
> `image release validate`; see
> [Lexr ADR017](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-017-native-image-release-preparation.md).
> Structural and reconstructed-byte proof does not assert a successful hardware boot.

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
owner authorised it as an experimental prerelease before completion of the
clean-install hardware matrix. It is not a hardware-qualified promotion, and
the exception does not relax checksum, provenance, explicit-target, or
fresh-download validation requirements.

## Context

The Surface Pro 11 bring-up can produce a direct-boot Ubuntu live USB raw disk
image:

```text
build/sp11-ubuntu-live-direct.img
```

For the Johan G. qcom-x1e 7.1.1 test image, the raw disk image is about 6.2 GB.
The image contains:

- an EFI system partition labelled `SP11EFI`
- an ext4 data partition labelled `SP11DATA`
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
9. print a `gh release create` command with an explicit
   `--target <support-commit>` that uploads only GitHub-safe assets

The default part size is 2,000,000,000 bytes. The helper rejects any configured
part size that is greater than or equal to 2,147,483,648 bytes.

The manifest records:

- raw image size and SHA256
- compressed image size and SHA256
- per-part size and SHA256
- validator outline SHA256
- support repository commit and dirty state
- whether validation ran

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

For the corrective r1 image, the generated publication command must have this
shape:

```bash
SUPPORT_COMMIT="$(git rev-parse HEAD)"

gh release create sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1 \
  --target "$SUPPORT_COMMIT" \
  --prerelease \
  --title "Surface Pro 11 live USB: 7.2-rc5-jg-0sp11v3 r1" \
  --notes-file RELEASE-NOTES.md \
  sp11-live-image-outline.txt \
  sp11-live-image-release-manifest.txt \
  SHA256SUMS \
  sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1.img.zst.part-aa \
  sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1.img.zst.part-ab \
  sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1.img.zst.part-ac
```

`$SUPPORT_COMMIT` must equal the clean support commit in the image manifest.
The retired image tag must not be reused, and GitHub must not infer the target
from the default branch.

## Consequences

The image can be published entirely through GitHub Releases without relying on
Google Drive, external object storage, or a separate hosting account.

Users must download multiple part files and reconstruct the compressed image
before writing the USB disk. This adds one step, but keeps all release assets
under the same tag, with checksums and provenance in one place.

The raw `.img` is intentionally not uploaded as a release asset. The uploaded
payload is the split compressed archive plus metadata files.

The release remains experimental. The raw image is unsigned, and users must
verify checksums and choose the correct removable disk before writing. The r1
authorisation permits experimental distribution while the hardware matrix is
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
Releases should remain the canonical artefact location.

### Split the raw image without compression

This would avoid a decompression step but would require more uploaded assets
and more total download bandwidth. Compression reduces the release size while
still allowing deterministic reconstruction and checksum verification.

### Compress without splitting

This was rejected because the compressed image can still exceed GitHub's per
asset limit. The Johan G. qcom-x1e 7.1.1 direct image compressed to about 4.2
GB, which still requires splitting.

## Verification

The helper was validated against the direct image generated for the Johan G.
qcom-x1e 7.1.1 path.

Validation performed:

```bash
bash -n scripts/prepare-sp11-image-release-assets.sh
./scripts/prepare-sp11-image-release-assets.sh \
  --image build/sp11-ubuntu-live-direct.img \
  --release-name sp11-ubuntu-live-direct-jg-7.1.1 \
  --allow-dirty
cd build/release/sp11-ubuntu-live-direct-jg-7.1.1
shasum -a 256 -c SHA256SUMS
```

The generated release assets were:

```text
sp11-live-image-outline.txt
sp11-live-image-release-manifest.txt
SHA256SUMS
sp11-ubuntu-live-direct.img.zst.part-aa
sp11-ubuntu-live-direct.img.zst.part-ab
sp11-ubuntu-live-direct.img.zst.part-ac
```

The split parts were below GitHub's per-asset upload limit.

The parts were also stream-verified:

```bash
cat sp11-ubuntu-live-direct.img.zst.part-* | shasum -a 256
cat sp11-ubuntu-live-direct.img.zst.part-* | zstd -d -c | shasum -a 256
```

The reconstructed compressed archive hash matched the manifest, and the
decompressed raw image hash matched the manifest.

## Related

- [ADR026: Prebuilt Kernel Release Artefacts](adr-0026-prebuilt-kernel-release-artifacts.md)
- [ADR037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1](adr-0037-jglathe-qcom-7-1-1-stubble-paths.md)
- [Lexr ADR017: Native image release preparation](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-017-native-image-release-preparation.md)
