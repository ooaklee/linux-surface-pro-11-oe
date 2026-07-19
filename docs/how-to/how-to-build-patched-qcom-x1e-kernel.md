---
id: how-to-build-patched-qcom-x1e-kernel
title: "Build a Patched qcom-x1e Kernel"
# prettier-ignore
description: How-to guide for building and testing a Surface Pro 11 qcom-x1e kernel with ath12k disable-rfkill support.
---

# How To: Build a Patched qcom-x1e Kernel

Use this procedure when Wi-Fi probes on Surface Pro 11 but remains
hard-blocked by rfkill, and `scripts/troubleshoot-sp11-wifi-rfkill.sh` reports
that the installed ath12k modules do not contain `disable-rfkill` support.

## Purpose

The firmware and board-file helpers are enough for WCN7850 to probe, load
firmware, and create an interface. On Surface Pro 11, Wi-Fi still needs ath12k
to skip rfkill configuration for the Denali WCN7850 devicetree node.

This procedure builds Ubuntu qcom-x1e kernel packages with the targeted
Surface Pro 11 rfkill patches.

## Prerequisites

- Installed Ubuntu on Surface Pro 11, booting from internal NVMe.
- Temporary networking through USB-C Ethernet, USB phone tethering, or another
  non-Wi-Fi path.
- Secure Boot disabled.
- The direct live USB kept nearby as a recovery environment.
- At least 40 GB free disk space for the kernel source, build tree, and
  generated `.deb` packages.
- AC power connected. Kernel builds can take a long time.
- An older known-good qcom-x1e kernel still installed. Do not run
  `apt autoremove` before this experiment.
- For the preferred off-device build: Docker on a host that can run
  `linux/arm64` containers. Native ARM64 is fastest; x86_64 hosts may use QEMU
  emulation and can be much slower.
- Enough Docker storage for a persistent Linux work volume. The host work
  directory only receives control files and copied artifacts; the kernel source
  and object tree are kept in Docker's `sp11-qcom-x1e-kernel-build` volume.

## Procedure

1. Mount the `SP11DATA` USB partition and enter the support directory.

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
cd "$SP11DATA/support"
```

2. Confirm the current failure mode.

```bash
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Continue only if Wi-Fi is still hard-blocked and the ath12k module scan says
`disable-rfkill support not found`.

## Dockerized ARM64 Build

Use this path when you have a stronger build machine available. The Surface
exports the exact qcom-x1e source package metadata, the build host compiles in
a Docker ARM64 Linux container, and the generated packages are copied into the
USB payload.

3. On the Surface, write the running kernel source metadata to `SP11DATA`.

```bash
./scripts/collect-sp11-kernel-source-metadata.sh \
  --out "$SP11DATA/sp11-kernel-source.env"
```

4. Move the USB back to the Docker build host, enter this repository root, then
   build the patched packages.

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

The wrapper runs Docker with `--platform linux/arm64`. The host `--work-dir`
stores Docker control files and copied artifacts. The actual kernel source and
object tree build under `/linux-work` in the Docker volume
`sp11-qcom-x1e-kernel-build`, which keeps the Linux kernel checkout on a
case-sensitive filesystem even when the build host is macOS. Successful builds
copy generated qcom-x1e `.deb` files to
`build/docker-sp11-qcom-x1e-kernel/artifacts/`, then to
`payload/kernel-debs/` when `--copy-to-payload` is set. Because the container
runs as root, the wrapper also runs Ubuntu `debian/rules` directly instead of
through `fakeroot`.

Treat `build/docker-sp11-qcom-x1e-kernel/artifacts/` as managed scratch space.
Real Docker runs clean it inside the container before copying new packages so
stale `.deb` files cannot leak into `payload/kernel-debs/`.

If the container cannot fetch the exact qcom-x1e source version, provide
matching apt source configuration from the same repositories that provided the
installed kernel:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --apt-sources /path/to/qcom-x1e.sources \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

For bring-up only, the Docker wrapper can use the public git branch instead of
apt source metadata:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

