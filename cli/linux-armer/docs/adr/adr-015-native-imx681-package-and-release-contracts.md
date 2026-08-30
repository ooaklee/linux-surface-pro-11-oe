---
id: adrs-adr015
title: "ADR015: Native IMX681 package and release contracts"
description: Architecture decision for authenticated native camera builds, coherent package validation, and local-only release preparation.
---

## Status

Accepted on 2026-08-30.

ADR020 refines transferred-build and release validation with independent
authority digests and a non-executable static proof.

## Context

Surface Pro 11 camera support needs a downstream libcamera patch, matching IMX681 tuning data, Ubuntu source packaging, and five runtime packages whose Simple IPA signature must match the libcamera core from the same build. Installing only one package or mixing build versions can cause IPA authentication to fail even when each Debian package is individually well formed.

The earlier build and publication helpers kept much of this policy in repository shell scripts. They also carried an obsolete default pairing with the sp11v14 kernel generation and combined local release preparation with optional remote publication. A released companion binary must be able to perform the maintained build and preparation workflows without those scripts, must not install anything on the host, and must not gain implicit authority to change a remote release.

The Ubuntu package build needs network access to acquire source and build dependencies. It also needs a native ARM64 Linux environment because the final proof executes the newly built `ipa_verify` and IPA module. A dry run on another platform can still describe the exact policy, but it cannot truthfully claim executable verification.

## Decision

The camera build domain will authenticate `BASE.txt`, the downstream patch, and `imx681.yaml` as regular non-link files whose bytes exactly match the selected support-tree HEAD. `BASE.txt` has an ordered, closed field contract. The parser rejects duplicate, missing, unknown, reordered, control-bearing, bidirectional, oversized, or malformed data. Its Ubuntu DSC, orig tarball, and Debian tarball SHA-256 values are the source authority; the container also checks that the DSC binds the two tarballs before extraction.

The host will invoke Docker only with argument-separated commands assembled by compiled Go policy. The build uses a digest-qualified Ubuntu 26.04 image, requires a native Linux ARM64 host and Docker server for execution, and supports a no-pull mode which refuses an absent local image. Parallel jobs and required free space are bounded. A dry run performs read-only support-input authentication and reports when the current host cannot execute the native proof; it does not pull an image or create directories.

The complete container recipe is embedded in the Go package and recorded by SHA-256. Network access inside the container is limited to normal package dependency and authenticated Ubuntu source acquisition. The recipe applies the distribution patch series before the reviewed IMX681 patch, verifies the resulting tuning file, builds the package set once, and selects exactly these runtime packages:

- `libcamera0.7`
- `libcamera-ipa`
- `libcamera-tools`
- `libcamera-v4l2`
- `gstreamer1.0-libcamera`

The selected packages, original `.changes`, original `.buildinfo`, and one structured build receipt form an eight-file bundle. The host validates package, source, version, architecture, size, and SHA-256 identity. Every `Checksums-Sha256` entry in `.changes` is recorded as delivered or deliberately omitted, and every delivered package plus `.buildinfo` must match its entry. This preserves the original Debian record while giving the selected runtime subset closed accounting.

Both the container and host extract the same-build core, IPA, and verifier packages. They require the IMX681 tuning bytes to match the authenticated support input and require `ipa_verify` to report a valid IPA signature. A successful container exit alone is not build success.

The build receipt contains no workstation path. It records support commit and input digests, authenticated Ubuntu and upstream source identity, extracted `debian/copyright` identity, package terms evidence, immutable builder identity, embedded recipe identity, toolchain identity, complete changes accounting, and every selected artefact digest and size. The build uses a private transaction and installs a fresh output directory with an operating-system no-replace rename. Cancellation or failure triggers bounded named-container cleanup and withholds publication. Nothing is installed on the host.

The camera release domain will accept only a successfully revalidated eight-file native bundle. It requires an explicit release tag, paired kernel tag, and paired installed qcom-x1e ABI; it has no sp11v14 default. It performs no GitHub, Git, tag, release, upload, or other remote mutation.

Local preparation copies the eight build artefacts into a new transaction, writes `SHA256SUMS` covering those eight files exactly once, writes British-English release notes, and writes a path-free structured release manifest with source and licence provenance. The resulting release directory contains exactly eleven regular files. It is flushed and installed with an atomic no-replace rename, so an existing file, directory, or link at the chosen tag is never replaced.

The package and release APIs remain separate from Cobra and userspace orchestration. Command wiring may expose build, validation, and local preparation, but remote publication would require a separate future decision and explicit authority.

## Consequences

- Camera source and local modifications are bound to one support commit and cannot silently drift between planning, building, and release preparation.
- All five runtime packages come from one build version and pass the trusted build workflow's same-build IPA signature and tuning identity proof; transferred bundles repeat static identity proof under ADR020.
- The public bundle has structured, machine-readable source, licence, builder, and output provenance without exposing a local filesystem path.
- Release preparation is recoverable, collision-safe, and strictly local; it does not imply permission to publish.
- ARM64 package execution remains an honest build-time platform gate. Other
  platforms can inspect a deterministic build dry run and can perform the
  later digest-pinned static release proof, but cannot claim the trusted
  builder's executable same-build IPA proof.
- The original Debian changes record can mention additional outputs, but every entry is accounted for and no unselected output enters the bounded runtime bundle.
- The old camera builder and publisher scripts are no longer runtime dependencies and may be retired once CLI wiring, current documentation, and the repository-wide migration gates are complete.
- Structural package proof does not establish camera graph operation, privacy indication, image quality, browser capture, suspend recovery, or repeated raw transport on a Surface Pro 11. Those remain explicit hardware tests.
