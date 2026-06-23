---
id: how-to-troubleshoot-linux-docker-overlay
title: "Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts"
# prettier-ignore
description: How-to guide for resolving Docker overlay2 mount errors when running build-sp11-qcom-x1e-kernel-docker.sh on Linux hosts.
---

# How To: Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts

Use this procedure when `scripts/build-sp11-qcom-x1e-kernel-docker.sh` fails
on a Linux host with a Docker daemon error like:

```text
docker: Error response from daemon: failed to mount /tmp/containerd-mount...:
mount source: "overlay", target: "/tmp/containerd-mount...", fstype: overlay,
flags: 0, data: "...", err: invalid argument
```

## Purpose

The Docker wrapper in this repo issues a plain `docker run` with a bind mount
and a named volume; it does not request any exotic storage backend. The error
above comes from the Docker daemon's `overlay2` snapshotter, not from this
repo's scripts. On Linux hosts this failure is almost always caused by one of:

1. **Docker's `data-root` is on a filesystem that does not support the
   `overlay` driver** — most commonly a ZFS or Btrfs dataset, an NFS/SSHFS
   mount, an encrypted home (`ecryptfs`), or any filesystem mounted without
   `xattr` support.
2. **A stale `containerd` snapshotter state** left behind after a Docker or
   `containerd` upgrade, where existing snapshot metadata no longer mounts.
3. **Docker-in-Docker without `--privileged`** (for example inside a CI runner
   or a tool that spawns nested containers), where the inner daemon has no
   overlayfs support and no `fuse-overlayfs` or `vfs` fallback is configured.

This guide walks through the three common fixes and a repo-specific fallback
that avoids Docker entirely.

## Prerequisites

- A Linux build host with Docker installed.
- `sudo` access on the build host to stop/start Docker and inspect mount
  state.
- A working path to this repository root, so the wrapper script can be run.

## Procedure

### 1. Confirm the failure is the Docker daemon, not this repo's wrapper

Run the smallest possible container. If it fails the same way, the daemon or
filesystem is the root cause:

```bash
docker run --rm hello-world
```

If `hello-world` fails with the same `overlay` mount error, continue with the
fixes below. If `hello-world` succeeds, re-run the kernel build with
`--dry-run` to inspect the generated Docker command and verify the host paths
exist:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload \
  --dry-run
```

### 2. Clear stale containerd overlay snapshots and restart Docker

This is the fastest fix and the most common cause after a Docker upgrade.
Stopping Docker and `containerd`, removing the stale overlay snapshot state,
and restarting is usually enough:

```bash
sudo systemctl stop docker docker.socket containerd
sudo rm -rf /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
sudo systemctl start docker
```

Then rerun the kernel build command unchanged:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

### 3. Check where Docker stores data and what filesystem it is

If clearing snapshots did not help, inspect Docker's storage configuration:

```bash
docker info 2>/dev/null | grep -E 'Docker Root Dir|Storage Driver|Backing Filesystem'
df -T "$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')"
```

If `Docker Root Dir` is on ZFS, Btrfs, or anything other than `ext4` or `xfs`
(or is an overlay-incompatible mount such as an encrypted home or network
filesystem), the `overlay2` driver will fail exactly like this. Move Docker's
data root to an `ext4` or `xfs` location by creating or editing
`/etc/docker/daemon.json`:

```json
{
  "data-root": "/path/to/ext4-or-xfs/docker"
}
```

Then restart Docker:

```bash
sudo mkdir -p /path/to/ext4-or-xfs/docker
sudo systemctl restart docker
```

Re-run `docker run --rm hello-world` to confirm Docker now starts a container
successfully before retrying the kernel build.

### 4. Handle Docker-in-Docker environments

If the build host is itself a container (for example a CI runner, or any nested Docker setup), the inner Docker
daemon has no overlayfs support unless it was started with `--privileged` and
the host exposes overlayfs. The cleanest fix is to run the kernel build
directly on the host Linux machine rather than nested.

If nesting is unavoidable, configure the inner daemon to use the `vfs` storage
driver (slow but works anywhere) by setting in `/etc/docker/daemon.json`
inside the nested daemon:

```json
{
  "storage-driver": "vfs"
}
```

Then restart the nested Docker daemon. This is a last resort; `vfs` is slow and
disk-hungry for kernel builds.

### 5. Fallback: skip Docker entirely with the on-device build

This repo documents an on-device build path that does not need Docker at all.
See the "On-Device Build Fallback" section of
[how-to-build-patched-qcom-x1e-kernel.md](how-to-build-patched-qcom-x1e-kernel.md).
Run it on the Surface itself:

```bash
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

It will be slow on the Snapdragon X Elite but avoids the overlay problem
entirely. Once built, install the packages with:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

## Expected Output

After applying the relevant fix, the Docker daemon should start a container
successfully:

```bash
docker run --rm hello-world
```

```text
Hello from Docker!
This message shows that your installation appears to be working correctly.
...
```

And the kernel build wrapper should proceed past container start into the
inner build helper, instead of failing with the overlay mount error.

## Validation

Confirm the Docker daemon is healthy before retrying the full kernel build:

```bash
docker info --format '{{.Driver}}: {{.DriverStatus}}'
docker run --rm hello-world
```

Passing validation means the daemon's storage driver can mount a container
filesystem. It does not prove the kernel build itself will succeed; rerun the
full `build-sp11-qcom-x1e-kernel-docker.sh` command and inspect the inner
build log for source/package errors.

## Privacy and Safety

The `rm -rf /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/`
command removes stale snapshot metadata only; it does not touch named volumes
such as `sp11-qcom-x1e-kernel-build`, so existing kernel source checkouts in
that volume are preserved. If you also want to discard the persistent Docker
source/build volume, remove it explicitly:

```bash
docker volume rm sp11-qcom-x1e-kernel-build
```

Before committing any logs or derived summaries, check that no local
workstation paths, account names, network addresses, tokens, or secrets are
present.

## Troubleshooting

If `docker run --rm hello-world` still fails after clearing snapshots, double
check that Docker's `data-root` is on a filesystem that supports overlayfs
(`ext4` or `xfs`). ZFS and Btrfs need their own Docker storage drivers; do
not force `overlay2` on them.

If moving the `data-root` does not help, inspect the kernel ring buffer and
journal for overlayfs mount errors:

```bash
sudo journalctl -u docker --no-pager -n 200
sudo dmesg | tail -n 200
```

If the build host is itself a container, confirm with `cat /proc/1/cgroup` or
`ls /.dockerenv` and switch to a host-level build or the `vfs` storage driver
fallback described above.

If none of the Docker fixes are acceptable, use the on-device build path from
the "Fallback" section. It is slower but has no Docker dependency.

## Related Documents

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
- [ADR023: Docker Kernel Build Case-Sensitive Work Volume](../adr/adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
