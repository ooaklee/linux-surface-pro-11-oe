---
id: how-to-repeat-kernel-build-for-new-release
title: "Repeat Patched Kernel Build for a New qcom-x1e Release"
# prettier-ignore
description: How-to guide for rebuilding the Surface Pro 11 Wi-Fi rfkill patched qcom-x1e kernel when a new Ubuntu kernel release ships.
---

# How To: Repeat Patched Kernel Build for a New qcom-x1e Release

Use this procedure when Ubuntu ships a new `qcom-x1e` kernel release (e.g.
`7.0.0-40-qcom-x1e`) and you need to produce a matching patched build with the
same Surface Pro 11 Wi-Fi rfkill fixes.

## Purpose

The Ubuntu Snapdragon X concept kernel tracks upstream `qcom-x1e-7.0`. Each
release bumps the ABI (e.g. `7.0.0-32` → `7.0.0-40`). The Surface Pro 11
Wi-Fi rfkill patches in `patches/ubuntu-qcom-x1e-7.0/` must be applied to the
matching source tree. This procedure captures the steps to go from "new kernel
is apt-upgraded on the Surface" to "bootable patched kernel with Wi-Fi working".

Two build paths are covered:

- **Docker (recommended)**: Collect source metadata on the Surface, build on a
  stronger ARM64 machine with Docker.
- **On-device (fallback)**: Build directly on the Surface after `apt upgrade`
  lands the new kernel.

## Prerequisites

- Surface Pro 11 booted into installed Ubuntu with the new unpatched qcom-x1e
  kernel (e.g. `7.0.0-40-qcom-x1e`).
- `apt update && apt upgrade` completed, `uname -r` confirms the new kernel.
- The `linux-surface-pro-11-oe` repository checkout is up to date.
- 40 GB free disk where the build runs.
- Docker (for the off-device path) with `linux/arm64` container support.

## Procedure

### 0. Rebase the checkout

```bash
cd linux-surface-pro-11-oe
git pull --rebase origin main
```

Check that `patches/ubuntu-qcom-x1e-7.0/` still contains the two rfkill patches.
If Ubuntu has significantly changed the kernel tree, the patches may need
refreshing (see Troubleshooting).

### 1. Collect source metadata on the Surface

Boot the installed Surface with the new kernel, then export the matching source
metadata:

```bash
./scripts/collect-sp11-kernel-source-metadata.sh \
  --out /tmp/sp11-kernel-source.env
```

This writes:

```text
SP11_KERNEL_RELEASE='7.0.0-40-qcom-x1e'
SP11_SOURCE_PACKAGE='linux-qcom-x1e'
SP11_SOURCE_VERSION='7.0.0-40.40'
SP11_BUILD_TARGET='binary-qcom-x1e'
```

The exact source package can change between Ubuntu kernel streams. Treat the
block above as an example and use whatever `collect-sp11-kernel-source-metadata.sh`
prints.

Transfer `sp11-kernel-source.env` to the repository root on the build host:

```bash
scp surface:/tmp/sp11-kernel-source.env ./sp11-kernel-source.env
```

Replace `surface` with the SSH host name or address for the Surface. Skip this
transfer for on-device builds; `build-sp11-qcom-x1e-kernel.sh` derives the
metadata locally.

### 2. Build the patched kernel

**Option A: Docker (preferred)**

On the build host:

```bash
cd linux-surface-pro-11-oe

./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

This clones the matching source package from apt inside an ARM64 container,
applies the rfkill patches, builds the full kernel, and copies the resulting
`.deb` files into `payload/kernel-debs/`.

If the container cannot reach the apt source repository, provide the matching
`.sources` file from the Surface:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata sp11-kernel-source.env \
  --apt-sources /path/to/qcom-x1e.sources \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

For a bring-up-only build without matching source repositories, use the git
fallback (builds from the public `qcom-x1e-7.0` branch, note ABI may not match):

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

**Option B: On-device (fallback)**

On the Surface directly:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

The helper derives the source package and version from the running kernel
packages. Pass `--source-version candidate` only if you want to build the apt
candidate instead.

On-device builds do not copy generated packages into `payload/kernel-debs/`.
Install from the on-device work directory in step 4, or copy the generated
`.deb` files to `payload/kernel-debs/` yourself before rebuilding the USB
image.

### 3. Rebuild and write the live USB image

For the Docker path, rebuild the USB image so `payload/kernel-debs/` is
available on the `SP11DATA` partition:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso path/to/ubuntu-x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate

./scripts/write-image-to-macos-disk.sh build/sp11-ubuntu-live-direct.img /dev/diskX
```

