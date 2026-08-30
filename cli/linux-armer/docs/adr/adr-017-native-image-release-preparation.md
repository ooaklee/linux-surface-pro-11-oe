---
id: adrs-adr017
title: "ADR017: Native image release preparation"
description: Architecture decision for local-only, deterministic, split installation-image release preparation and validation.
---

## Status

Accepted on 2026-08-30.

## Context

The original live-image release helper prepared a raw disk image through a shell workflow. The current image builder instead publishes a directly written hybrid ISO, one adjacent `*.iso.manifest.json` contract, and one path-bearing operation journal. The image manifest is also the sole authority for the optional companion bundle. A release workflow must preserve that contract rather than create another companion manifest or assume the retired raw-disk layout.

Hosted release services impose a per-asset size limit below the size of a complete installation image. The image therefore needs deterministic compression and ordered splitting. Reviewers and users must be able to verify the exact closed release directory, reconstruct the original ISO digest, and understand the kernel, device-tree, media-discovery, companion, and structural-validation evidence without trusting a release-provided executable script.

The adjacent operation journal records useful creation evidence but includes a local output path. Copying it unchanged into a public release would disclose a builder path. Preparation must retain its evidential value without publishing workstation-specific data. It must also remain distinct from remote publication: creating local assets does not authorise a tag, release, upload, or any other remote mutation.

## Decision

The image domain will own `image release prepare` and `image release validate` through a compiled feature package. Preparation accepts only one bounded, regular `.iso` beneath an explicit repository root, the exact adjacent image-manifest sidecar, and the exact adjacent native creation journal. It rejects symbolic-link routes, unsafe names, incomplete or out-of-order journal steps, mismatched output identities, existing output directories, and output anywhere except a fresh `build/release/<release-name>` child.

The adapter-owned image validator must pass before release preparation. Its image digest, size, layout, adapter and kernel ABI must agree with the ISO sidecars. The release manifest stores only stable check names and pass states; local diagnostic paths and free-form details are not published.

The zstd executable is invoked directly with argument separation, a fixed compression level, one worker and content checksums. No shell or repository script is executed. The encoder version and settings are recorded because different encoder versions need not produce identical compressed bytes. The source ISO is hashed while it is fed to the encoder, and the compressed stream is divided by the Go workflow into zero-padded parts. Every part is opened exclusively, flushed, hashed and kept below the hosted asset limit.

The generated `image-release-manifest.json` is deterministic and path-free. It records the ISO identity, exact copied image-manifest identity and decoded contract, a path-free ordered projection of the creation journal, structural-validation evidence, compression policy, recombined archive identity, part limit, and every part identity. The original journal is deliberately not published. Its output path becomes the ISO basename in the projection, while checkpoint times and sorted digest evidence are preserved.

`SHA256SUMS` covers every published file except itself in lexical order. Release notes are rendered deterministically from the manifest. A prepared directory contains exactly the image-manifest sidecar, release manifest, notes, checksum file and declared parts; no additional member, link, special file or directory is permitted.

Preparation occurs in a mode-`0700` sibling transaction. It copies the already measured sidecar, streams compression, writes generated records exclusively, validates the complete staged directory, streams decompression across the ordered parts, and proves both compressed and reconstructed ISO identities. Only then does it select the public mode and use the host's atomic no-replace rename primitive. A failure removes only the transaction directory whose filesystem identity the process created. An existing final directory is never replaced.

Independent validation strictly decodes canonical JSON, checks the exact directory and checksum set, compares the copied single image manifest with the embedded release contract, verifies every part during streaming decompression, and proves the reconstructed ISO digest and size. Validation does not require or execute release-provided code.

Both commands are local-only. Their structured results explicitly state that no remote service was changed. Publishing remains a separate, deliberate operator action outside this package.

## Consequences

- The current hybrid-ISO contract, including its manifest-tracked companion bundle, reaches a release without a second companion authority.
- Identical source bytes, sidecars, release identity, split size and zstd version produce identical release bytes even when repositories occupy different host paths.
- The release records successful structural validation but does not claim physical-device boot qualification.
- Verification requires a compatible local `zstd` executable, but never a repository shell helper.
- The public release omits the original path-bearing journal while preserving its ordered, immutable evidence in a path-free projection.
- Very small part sizes can create too many files and are rejected by a fixed part-count safety bound.
- Release preparation cannot update an existing directory in place; operators choose a fresh release identity for a new byte set.
