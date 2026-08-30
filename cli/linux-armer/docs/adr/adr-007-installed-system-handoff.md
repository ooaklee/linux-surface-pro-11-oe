---
id: adrs-adr007
title: "ADR007: Deterministic installed-system hand-off from Ubuntu media"
description: Architecture decision for carrying the selected Surface kernel and boot support through installation.
---

## Status

Accepted on 2026-08-30.

## Context

A live image can boot the custom kernel while still installing an operating system that lacks that kernel, its device trees, or usable firmware entries. Leaving packages under an ISO support directory is not an installed-system strategy. Running the historical support scripts after installation would also reintroduce retired audio, touchscreen, wireless, and service workarounds that no longer belong in the maintained path.

The X1E/OLED and X1P/LCD devices require different device trees. Installed media also needs ordinary storage and audio behaviour rather than the temporary USB safeguards used by the live environment.

## Decision

The Ubuntu adapter will register the exact ARM64 image and modules packages in the deployable Casper root's dpkg database. It will create a separate non-Casper initramfs for that ABI, seed both paired device trees in versioned `/boot` paths, and install explicit GRUB entries for the X1E and X1P models.

Installed GRUB configuration will contain the common Surface platform arguments and `soundwire_qcom.sp11_feedback_active_offset2_zero=1`. It will not contain the live-media-only `qcom_q6v5_pas` blacklist.

A bounded refresh helper and kernel post-install and post-remove hooks will consider only path-safe Surface kernel ABIs. They will copy only the two known device-tree filenames from the corresponding ABI's package paths, with the original image's paired seed copies available for its exact ABI. They will not download content, execute catalogue data, or install historical workarounds.

The structural publication gate will extract the default minimal deployable root and verify dpkg registration, installed kernel and initramfs contents, device-tree digests, GRUB arguments and entries, and hook boundaries. The optional full-desktop upper layer carries its own dpkg status database and is outside this first proven hand-off. The project will still require a real minimal installation, confirmation that the installer runs its target `update-grub` step, and an installed boot on Surface hardware before describing a release as hardware-validated.

## Consequences

- Installing from the remastered Ubuntu media no longer depends on a separate all-purpose post-install script for its selected kernel and boot paths.
- Live USB safeguards remain isolated from installed-system behaviour.
- Later Surface kernel packages can refresh their paired device trees through a narrow lifecycle hook.
- Firmware with restricted redistribution remains outside the image and must be acquired separately from an authorised source.
- Structural checks can prove payload coherence for the default minimal root but cannot prove that every Ubuntu installer choice deploys or boots it correctly on hardware.
