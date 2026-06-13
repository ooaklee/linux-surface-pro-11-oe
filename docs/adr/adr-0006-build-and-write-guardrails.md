---
id: adrs-adr006
title: "ADR006: Build and Write Guardrails"
# prettier-ignore
description: Architecture Decision Record (ADR) for using a containerized image builder and guarded macOS USB writer.
---

## Context

[ADR002](adr-0002-boot-shim-image-strategy.md) selects a raw USB image with an
ARM64 GRUB boot shim. Building that image on macOS requires Linux filesystem
tools, ARM64 GRUB binaries, and GPT manipulation.

The requested test target is a removable USB disk. Writing raw images to disks
is destructive, and the host may also have internal disks attached.

## Decision

The image builder will run inside an ARM64 Ubuntu container. It will produce a
raw GPT disk image with:

- a FAT EFI System Partition labeled `SP11EFI`,
- an ext4 data partition labeled `SP11DATA`,
- a validation pass using GPT tooling before exporting the image.

The macOS writer will accept only explicit `/dev/diskN` targets and refuse to
write unless `diskutil info` reports the target as external, removable, and
USB. It will print the target disk information and wait briefly before erasing
the device.

We will not write the USB until the Ubuntu ISO and Denali DTB inputs are
present and the image has built successfully.

## Consequences

The builder avoids relying on host loop devices or host Linux filesystem
support. Docker Desktop is required on macOS.

The writer reduces accidental internal-disk risk but cannot make raw disk
writing harmless. Users must still verify the target disk immediately before
running it.

Future automation can wrap these scripts, but it should preserve the explicit
disk verification and destructive-write pause.
