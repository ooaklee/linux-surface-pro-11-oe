---
id: adrs-adr021
title: "ADR021: Git Fallback Kernel Build Toolchain"
# prettier-ignore
description: Architecture Decision Record (ADR) for selecting the Docker image used by the git fallback qcom-x1e kernel build.
---

## Context

[ADR020](adr-0020-dockerized-arm64-kernel-build.md) added a Dockerized ARM64
kernel build workflow. The preferred path is apt source mode with metadata
collected from the installed Surface Pro 11 kernel package.

During bring-up, the default Ubuntu 26.04 container could not fetch the
`linux-qcom-x1e` source package without matching qcom-x1e source repositories.
The git fallback path was therefore used with the public `qcom-x1e-7.0` branch.

That branch currently carries qcom-x1e packaging for `7.0.0-22.22` and its
config annotations expect Rust 1.85 and LLVM 19. Building it in an Ubuntu 26.04
container installs Rust 1.93, which makes Ubuntu's config policy check fail
before the kernel compile starts. Ubuntu 25.10 provides Rust 1.85 and LLVM 19,
matching the branch's expected toolchain generation.

## Decision

The Docker wrapper will select its default image by source mode:

- apt source mode defaults to `ubuntu:26.04`, matching the installed Resolute
  qcom-x1e package stream when matching source repositories are available;
- git source mode defaults to `ubuntu:25.10`, matching the current
  `qcom-x1e-7.0` branch's Rust and LLVM config policy.

The operator can still override the image explicitly with `--image` when a
different source branch or package stream requires a different toolchain.

## Consequences

The git fallback path can build with the branch's expected Rust policy without
disabling Ubuntu config checks.

Ubuntu 25.10 is an interim release, so this default has a limited support
window. When the git fallback branch moves to a newer toolchain policy, or when
Ubuntu 25.10 packages are no longer available from the standard container
sources, the default git-mode image must be revisited.

The apt source path remains tied to matching qcom-x1e source repositories for
the installed Surface kernel. If those repositories become available to the
container, apt source mode remains preferred because it can build the exact
source package version recorded from the Surface.

The git fallback still may not match the exact kernel ABI installed on the
Surface. Its output remains an experiment for Wi-Fi rfkill bring-up rather than
a substitute for a matching source-package rebuild.
