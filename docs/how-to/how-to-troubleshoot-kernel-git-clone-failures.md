---
id: how-to-troubleshoot-kernel-git-clone-failures
title: "Troubleshoot Kernel Git Clone `fetch-pack` Failures"
# prettier-ignore
description: "How-to guide for resolving `fatal: fetch-pack: invalid index-pack output` when build-sp11-qcom-x1e-kernel.sh or build-sp11-qcom-x1e-kernel-docker.sh clones the qcom-x1e kernel git branch."
---

# How To: Troubleshoot Kernel Git Clone `fetch-pack` Failures

Use this procedure when `scripts/build-sp11-qcom-x1e-kernel.sh` (or the Docker
wrapper `scripts/build-sp11-qcom-x1e-kernel-docker.sh`) fails during the
kernel source clone with an error like:

```text
Cloning into '/linux-work/source/git-qcom-x1e-7.0'...
fatal: fetch-pack: invalid index-pack output
Docker kernel build failed; inspect the log above for the first build error.
If the source tree was partially prepared, rerun with --reset-source after fixing the failure.
```

The same procedure applies to pack-transfer errors such as:

```text
fatal: could not open '.git/objects/pack/tmp_pack_...': No such file or directory
```

## Purpose

The `--source git` path clones the requested kernel git branch. The default is
`https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute`
branch `qcom-x1e-7.0`. New checkouts use `git clone --depth 1 --branch`, which
avoids downloading the repository's full history, but the checkout and pack
can still be large enough to expose memory, network, or disk problems.

`fetch-pack: invalid index-pack output` means the `index-pack` process that
receives and decompresses the pack stream from the remote died or produced
invalid output before the clone completed. This is a transport/resource
failure, not a problem with this repo's scripts and not a sign that the kernel
repository itself is broken.

This guide covers the three common root causes, explains what
`--reset-source` actually means (it is not a "dirty tree" warning), and gives
fallbacks.

## Prerequisites

- A build host that has already gotten past Docker startup and dependency
  installation (i.e. the failure happens at `Cloning into ...`, not earlier).
  If you are instead hitting `exec format error` before dependencies install,
  see
  [how-to-troubleshoot-docker-exec-format-error.md](how-to-troubleshoot-docker-exec-format-error.md).
- `sudo` access on the build host (to inspect logs and free resources).
- Enough free disk for the kernel source tree (several GB) plus the build
  output (the wrapper requires at least 40 GiB free, enforced by
  `scripts/build-sp11-qcom-x1e-kernel.sh`).

## Procedure

### 1. Identify the root cause

The `index-pack` process is killed or corrupted most often by, in order of
likelihood:

1. **Out of memory.** `index-pack` is RAM-hungry on large repositories. The
   kernel OOM killer terminates it, and git reports `invalid index-pack
   output`. This is especially common inside a VM or under QEMU emulation
   where memory is constrained.
2. **Network interruption or corruption.** The pack stream from
   `git.launchpad.net` is truncated by a flaky connection, a proxy, or a
   captive portal, and `index-pack` receives garbage.
3. **Disk full mid-clone.** The pack file is large; if the filesystem fills
   up while `index-pack` is writing, it dies.

Check the kernel ring buffer and the Docker/container journal for OOM kills
first, because that is the most common cause and is silent in the git output:

```bash
sudo dmesg | grep -i -E 'oom|killed process|index-pack' | tail -n 40
```

If you are running inside Docker, also check the host's `dmesg` (the OOM kill
is logged on the host, not inside the container):

```bash
sudo journalctl -k --no-pager -n 200 | grep -i -E 'oom|killed process'
```

Check free disk and free memory on the build host:

```bash
df -h "$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')"
free -h
```

### 2. Fix the resource limit

- **If `index-pack` was OOM-killed:** increase available memory. For a Docker
  build host, raise the VM's RAM (8 GiB is a minimum for the kernel clone
  under emulation; more is better). For an on-device build on the Surface,
  close other applications. You can also reduce `index-pack`'s memory by
  lowering the window size — but the wrapper does not expose that, so the
  simplest fix is more RAM.

- **If the disk is full:** free space under the Docker data root and the work
  directory. The persistent Docker source/build volume
  `sp11-qcom-x1e-kernel-build` can hold a partial clone from a previous
  failed run. Remove it explicitly:

  ```bash
  docker volume rm sp11-qcom-x1e-kernel-build
  ```

  Also remove the host control directory if it has grown:

  ```bash
  rm -rf build/docker-sp11-qcom-x1e-kernel
  ```

- **If the network is the problem:** retry on a stable wired connection. If
  `git.launchpad.net` is slow or unreliable from your network, you can clone
  the repository once on a reliable host and copy it into the build volume,
  but that is advanced; the simpler path is to retry or use the `apt` source
  mode fallback below.

### 3. Retry with `--reset-source`

A failed `git clone` can leave a partial directory behind. Rerun with
`--reset-source` so the helper discards generated files from a valid checkout,
or replaces a non-git source directory before cloning again. If the partial
directory contains a damaged `.git` directory and reset itself fails, remove
that specific checkout or the Docker work volume, then retry.

#### What `--reset-source` actually means

`--reset-source` does **not** refer to this repository's working tree. It acts
on the kernel source checkout in the build work directory. In git mode:

- With a valid Git checkout, `--reset-source` runs `git reset --hard` and
  `git clean -ffdx`, then checks out and resets the requested remote branch or
  tag. This preserves the expensive checkout while removing prior build and
  patch state.
