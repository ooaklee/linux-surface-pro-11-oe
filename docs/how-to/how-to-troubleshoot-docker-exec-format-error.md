---
id: how-to-troubleshoot-docker-exec-format-error
title: "Troubleshoot ARM64 Container Execution"
# prettier-ignore
description: Diagnose an exec format error from linux-armer's native ARM64 kernel build on a non-ARM64 host.
---

# How To: Troubleshoot ARM64 Container Execution

Last reviewed: 2026-08-30

`linux-armer kernel build` deliberately runs the maintained recipe in a Linux
ARM64 container. An `exec format error` on an x86-64 Linux host normally means
the Docker daemon cannot execute ARM64 binaries.

## Confirm the failure boundary

```sh
uname -m
docker version
docker info
linux-armer doctor --workspace .
linux-armer kernel build --dry-run
```

Read the first build or daemon error. Do not diagnose a later generic failure
message in isolation. The dry run prints the exact pinned container reference
without invoking Docker. Test that reference directly:

```sh
docker run --rm --platform linux/arm64 \
  <pinned-container-reference-from-the-dry-run> \
  /bin/uname -m
```

The expected output is `aarch64`. Use the complete digest-qualified reference
from the plan, not a mutable tag.

## Restore ARM64 container support

- On Docker Desktop, enable its supported Linux ARM64 emulation and restart the
  Docker engine.
- On a managed Linux builder, ask the administrator to provide persistent
  ARM64 `binfmt` support through the host's documented container-platform
  configuration.
- On a native ARM64 host, verify that Docker is using the expected daemon and
  that `docker info` does not report an unexpected remote context.

Avoid ad-hoc privileged registration commands copied from untrusted sources;
they change host-wide executable handling and may disappear after reboot.

## Retry safely

```sh
linux-armer kernel build --dry-run
linux-armer kernel build \
  --work-dir build/linux-armer/kernel-work-retry \
  --output-dir build/linux-armer/kernel-retry
```

Use a fresh output directory. If the error persists before source preparation,
it remains a host container-runtime problem rather than a kernel source or
recipe failure.

## Acceptance criteria

- `doctor` passes its required Docker and workspace checks.
- The digest-qualified ARM64 container probe prints `aarch64`.
- The real build publishes a fresh package closure.
- `linux-armer kernel inspect <output-directory>` accepts the result.
