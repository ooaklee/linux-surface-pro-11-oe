---
id: adrs-adr004
title: "ADR004: Containerised Ubuntu hybrid ISO remaster"
description: Architecture decision for replacing the live kernel while preserving ARM64 hybrid boot media.
---

## Status

Accepted on 2026-08-30.

## Context

Placing kernel packages beside an unchanged installer does not change the kernel used by its live environment. The Ubuntu Concept image uses Casper and layered live filesystems. It is also hybrid media with ISO boot records, a protective partition layout, and an appended EFI System Partition.

Surface Pro 11 firmware needs a usable ARM64 EFI path, and the boot menu must select the correct device tree for X1E and X1P variants. Reconstructing only the visible ISO filesystem can discard boot metadata or leave the appended EFI partition unchanged.

The required image tools are Linux-oriented and their behaviour should not depend on the host distribution.

## Decision

The `ubuntu-casper` adapter will perform a true live-image remaster. It will extract the Casper root filesystem, register the selected kernel image and modules in dpkg, run dependency indexing, generate exact-ABI live and installed initramfs images, and stage the paired X1E and X1P device trees. It will replace the live kernel and initramfs, update package, size, integrity, and support manifests, and repack the root filesystem using a compatible compression method.

The deployable root will contain explicit installed-system X1E and X1P GRUB entries, the required Surface boot arguments, versioned device trees under `/boot`, and a bounded kernel lifecycle hook that refreshes only paired Surface device trees. The live entries may temporarily blacklist `qcom_q6v5_pas` to keep USB installation media available; that blacklist must not be carried into the installed-system configuration. Both live and installed paths will carry `soundwire_qcom.sp11_feedback_active_offset2_zero=1` for the validated FullIO audio behaviour.

The adapter will use `xorriso` boot replay to preserve the source hybrid layout. It will install direct GRUB in the ISO filesystem and update the corresponding file inside the appended EFI System Partition. The generated GRUB menu will keep device-specific entries and temporary live-media kernel parameters scoped to those entries.

All Linux image tooling will run in a dedicated ARM64 Docker image whose definition is versioned with the CLI. Every remaster will allocate a uniquely named Linux Docker volume for extracted Casper layers, the merged live root, initramfs generation, and other mutable filesystem work. Keeping this state on a Linux filesystem preserves case-sensitive paths, root ownership, device nodes, whiteout behaviour, and required extended attributes independently of host filesystem semantics.

The host CLI will run as a regular user. Only input and output artefacts will cross the host boundary; the mutable live filesystem will not be exposed through a host bind mount. The CLI will revalidate the volume identity before lifecycle operations, remove it after a normal build, and publish the completed ISO atomically only after structural validation.

The validator will check the ISO and GPT boot structures, both EFI paths, embedded build manifest, kernel and initramfs digests, module tree for the selected ABI, device-tree files, and GRUB configuration. It will also extract the deployable root and verify exact dpkg records, a non-Casper installed initramfs, paired installed device trees, installed GRUB configuration, and bounded kernel refresh hooks.

Raw disk artefacts will use separate adapters because their partition and boot semantics differ from hybrid ISO media.

## Consequences

- The remastered live environment references and carries the selected custom kernel rather than merely storing packages for later installation.
- Ubuntu's default minimal layered installation receives a deployable root with the exact custom kernel registered and installed-system boot support prepared.
- Source boot metadata is retained while both firmware-visible EFI paths are updated consistently.
- Builds work from macOS or Linux hosts with a suitable Docker daemon and ARM64 container support without inheriting case-sensitivity, device-node, or extended-attribute limitations from the host filesystem.
- Docker, substantial free space, and additional build time are required.
- The adapter is intentionally coupled to the validated Ubuntu Casper layout and must reject incompatible source images.
- Structural validation cannot prove that Ubuntu completes an installation, runs its target `update-grub` step, or that firmware and peripherals behave correctly. The optional full-desktop upper layer has a separate package database and remains outside the currently proven hand-off. Secure Boot must remain disabled for the unsigned custom kernel, and live plus default-minimal installed boots on the target Surface Pro 11 remain final device gates.