- With an existing non-git source directory, `--reset-source` removes that
  directory and performs a fresh shallow clone.
- Without `--reset-source`: if the directory already exists, the helper
  fetches and resets a branch, or resets directly to an already-present tag.
  It rejects local changes, untracked files, local-only commits, and non-git
  source directories.

The Docker wrapper always appends the `--reset-source` hint after a failure.
It is generic recovery advice for a partially prepared source tree, not a
diagnosis that the kernel repository is broken.

Retry the build with `--reset-source`:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload \
  --reset-source \
  --jobs 4 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-build-$(date +%Y%m%d-%H%M%S).log
```

### 4. If the clone keeps failing, switch to `apt` source mode

The `apt` source mode downloads a source package tarball instead of cloning
the full git history, which avoids the large `index-pack` entirely. It needs
`deb-src` entries enabled for the qcom-x1e repositories on the build host
container.

On the Surface, collect the running kernel's source metadata:

```bash
./scripts/collect-sp11-kernel-source-metadata.sh \
  --out sp11-kernel-source.env
```

Then on the Docker build host, run with `--metadata` instead of `--source git`:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload \
  --reset-source
```

See [how-to-build-patched-qcom-x1e-kernel.md](how-to-build-patched-qcom-x1e-kernel.md)
for the full `apt` source mode procedure.

## Expected Output

After fixing the resource limit and retrying with `--reset-source`, a new
checkout should complete:

```text
Cloning into '/linux-work/source/git-qcom-x1e-7.0'...
remote: Enumerating objects: ..., done.
remote: Counting objects: 100% (...), done.
remote: Compressing objects: 100% (...), done.
remote: Total ... (delta ...), reused ... (delta ...), pack-reused ...
Receiving objects: 100% (...), done.
Resolving deltas: 100% (...), done.
```

The build then proceeds to patch application and `debian/rules`. Common build
dependencies are installed before the clone; git-source-specific build
dependencies are installed after patching.

## Validation

Confirm the source tree is a complete git checkout:

```bash
docker run --rm -v sp11-qcom-x1e-kernel-build:/linux-work \
  --platform linux/arm64 ubuntu:25.10 \
  bash -c 'apt-get update && apt-get install -y --no-install-recommends git >/dev/null && git -C /linux-work/source/git-qcom-x1e-7.0 status'
```

A clean checkout reports `working tree clean` on the `qcom-x1e-7.0` branch.
Then rerun the full build command and inspect the inner build log for the
first compile error, if any.

Passing validation means the kernel source tree is complete and the build can
proceed past the clone. It does not prove the kernel compile itself will
succeed; a patch may fail to apply against a newer source version, or a build
dependency may be missing.

## Privacy and Safety

Removing the Docker volume `sp11-qcom-x1e-kernel-build` discards the kernel
source checkout and any partial build output. It does not affect the host work
directory (`build/docker-sp11-qcom-x1e-kernel`) or the payload directory
(`payload/kernel-debs/`), but those may also hold stale artifacts from a
failed run — remove them with `rm -rf` if you want a fully clean retry.

Do not commit generated kernel source trees, `.deb` packages, or build logs
that may contain local network configuration.

## Troubleshooting

If `dmesg` shows `index-pack` was OOM-killed and you cannot add more RAM, try
the `apt` source mode fallback above, which avoids the large git clone
entirely.

If the clone fails with a network error rather than `invalid index-pack`, test
connectivity to the Launchpad git host:

```bash
git ls-remote https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute qcom-x1e-7.0
```

If that fails or is very slow, retry on a different network or use `apt`
source mode.

If you are building on the Surface itself (on-device build, no Docker) and the
clone fails the same way, the same causes apply — check `dmesg` for OOM kills
and `df -h` for free disk. The on-device build has no QEMU overhead but the
Surface's RAM is still finite.

## Native ARM64 fallback: build on the Surface directly

If the Docker build host is a constrained VM and the clone keeps failing on
memory, build the kernel natively on the Surface Pro 11. This avoids both
QEMU emulation and the VM's memory limit.

### You do not need SP11DATA for a direct repo clone

The `SP11DATA` variable referenced elsewhere in these docs is the mount point
of the live USB's data partition. It is only required when running the
post-install support scripts from the USB stick. If you have cloned this
repository directly onto installed Ubuntu on the Surface, you do not need
`SP11DATA` — run the build helper from the repo root:

```bash
cd /path/to/linux-surface-pro-11-oe
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --source git \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

The helper locates its own patch directory from the repository root, so it
works from any checkout. If a previous clone failed on the Surface, add
`--reset-source` to clear the partial checkout before retrying.

Once built, install the generated packages with the fallback-kernel guard:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

### If you are running from the live USB

If you are following the post-install USB flow, mount the `SP11DATA` partition
first and run from its `support` directory:

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found; run lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --source git \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

The on-device build is slow on the Snapdragon X Elite but runs natively with
no QEMU overhead and no VM memory limit. See the "On-Device Build Fallback"
section of
[how-to-build-patched-qcom-x1e-kernel.md](how-to-build-patched-qcom-x1e-kernel.md)
for the full procedure.

## Related Documents

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [Troubleshoot Docker `exec format error` on x86_64 Linux Build Hosts](how-to-troubleshoot-docker-exec-format-error.md)
- [Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts](how-to-troubleshoot-linux-docker-overlay.md)
- [ADR021: Git Fallback Kernel Build Toolchain](../adr/adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR023: Docker Kernel Build Case-Sensitive Work Volume](../adr/adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