Treat git mode as a fallback because it may not match the exact qcom-x1e
package version currently installed on the Surface. Git mode defaults to an
`ubuntu:25.10` container because the current `qcom-x1e-7.0` git branch expects
Rust 1.85 and LLVM 19 during Ubuntu config validation.

### Johan G. 7.1.3 source

The `jg/ubuntu-qcom-x1e-7.1.3-jg-1` tag requires Ubuntu 26.04, the matching
build-compatibility patches, and the standard Surface Pro 11 v2 patch set:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.1.3 patches/sp11-qcom-x1e-7.1.3-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.3-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.1.3-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 4 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-jg-7.1.3-sp11-v2-build-$(date +%Y%m%d-%H%M%S).log
```

If `check-config` reports changed options after moving to a newer `jg-*` tag,
regenerate the tag-specific annotations patch first:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch "jg/ubuntu-qcom-x1e-7.1.3-jg-<n>" \
  --reset-source
```

The helper removes only the stale tag-specific annotations patch. It preserves
the other compatibility patches in the directory. Rerun the original build
command unchanged after confirming the new patch filename.

5. Rebuild and write the live USB image so `payload/kernel-debs/` is copied to
   `SP11DATA`.

Use the same image-builder options that are working for the current test path,
for example the direct-boot image from the README:

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

6. Boot back into installed Ubuntu, mount `SP11DATA`, and install the payload
   packages with the Surface-side fallback guard.

```bash
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only
```

The helper refuses to install if it cannot find another installed qcom-x1e
kernel ABI to use as a GRUB fallback. Do not override that guard unless you are
comfortable recovering through the direct live USB:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only \
  --allow-no-fallback
```

For debugging, inspect the generated package list before installing:

```bash
find "$SP11DATA/payload/kernel-debs" -maxdepth 1 -type f -name '*.deb' -print | sort
```

Use `--install-only` for the actual install so the fallback-kernel guard and
post-install support helper run consistently.

## On-Device Build Fallback

Use this path when Docker is not available.

1. Build from the installed Ubuntu source package version.

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

This can take hours. The helper writes a manifest at:

```text
$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-build-manifest.txt
```

If apt source download fails because source repositories are disabled, enable
source entries for the same Ubuntu/PPA repositories that provide the installed
qcom-x1e packages, run `sudo apt update`, and rerun the command. By default the
helper derives the source package and version from the running kernel packages,
starting with `linux-modules-$(uname -r)`. Use `--source-version candidate`
only when you intentionally want to build the apt source candidate instead.

2. Install the generated qcom-x1e kernel packages.

The helper can do this directly:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

The helper refuses to install if it cannot find another installed qcom-x1e
kernel ABI to use as a GRUB fallback. Do not override that guard unless you are
comfortable recovering through the direct live USB:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only \
  --allow-no-fallback
```

For debugging, inspect the generated package list before installing:

```bash
cat "$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-debs.txt"
```

Use `--install-only` for the actual install so the fallback-kernel guard and
post-install support helper run consistently.

## Reboot and Validate

1. Confirm GRUB still injects the Surface Pro 11 DTB.

```bash
grep -n "devicetree .*sp11-denali" /boot/grub/grub.cfg | head
```

For the verified separate `/boot` layout, the entries should use:

```text
devicetree /sp11-denali.dtb
```

2. Confirm the staged boot DTB contains the rfkill property.

```bash
sudo grep -a -q 'disable-rfkill' /boot/sp11-denali.dtb \
  && echo "/boot/sp11-denali.dtb contains disable-rfkill" \
  || echo "/boot/sp11-denali.dtb is missing disable-rfkill"
```

If the patched kernel ABI is older than another installed qcom-x1e fallback
kernel, the support helper must prefer the rfkill-capable DTB rather than the
newest unpatched DTB. This is recorded in
[ADR025](../adr/adr-0025-rfkill-capable-dtb-selection.md).

3. Reboot and choose the patched kernel.

```bash
sudo reboot
```

