---
id: adrs-adr004
title: "ADR004: Containerized Ubuntu hybrid ISO remaster"
description: Architecture decision for replacing the live kernel while preserving ARM64 hybrid boot media.
---

## Status

Accepted on 2026-08-30.

## Context

Placing kernel packages beside an unchanged installer does not change the kernel used by its live environment. The Ubuntu Concept image uses Casper and layered live filesystems. It is also hybrid media with ISO boot records, a protective partition layout, and an appended EFI System Partition.

Surface Pro 11 firmware needs a usable ARM64 EFI path, and the boot menu must select the correct device tree for X1E and X1P variants. Reconstructing only the visible ISO filesystem can discard boot metadata or leave the appended EFI partition unchanged.

The required image tools are Linux-oriented and their behavior should not depend on the host distribution.

## Decision

The `ubuntu-casper` adapter will perform a true live-image remaster. It will extract the Casper root filesystem, install the selected kernel image and modules, run dependency indexing, generate an exact-ABI initramfs, and stage the paired X1E and X1P device trees. It will replace the live kernel and initramfs, update package, size, integrity, and support manifests, and repack the root filesystem using a compatible compression method.

The adapter will use `xorriso` boot replay to preserve the source hybrid layout. It will install direct GRUB in the ISO filesystem and update the corresponding file inside the appended EFI System Partition. The generated GRUB menu will keep device-specific entries and temporary live-media kernel parameters scoped to those entries.

All Linux image tooling will run in a dedicated ARM64 Docker image whose definition is versioned with the CLI. The host CLI will run as a regular user, mount only a dedicated build workspace, and publish the output atomically after structural validation.

The validator will check the ISO and GPT boot structures, both EFI paths, embedded build manifest, kernel and initramfs digests, module tree for the selected ABI, device-tree files, and GRUB configuration.

Raw disk artifacts will use separate adapters because their partition and boot semantics differ from hybrid ISO media.

## Consequences

- The live session boots the selected custom kernel rather than merely carrying packages for later installation.
- Source boot metadata is retained while both firmware-visible EFI paths are updated consistently.
- Builds work from macOS or Linux hosts with a suitable Docker daemon and ARM64 container support.
- Docker, substantial free space, and additional build time are required.
- The adapter is intentionally coupled to the validated Ubuntu Casper layout and must reject incompatible source images.
