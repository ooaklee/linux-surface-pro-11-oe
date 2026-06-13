---
id: adrs-adr010
title: "ADR010: Image Validation Workflow"
# prettier-ignore
description: Architecture Decision Record (ADR) for validating generated Surface Pro 11 Ubuntu USB images before writing them to removable media.
---

## Context

[ADR006](adr-0006-build-and-write-guardrails.md) established that raw disk
image writes must be guarded carefully. During the first image build, manual
validation checked the image size and hash, GPT layout, ESP contents, embedded
GRUB menu, and the extracted Surface Pro 11 DTB.

Those checks are easy to forget and awkward to reproduce by hand. macOS also
cannot directly mount or inspect the ext4 `SP11DATA` partition in the generated
image without extra tooling.

## Decision

The image builder will support two validation paths:

- `--validate`, which validates the image immediately after a build.
- `--validate-image IMAGE`, which validates an existing image and exits.

Validation will run inside the same ARM64 Ubuntu container model as the build.
It will report the image size, SHA-256 hash, GPT layout, ESP contents, embedded
GRUB menu hints, and `/dtb/sp11-denali.dtb` from the `SP11DATA` partition.

The validator will use Sleuth Kit tools to inspect the ext4 data partition by
sector offset. This avoids privileged loop mounts and keeps validation usable
on Docker Desktop for macOS.

## Consequences

Image validation becomes a first-class build step instead of a one-off manual
sequence.

The validator installs a few extra packages when it runs, so `--validate` adds
some time to the end of the build.

Passing validation does not prove that the Surface Pro 11 will boot. It proves
that the generated image has the intended bootloader, partition layout, DTB,
and support payload before it is written to a USB device.
