---
id: how-to-troubleshoot-linux-docker-overlay
title: "Troubleshoot Docker Storage Failures on Linux Build Hosts"
# prettier-ignore
description: Diagnose Docker overlay and container-storage failures affecting native Lexr.sh builds.
---

# How To: Troubleshoot Docker Storage Failures on Linux Build Hosts

Last reviewed: 2026-08-30

Use this procedure when `lexr kernel build` fails before the recipe runs
with a Docker overlay, snapshotter, mount or storage-driver error. These are
daemon or host-storage failures, not kernel compilation failures.

## Collect read-only evidence

```sh
lexr doctor --workspace .
docker version
docker info
docker system df
df -h .
```

The Docker and filesystem commands are intentional bounded external host
diagnostics. `lexr doctor` reports the minimum daemon and workspace
readiness needed by its workflows; it does not claim to inspect or repair the
container engine's complete storage configuration.

Record the Docker server version, storage driver, backing filesystem and the
first daemon error. Redact registry credentials, proxy values, user names and
private paths before sharing a report.

## Check scope

```sh
lexr kernel build \
  --work-dir build/lexr/kernel-work-storage-check \
  --output-dir build/lexr/kernel-storage-check \
  --dry-run
```

The dry run does not invoke Docker. Use it to verify containment, capacity and
resolved policy. A different work directory cannot repair a broken storage
driver, but it distinguishes a path-specific capacity problem from a
daemon-wide failure when the real build is retried.

## Repair through the host owner

- Free ordinary host storage outside Docker when the filesystem is full.
- Use the platform's supported Docker Desktop or daemon recovery procedure.
- On a managed host, give the administrator the storage driver, backing
  filesystem and first daemon error.
- Preserve unrelated images and volumes. Do not run an unreviewed global prune
  or delete Docker's data directory.

After the daemon is healthy, retry with a fresh output directory:

```sh
lexr doctor --workspace .
lexr kernel build \
  --work-dir build/lexr/kernel-work-storage-retry \
  --output-dir build/lexr/kernel-storage-retry
lexr kernel inspect build/lexr/kernel-storage-retry
```

Do not fall back to an untracked host build. The native container workflow is
what records the recipe, toolchain, exact source and closed output needed for
subsequent validation.
