---
id: adrs-adr023
title: "ADR023: Docker Kernel Build Case-Sensitive Work Volume"
# prettier-ignore
description: Architecture Decision Record (ADR) for keeping Dockerized qcom-x1e kernel source and object builds on a Linux case-sensitive filesystem.
---

## Context

[ADR020](adr-0020-dockerized-arm64-kernel-build.md) introduced Dockerized
ARM64 kernel builds. [ADR021](adr-0021-git-fallback-kernel-build-toolchain.md)
selected the temporary git fallback toolchain, and
[ADR022](adr-0022-docker-kernel-build-without-fakeroot.md) removed fakeroot
from the root-container path.

The first long git fallback build after ADR022 progressed past dependency
setup, source patching, and the former fakeroot failure. It then exposed a
different host-filesystem problem. The Docker wrapper bind-mounted the host
work directory at `/work`, and the inner helper cloned the Linux kernel source
under that mount.

On default macOS APFS, paths that differ only by case collide. The Linux kernel
tree contains case-distinct files such as `net/netfilter/xt_DSCP.c` and
`net/netfilter/xt_dscp.c`. Git warned that those paths collided during checkout,
and the later kernel build failed because `net/netfilter/xt_DSCP.o` could not
be made from a missing source file.

## Decision

The Docker kernel wrapper will no longer use the host bind mount as the
default kernel source and object build directory.

The wrapper will keep the host `--work-dir` for Docker control files, logs
captured by the caller, and copied build artifacts. The actual inner
`build-sp11-qcom-x1e-kernel.sh --work-dir` path will default to `/linux-work`,
backed by the Docker named volume `sp11-qcom-x1e-kernel-build`.

After a successful container build, the wrapper's inner script will copy
generated qcom-x1e `.deb` packages and build manifests from `/linux-work` back
to the host work directory under `artifacts/`. Existing `--copy-to-payload`
behavior will then copy those host-visible package artifacts into
`payload/kernel-debs/`.

The wrapper will still allow `--container-work-dir /work` for operators who
intentionally provide a case-sensitive host filesystem. When `/work` is used,
the wrapper will refuse to continue if the host work directory behaves as
case-insensitive.

## Consequences

Dockerized kernel builds work on macOS hosts without losing case-distinct Linux
kernel files during checkout.

The source and object tree are no longer directly browsable under the host
work directory by default. Operators can inspect them from a temporary
container attached to the Docker volume, or remove the volume to force a fresh
checkout.

The Docker volume can grow large and persists across runs. `--reset-source`
resets the source tree inside the volume for the next build, while
`docker volume rm sp11-qcom-x1e-kernel-build` discards the full cached work
volume.

The host work directory remains the stable place to look for copied package
artifacts, wrapper-generated control files, and logs captured by the shell
command running the wrapper.
