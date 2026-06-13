---
id: adrs-adr022
title: "ADR022: Docker Kernel Build Without fakeroot"
# prettier-ignore
description: Architecture Decision Record (ADR) for running Ubuntu qcom-x1e debian/rules directly in root Docker containers instead of through fakeroot.
---

## Context

[ADR020](adr-0020-dockerized-arm64-kernel-build.md) added an off-device Docker
workflow for building patched qcom-x1e kernel packages. [ADR021](adr-0021-git-fallback-kernel-build-toolchain.md)
selected an interim `ubuntu:25.10` image for the git fallback path so the
toolchain matches the current `qcom-x1e-7.0` branch.

During the first long git fallback build, the compile progressed into the
parallel kernel build and then failed with repeated:

```text
libfakeroot internal error: payload not recognized!
```

The Docker wrapper runs the Ubuntu container as root. In that environment,
wrapping `debian/rules` in `fakeroot` does not provide useful package ownership
simulation because the build process already has root privileges. It also adds
an IPC layer that can fail during the long parallel kernel package build.

The on-device build path remains different: it normally runs as an unprivileged
user and still needs `fakeroot` so generated package metadata has root-owned
files without requiring the entire build to run as root.

## Decision

The inner kernel build helper will route all `debian/rules` invocations through
a single helper.

When the helper is running as root, it will invoke `debian/rules` directly.
When the helper is running as a normal user, it will keep using `fakeroot`.

The Docker wrapper will pass `--no-fakeroot` to the inner helper to make the
root-container behavior explicit. Passing `--no-fakeroot` outside a root
context is invalid and fails early rather than silently producing unexpected
package ownership behavior.

This applies to all three qcom-x1e build rule invocations currently used by the
helper:

- generating `debian/control` for git source build dependencies,
- running `debian/rules clean`,
- running the selected qcom-x1e package build target.

## Consequences

Docker builds no longer depend on fakeroot's IPC layer during the expensive
parallel qcom-x1e package build.

The on-device build path keeps its existing non-root package build behavior.

The Docker output remains local generated package data and must not be
committed.

If a future Docker workflow intentionally runs the container as a non-root user,
it must either stop passing `--no-fakeroot` or provide a different package
ownership strategy.
