---
id: adrs-adr003
title: "ADR003: Version-bound kernel bundles"
description: Architecture decision for keeping kernels, modules, initramfs, and device trees consistent.
---

## Status

Accepted on 2026-08-30.

## Context

A bootable live image needs more than a kernel binary. Its module tree, generated initramfs, and board device trees must match the selected kernel ABI. Combining packages from different releases can produce media that passes superficial file checks but fails during boot or device discovery.

Kernel release assets are downloaded independently and can be replaced or corrupted unless each file is verified.

## Decision

Kernel inputs will be normalized into a `KernelBundle`. A bundle records its source release and repository, architecture, ABI, package version, selected Debian packages, package SHA-256 digests, and expected Surface Pro 11 device-tree paths.

Every image build requires one kernel image package and one modules package. The CLI will derive roles, ABI, and package version from the filenames and reject missing runtime packages, duplicate roles, mixed ABIs, mixed versions, or absent digests. Local package contents must match their recorded SHA-256 values immediately before use.

Release downloads will require a publisher `SHA256SUMS` asset. When the hosting service also supplies a digest, both values must agree. Headers may be carried in a bundle for development but are not required for live-image creation.

The remasterer will generate an initramfs for the bundle's exact ABI and take both the X1E OLED and X1P LCD device trees from that same installed modules package.

## Consequences

- Kernel, modules, initramfs, and device trees remain traceable to one release and ABI.
- Incomplete or internally inconsistent releases fail before an output image is published.
- Reusing a local bundle remains possible without weakening digest checks.
- Package naming is an explicit compatibility contract and requires parser updates if the release convention changes.