If the patched kernel fails, use GRUB advanced options to boot another
known-good qcom-x1e kernel such as the verified `7.0.0-32-qcom-x1e` entry, or
boot the direct live USB and rerun the installed support helper.

## Expected Output

The build should produce qcom-x1e kernel `.deb` packages under the selected
work directory, including image, modules, and headers packages.

After booting the patched kernel, `uname -r` should match the ABI that the
build produced. For the first verified Docker git-fallback build this is
`7.0.0-22-qcom-x1e`, even though the Surface had previously upgraded to
`7.0.0-32-qcom-x1e`. The important validation is whether the loaded ath12k
module and device tree now expose `disable-rfkill`.

## Validation

After reboot, rerun:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Passing validation for the patch experiment means:

- `DT has disable-rfkill`,
- Wi-Fi `phy0` no longer reports `Hard blocked: yes`.

The module string scan is best-effort. If it says support is not found but the
running patched kernel, loaded DTB property, and `rfkill` hard state all match
the expected values, treat the runtime rfkill result as authoritative and move
on to Wi-Fi scan/connect validation.

That proves the rfkill gate moved. It does not prove Bluetooth, suspend,
touchscreen, audio, camera, or long-term Wi-Fi stability.

## Privacy and Safety

Do not commit generated kernel source trees, `.deb` packages, firmware files,
or logs containing local network configuration.

Keep the previous qcom-x1e kernel installed until the patched kernel has booted
and the rfkill result is known. Avoid `apt autoremove` during this experiment.

## Troubleshooting

If apt source download fails, enable matching source repositories for the
running qcom-x1e kernel source and rerun `sudo apt update`.

If a patch does not apply, stop and record the source package version. The
Ubuntu qcom-x1e source may have changed enough that the patch needs to be
refreshed.

If a Docker build fails with `libfakeroot internal error: payload not
recognized!`, make sure the inner build is running in the wrapper's default
root container path. The root container does not need `fakeroot`, and the
wrapper passes `--no-fakeroot` to assert that direct `debian/rules` path during
the long parallel package build.

If a Docker build logs `warning: the following paths have collided` and later
fails with a missing target such as `net/netfilter/xt_DSCP.o`, the kernel
source was checked out on a case-insensitive filesystem. Use the wrapper's
default `/linux-work` Docker volume path. Do not force `--container-work-dir
/work` on default macOS APFS unless `/work` is backed by a case-sensitive
filesystem.

For reruns in the default Docker volume path, pass `--reset-source` when you
want a fresh checkout. The host wrapper cannot inspect the Docker volume
without starting a container, so stale-source detection happens inside the
inner build helper.

If the build runs out of disk space, remove the host work directory. To also
discard the persistent Docker source/build volume, remove it explicitly:

```bash
rm -rf build/docker-sp11-qcom-x1e-kernel
docker volume rm sp11-qcom-x1e-kernel-build
```

If the patched kernel boots but Wi-Fi is still hard-blocked, save the full
troubleshooting output and compare the DT and ath12k support lines first.

If Wi-Fi disappears from the desktop UI after firmware changes and the dmesg
output shows `failed to start mhi: -34` or `failed to power up :-34`, do a full
cold boot before changing firmware again. On the verified installed system, a
cold boot restored WCN7850 probe and interface creation, after which Wi-Fi
returned to the expected `phy0` hard-blocked state.

## Related Documents

- [ADR018: Wi-Fi rfkill Bring-Up Gate](../adr/adr-0018-wifi-rfkill-bring-up-gate.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
- [ADR021: Git Fallback Kernel Build Toolchain](../adr/adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR022: Docker Kernel Build Without fakeroot](../adr/adr-0022-docker-kernel-build-without-fakeroot.md)
- [ADR023: Docker Kernel Build Case-Sensitive Work Volume](../adr/adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
- [Surface Pro 11 Wi-Fi rfkill test after qcom-x1e upgrade](../installed-wifi-rfkill-upgrade-test-20260613.md)
- [Surface Pro 11 Wi-Fi test after Windows firmware and cold boot](../installed-wifi-windows-firmware-cold-boot-test-20260613.md)
