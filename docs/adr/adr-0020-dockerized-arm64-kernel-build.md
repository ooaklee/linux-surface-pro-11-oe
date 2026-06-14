---
id: adrs-adr020
title: "ADR020: Dockerized ARM64 Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for building patched Surface Pro 11 qcom-x1e kernel packages inside a Docker ARM64 Linux container.
---

## Context

[ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) introduced a
patched qcom-x1e kernel build path for the Surface Pro 11 Wi-Fi rfkill
experiment. That decision assumed the build would happen on the installed
Surface Pro 11 or another ARM64 Linux system.

The Surface Pro 11 can build the kernel locally, but that uses battery, heat,
disk, and time on the device under test. A stronger development machine can
build the same ARM64 packages in a Docker `linux/arm64` container, then carry
the generated `.deb` files back to the Surface through the USB payload.

The off-device build still needs to match the qcom-x1e package stream installed
on the Surface. A container cannot infer that from its own running kernel, so
the Surface must export the source package and source version metadata first.

## Decision

The project will support Dockerized ARM64 qcom-x1e kernel builds as the
preferred heavy-build workflow when another machine is available.

The workflow has three parts:

- `scripts/collect-sp11-kernel-source-metadata.sh` runs on the installed
  Surface Pro 11 and writes the running qcom-x1e source package/version to a
  small shell metadata file.
- `scripts/build-sp11-qcom-x1e-kernel-docker.sh` runs on the build host,
  launches a Docker `linux/arm64` Ubuntu container, applies the ADR019 patches,
  and builds the qcom-x1e packages in a host-mounted work directory.
- The Docker wrapper can copy generated qcom-x1e `.deb` files to
  `payload/kernel-debs/` so the existing live-USB image builder carries them to
  `SP11DATA`.

Installation still happens on the Surface Pro 11, using
`scripts/build-sp11-qcom-x1e-kernel.sh --install-only`. That keeps the
fallback-kernel guard and installed-system support helper in the target
environment instead of inside the container.

The Docker wrapper defaults to apt source mode with explicit metadata from the
Surface. A public git source mode remains available for bring-up, but it is not
the preferred path when the installed package source version is available.

## Consequences

The expensive compile can move off the Surface Pro 11 while preserving the
Surface-side install and validation guardrails.

The Docker host needs Docker support for `linux/arm64`. On ARM64 hosts this is
usually native. On x86_64 hosts this may require QEMU emulation and can be much
slower.

The container still needs matching source repositories for the qcom-x1e source
package. If the default Ubuntu container sources cannot fetch the exact source
version, the operator must provide a matching apt `.sources` or `.list` file to
the Docker wrapper, or intentionally choose the git fallback path.

Generated package files, source trees, and copied USB payload debs remain local
artifacts and must not be committed.
