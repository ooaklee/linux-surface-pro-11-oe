---
id: how-to-troubleshoot-docker-exec-format-error
title: "Troubleshoot Docker `exec format error` on x86_64 Linux Build Hosts"
# prettier-ignore
description: How-to guide for resolving Docker `exec format error` when running build-sp11-qcom-x1e-kernel-docker.sh on x86_64 Linux hosts that lack QEMU binfmt for arm64.
---

# How To: Troubleshoot Docker `exec format error` on x86_64 Linux Build Hosts

Use this procedure when `scripts/build-sp11-qcom-x1e-kernel-docker.sh` fails on
a Linux host with an error like:

```text
exec /work/docker-build-inside.sh: exec format error
Docker kernel build failed; inspect the log above for the first build error.
```

## Purpose

The kernel build wrapper runs an ARM64 Ubuntu container
(`--platform linux/arm64`, the default at
`scripts/build-sp11-qcom-x1e-kernel-docker.sh:5`). Docker Desktop on macOS and
Windows ships QEMU user-mode emulation built in, so ARM64 containers run
transparently there. Plain Docker on an x86_64 Linux host does **not** register
the QEMU binfmt handlers automatically, so the host kernel cannot execute the
ARM64 binaries inside the container — beginning with the `#!/usr/bin/env bash`
shebang of the generated `/work/docker-build-inside.sh` script.

The result is `exec format error` (`ENOEXEC`), which looks like the script
path is wrong but is actually a host execution-architecture problem.

This guide registers QEMU binfmt on the x86_64 Linux host so the ARM64
container can run, and documents a native ARM64 fallback that avoids emulation
entirely.

## Prerequisites

- A Linux build host with Docker installed and working (run
  `docker run --rm hello-world` first; if that fails, fix Docker before this
  guide — see
  [how-to-troubleshoot-linux-docker-overlay.md](how-to-troubleshoot-linux-docker-overlay.md)).
- `sudo` access on the build host (registering binfmt handlers is privileged).
- Internet access to pull `multiarch/qemu-user-static`.

## Procedure

### 1. Confirm the host cannot run ARM64 containers

Run the smallest possible ARM64 container:

```bash
docker run --rm --platform linux/arm64 ubuntu:25.10 uname -m
```

If this also fails with `exec format error`, the host lacks QEMU binfmt
support for `aarch64`. If it prints `aarch64`, the binfmt handlers are already
registered and the failure is elsewhere — collect the full build log and re-run
the wrapper with `--dry-run` to inspect the generated Docker command.

### 2. Register QEMU user-mode emulation for arm64

Register the binfmt handlers with the one-shot `multiarch/qemu-user-static`
image. This requires `--privileged` because it writes to `/proc/sys/fs/binfmt_misc`:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

The `--reset -p yes` flags clear any stale handlers and register QEMU for all
supported guest architectures, including `aarch64`.

### 3. Verify ARM64 containers now run

Re-run the ARM64 smoke test:

```bash
docker run --rm --platform linux/arm64 ubuntu:25.10 uname -m
```

It should print `aarch64`. If it still fails, confirm the binfmt registration
persisted:

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || \
  ls /proc/sys/fs/binfmt_misc/ | grep -i aarch64
```

If the handler is missing after the registration command, the host kernel may
not have `binfmt_misc` mounted. Mount it and re-register:

```bash
sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

### 4. Rerun the kernel build

Once `uname -m` returns `aarch64`, rerun the wrapper unchanged. For example,
the git fallback path from the README:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload \
  --reset-source \
  --jobs 4 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-build-$(date +%Y%m%d-%H%M%S).log
```

### 5. Expect emulation to be slow

QEMU user-mode emulation is correct but slow. A kernel build that takes under
an hour on a native ARM64 machine can take several hours on an x86_64 host
under emulation. Keep the build machine on AC power, give Docker enough disk
(the kernel source/build tree is large), and do not interrupt the clone/compile
phases.

If the build host is a VM, give it as much RAM as practical — `index-pack`
during the kernel `git clone` is memory-hungry and can be killed by the OOM
killer. See
[how-to-troubleshoot-kernel-git-clone-failures.md](how-to-troubleshoot-kernel-git-clone-failures.md)
for that failure mode.

## Expected Output

After registering QEMU binfmt, the ARM64 smoke test prints the guest
architecture:

```text
aarch64
```

And the kernel build wrapper proceeds past container start into the inner
build helper (apt setup, source clone, patch application, `debian/rules`),
instead of failing immediately with `exec format error`.

## Validation

Confirm the binfmt handler is registered and an ARM64 binary can execute:

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64 | grep -E '^interpreter|^flags'
docker run --rm --platform linux/arm64 ubuntu:25.10 uname -m
```

Passing validation means the host can execute ARM64 container binaries under
QEMU. It does not prove the kernel build will succeed; rerun the full
`build-sp11-qcom-x1e-kernel-docker.sh` command and inspect the inner build log
for source, dependency, or compile errors.

## Privacy and Safety

Registering QEMU binfmt handlers is a host-level change that persists across
Docker restarts (it is registered in the kernel, not in Docker). It is safe to
leave registered. To remove it later:

```bash
echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-aarch64
```

## Troubleshooting

If `docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`
itself fails with a permission error, confirm Docker is installed with root
privileges and that `binfmt_misc` support is compiled into the host kernel
(`zgrep BINFMT_MISC /proc/config.gz` or check the distro kernel config).

If the ARM64 smoke test works but the kernel build still fails with
`exec format error`, the wrapper may have been invoked with an explicit
`--platform` that does not match. Check the generated Docker command with
`--dry-run`:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git --work-dir build/docker-sp11-qcom-x1e-kernel --dry-run
```

The `--platform` line should be `linux/arm64` (the default). Do not set
`--platform linux/amd64`; the qcom-x1e kernel packages must be built for
ARM64.

## Native ARM64 fallback: build on the Surface directly

If QEMU emulation is too slow or unavailable, build the kernel natively on the
Surface Pro 11 itself. This avoids Docker and QEMU entirely.

### You do not need SP11DATA for a direct repo clone

The `SP11DATA` variable referenced elsewhere in these docs is the mount point
of the live USB's data partition. It is only required when running the
post-install support scripts from the USB stick. If you have cloned this
repository directly onto installed Ubuntu on the Surface, you do not need
`SP11DATA` — run the build helper from the repo root:

```bash
cd /path/to/linux-surface-pro-11-oe
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

The helper locates its own patch directory via `repo_dir`
(`scripts/build-sp11-qcom-x1e-kernel.sh:97`), so it works from any checkout.

The default source mode is `apt`, which derives the source package and version
from the running kernel and needs `deb-src` entries enabled for the qcom-x1e
repositories. If `apt source` fails, retry with `--source git` to use the
public git branch instead (slower, larger clone, but no `deb-src` needed):

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --source git \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
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
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

Once built, install the generated packages with the fallback-kernel guard:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

The on-device build is slow on the Snapdragon X Elite but runs natively with
no QEMU overhead. See the "On-Device Build Fallback" section of
[how-to-build-patched-qcom-x1e-kernel.md](how-to-build-patched-qcom-x1e-kernel.md)
for the full procedure.

## Related Documents

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts](how-to-troubleshoot-linux-docker-overlay.md)
- [Troubleshoot Kernel Git Clone `fetch-pack` Failures](how-to-troubleshoot-kernel-git-clone-failures.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
- [ADR021: Git Fallback Kernel Build Toolchain](../adr/adr-0021-git-fallback-kernel-build-toolchain.md)