Replace `/dev/diskX` with the verified removable USB disk.

For the on-device path, this USB rebuild is optional unless you want a recovery
USB carrying the new packages. The build artifacts already live under
`$HOME/sp11-qcom-x1e-kernel-build` on the Surface.

### 4. Install the patched packages on the Surface

Boot installed Ubuntu, mount `SP11DATA`:

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
```

For the Docker path, install the packages copied through the USB payload:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only
```

For the on-device path, install from the local build work directory instead:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

The helper refuses to install if no older qcom-x1e kernel exists as GRUB
fallback. Keep the previous kernel installed.

### 5. Reboot and validate

```bash
sudo reboot
```

After reboot into the patched kernel:

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
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Passing validation means:
- `DT has disable-rfkill`
- Wi-Fi `phy0` no longer reports `Hard blocked: yes`
- `uname -r` matches the patched ABI

## Expected Output

A bootable qcom-x1e kernel with ath12k `disable-rfkill` support matching the
Ubuntu kernel release running on the Surface.

Generated artifacts under `payload/kernel-debs/`:

```text
linux-headers-<abi>_<version>_arm64.deb
linux-image-<abi>_<version>_arm64.deb
linux-modules-<abi>_<version>_arm64.deb
```

## What Changes Between Releases

| Item | Changes? | Notes |
|------|----------|-------|
| Kernel ABI | Yes | `7.0.0-32` → `7.0.0-40`, derived from `uname -r` |
| Source package | Possibly | Example: `linux-qcom-x1e`; check `dpkg -s linux-modules-$(uname -r)` |
| Source version | Yes | `7.0.0-32.32` → `7.0.0-40.40` |
| Build target | No | Always `binary-qcom-x1e` |
| Patches | No change | `patches/ubuntu-qcom-x1e-7.0/*.patch` — unless Ubuntu tree diverges |
| rfkill fix | No change | Same `disable-rfkill` property on Denali WCN7850 node |

The `collect-sp11-kernel-source-metadata.sh` script captures everything that
changes automatically.

## Privacy and Safety

- Do not commit generated `.deb` files, source trees, or kernel artifacts.
- Keep the previous qcom-x1e kernel installed as a GRUB fallback.
- Keep the direct live USB nearby for recovery.
- `build/`, `payload/kernel-debs/`, and `*.deb` are `.gitignore`d.

## Troubleshooting

**Patches don't apply.** The Ubuntu qcom-x1e source tree has diverged. Inspect
the prepared source directory printed by the build helper (`Using source tree:
...`), refresh the patches against that tree, and rerun the build. For example,
with the git fallback source layout:

```bash
cd source/git-qcom-x1e-7.0
# Manually rework the two patches to match the new tree
git diff HEAD > ../../patches/ubuntu-qcom-x1e-7.0/0001-...patch
git diff HEAD -- arch/arm64/boot/dts/qcom/ \
  > ../../patches/ubuntu-qcom-x1e-7.0/0002-...patch
```

Then rerun the build.

**Docker build fails with libfakeroot errors.** The container already runs as
root. The wrapper passes `--no-fakeroot`. Make sure you're using the default
container path.

**Case-sensitivity warnings.** Use the default `/linux-work` Docker volume path.
Do not force `--container-work-dir /work` on case-insensitive filesystems (e.g.
macOS APFS).

**Out of disk space.** Remove stale build volumes and directories:

```bash
rm -rf build/docker-sp11-qcom-x1e-kernel
docker volume rm sp11-qcom-x1e-kernel-build
```

Then retry. A full kernel build needs ~30 GiB.

**apt source fails.** Enable matching `deb-src` entries for the repositories
that provide the qcom-x1e kernel packages, then run `sudo apt update`. Or use
`--source git` for a bring-up fallback build from the public branch.

## Related Documents

- [How To: Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
- [Surface Pro 11 Wi-Fi rfkill test after qcom-x1e upgrade](../installed-wifi-rfkill-upgrade-test-20260613.md)
