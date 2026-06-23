# Ubuntu on Surface Pro 11 (Snapdragon X Elite)

This repository is an experimental Ubuntu bring-up kit for the Microsoft
Surface Pro 11 with Snapdragon X Elite (`X1E80100`). It uses the Surface Laptop
7 Ubuntu work as a reference, and ports the Surface Pro 11-specific pieces from
Dale Whinham's Arch Linux work.

The current verified target is:

| Item | Value |
| --- | --- |
| Device | Microsoft Surface Pro, 11th Edition |
| SKU | `Surface_Pro_11th_Edition_2076` |
| CPU | `Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz` |
| Firmware/UEFI | `175.222.235`, dated 2026-02-23 |
| Internal disk | Samsung `MZ9L4512HBLU-00BMV-SAMSUNG`, 476.9 GiB NVMe |
| Windows source checked | Windows 11 Home Insider Preview build `29585` |

> Warning: this is not an official Ubuntu, Microsoft, or linux-surface release.
> Keep Windows installed, keep a recovery USB nearby, and expect regressions.

## Prerequisites

Prepare these before building or booting the installer:

- A Microsoft Surface Pro 11 with Snapdragon X Elite (`X1E80100`). This guide
  is not for Surface Laptop 7/Romulus devices or Intel Surface devices.
- A complete Windows backup and a saved BitLocker or Device Encryption recovery
  key. Suspend or decrypt Windows device encryption before resizing partitions
  or repeatedly booting experimental media.
- Secure Boot disabled in Surface UEFI.
- A Windows recovery USB or another confirmed way to restore the device if the
  Ubuntu install or bootloader setup fails.
- A USB-C flash drive, 16 GB or larger. The write script erases the entire
  selected disk.
- A macOS build host with Docker Desktop running, `git`, `diskutil`, and sudo
  access for writing the raw USB image. Keep at least 20 GB free for the ISO,
  Docker image/package setup, work directories, and generated raw images.
- Temporary networking for post-install firmware work. Wi-Fi is not working in
  the current live session, so prepare USB-C Ethernet, USB phone tethering, or
  a mounted Windows partition for `sp11-grab-fw --windows-root`.
- An external USB keyboard is recommended for installer recovery and text
  entry. The direct GRUB mode avoids the broken interactive GRUB menu, but
  normal keyboard text input in the desktop still needs confirmation.

## Current Status

The Surface Pro 11 still needs a custom device tree and firmware handling. A
standard ARM64 Ubuntu ISO is not enough.

Latest live-USB result, 2026-06-13: the `--grub-mode direct` image boots to the
Ubuntu desktop. The interactive GRUB menu still does not accept input or
auto-boot reliably, so direct mode is the verified live-USB path for now.

Latest installed-system result, 2026-06-14: a rebuilt direct USB image carrying
the patched `7.0.0-22-qcom-x1e` kernel packages and current support scripts
completed the clean installed-system flow. The support helper selected the
rfkill-capable Denali OLED DTB, `/boot/sp11-denali.dtb` contained
`disable-rfkill`, the system booted the patched kernel, and NetworkManager
automatically reconnected to the previously saved Wi-Fi network after reboot.

The feature table below is aligned with the upstream
[dwhinham/linux-surface-pro-11 "What's working"](https://github.com/dwhinham/linux-surface-pro-11#whats-working)
list, so the Arch and Ubuntu bring-up status can be compared row by row. The
notes reflect the verified Ubuntu live-USB and installed-system results.

> The test model is a Surface Pro 11, OLED version, Wi-Fi only (no 5G), with
> the X1E SoC. If you have a different model (e.g. LCD screen, 5G, X1P CPU) you
> are on your own.

| Feature | Status | Notes |
| --- | --- | --- |
| NVMe | ✅ Working | Installed Ubuntu boots from `/dev/nvme0n1p5` with separate `/boot` and `/boot/efi` partitions after support setup. |
| Graphics | ✅ Working | Direct boot reaches the Ubuntu desktop. 3D acceleration for X1E SoCs only; X1P support is on its way from upstream. |
| Backlight | ✅ Working | Night Light and screen brightness controls work. Adjustable via `/sys/class/backlight/dp_aux_backlight/brightness`. |
| USB3 | ⚠️ Partially | USB-C ports are working, but the Surface Dock connector is presumably not. |
| USB4/Thunderbolt | ❌ Not working | No external display output when using the [official USB4 dock](https://learn.microsoft.com/en-us/surface/surface-usb4-dock). |
| USB-C display output | ✅ Working | Working as of 6.15-rc6 (for DP alt mode). |
| USB-C boot | ✅ Working with `--grub-mode direct` | The normal GRUB menu can display entries but input and timeout are unreliable. Use `--grub-mode direct` for the verified live-USB path. |
| Wi-Fi | ✅ Working | WCN7850/Qualcomm FastConnect 7800 binds to `ath12k_wifi7_pci`, loads firmware, scans, reconnects to a saved network after reboot, and passes traffic on patched git-fallback `7.0.0-22-qcom-x1e` plus an rfkill-capable Denali DTB. Stock/upgraded `7.0.0-32-qcom-x1e` remained hard-blocked. Uses a [kernel hack to disable rfkill](https://github.com/dwhinham/kernel-surface-pro-11/commit/fcc769be9eaa9823d55e98a28402104621fa6784). Continue validating normal reboots, suspend/resume, and package upgrades. |
| Bluetooth | ✅ Working | Public address set via raw `AF_BLUETOOTH` socket C helper (`tools/sp11-bt-set-addr.c`) before `bluetooth.service` starts, avoiding the btmgmt D-state hang. Cold boot service succeeds at T+1s. Pairing, audio, and suspend/resume still need validation. See [how-to-bring-up-bluetooth](docs/how-to/how-to-bring-up-bluetooth.md). |
| Audio | ⚠️ Partially | Sound card instantiates with generated topology from CRD template. Both speakers work via PipeWire manual sink with reordered `audio.position` labels to bypass the kernel DAPM gate. Speakers can sound distorted; care needed with volume controls; microphone too distorted to be usable. Audio boot race fixed: `alsa-restore.service` masked, `sp11-wsa-routing.service` enables WSA routing after the DSP graph loads. See [`how-to-bring-up-audio`](docs/how-to/how-to-bring-up-audio.md) and [ADR-0033](docs/adr/adr-0033-audio-topology-gap.md), [ADR-0034](docs/adr/adr-0034-wsa2-regcache-right-speaker.md), [ADR-0035](docs/adr/adr-0035-audio-boot-race-alsactl.md), [ADR-0036](docs/adr/adr-0036-right-speaker-audio-position-reorder.md). |
| Touchscreen | ❌ Not working | Not working in live USB. Upstream Arch notes also list touchscreen as not working. |
| Pen | ❌ Not working | Not working in live USB. Upstream Arch notes also list pen as not working. |
| Flex Keyboard | ✅ Working | Surface cover touchpad and keyboard work after the desktop starts. Backlight and function-key events are visible. Only when attached to the Surface Pro; Bluetooth cover mode unconfirmed. GRUB menu input remains unresolved, so use `--grub-mode direct`. |
| Suspend/resume | ⚠️ Partially/risky | Lid switch seems to work when the Flex Keyboard covers the screen. Resume from sleep can cause the machine to hang or produce a black screen. Prefer testing boot/install first. |
| Cameras (and status LEDs) | ❌ Not working | Camera support is not part of the first Ubuntu boot path. |

## Recommended Path

Use the custom live-USB image builder in this repo. It creates a small ARM64
GRUB boot shim, stores the Ubuntu Snapdragon X concept ISO on a Linux data
partition, and injects the Surface Pro 11 device tree at boot.

This avoids remastering the Ubuntu ISO while still giving us the SP11-specific
`devicetree` line that stock ISO boot paths lack.

### From-Scratch Commands

Run these commands from this repository root on the macOS/Docker build host:

```bash
cd /path/to/linux-surface-pro-11-oe
mkdir -p build
```

Build the patched qcom-x1e kernel packages and copy them into the USB image
payload directory:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload \
  --reset-source \
  --jobs 4 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-build-$(date +%Y%m%d-%H%M%S).log
```

Build the direct-boot USB image. This image boots the Ubuntu concept ISO kernel
for the live environment, injects the Surface Pro 11 DTB from GRUB, and carries
the patched kernel packages under `SP11DATA/payload/kernel-debs/` for
installation onto the Surface:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate
```

Identify the removable USB disk carefully. Replace `/dev/diskX` with the real
USB disk, not an internal disk:

```bash
diskutil list
diskutil info /dev/diskX
```

Write the image to the USB drive:

```bash
./scripts/write-image-to-macos-disk.sh \
  build/sp11-ubuntu-live-direct.img \
  /dev/diskX
```

After booting the Surface from this USB and installing Ubuntu, choose
`continue testing` at the end of the installer and prepare the installed target
before rebooting:

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found; run lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS."; exit 1; }

SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi

test -d /target/etc || { echo "Mount the installed Ubuntu root at /target first."; exit 1; }

cd "$SP11DATA/support"
sudo ./scripts/prepare-sp11-installed-system.sh --target /target
sudo reboot
```

After the first installed boot, mount `SP11DATA`, install firmware/support
helpers, then install the patched kernel payload:

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
sudo ./scripts/finish-sp11-installed-system.sh --download --reboot
```

If temporary networking is unavailable, mount the Windows partition and use
Windows firmware instead of downloading it:

```bash
WINROOT="/run/media/$USER/Local Disk"
test -d "$WINROOT/Windows" || { echo "Set WINROOT to the mounted Windows NTFS partition."; exit 1; }

cd "$SP11DATA/support"
sudo ./scripts/finish-sp11-installed-system.sh \
  --windows-root "$WINROOT" \
  --reboot
```

After rebooting back into installed Ubuntu, install the patched kernel packages
from the USB payload:

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
find "$SP11DATA/payload/kernel-debs" -maxdepth 1 -type f -name '*.deb' -print | sort
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only
sudo reboot
```

After the patched kernel has booted, validate audio and install the user-level
PipeWire speaker sink for the logged-in desktop user. The support installer
copies the packaged topology/UCM files from `payload/audio/` when present and
installs the `sp11-wsa-routing.service` boot-race fix; the PipeWire sink is
per-user and must be installed from the desktop session:

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
systemctl status sp11-wsa-routing.service --no-pager
./scripts/sp11-pipewire-speaker-sink.sh --install --enable-route
wpctl status
./scripts/troubleshoot-sp11-audio.sh > ~/sp11-audio-after-setup.txt
```

If `/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`
is missing, build and install the topology manually, then reboot:

```bash
cd "$SP11DATA/support"
./scripts/sp11-audio-topology.sh
sudo ./scripts/sp11-audio-topology.sh --install
sudo ./scripts/sp11-fix-audio-boot-race.sh install
sudo reboot
```

Alternatively, download the prebuilt audio topology release from
<https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-topology-v1>.
It includes the AudioReach topology binary, ALSA UCM profile, HiFi verb, and
SP11 DMI matcher. After extracting the release files on the Surface, install
them with:

```bash
shasum -a 256 -c SHA256SUMS
sudo install -m 0644 -D X1E80100-Microsoft-Surface-Pro-11-tplg.bin \
  /lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin
sudo install -m 0644 -D MICROSOFT-Surface-Pro-11.conf \
  /usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf
sudo install -m 0644 -D Surface11-HiFi.conf \
  /usr/share/alsa/ucm2/Qualcomm/x1e80100/Surface11-HiFi.conf
sudo install -m 0644 -D x1e80100.conf \
  /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf
sudo ./scripts/sp11-fix-audio-boot-race.sh install
sudo reboot
```

Bluetooth also needs the device's real Bluetooth public address from Windows.
Do not use a made-up address or publish the raw address in logs. In Windows,
run PowerShell as Administrator from a checkout of this repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\collect-sp11-windows-bluetooth-address.ps1
```

Then boot Ubuntu, replace the placeholder below with the Windows Bluetooth
address, compile the raw mgmt-socket helper, and install the cold-boot hook:

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
gcc -Wall -Wextra -O2 \
  -o tools/sp11-bt-set-addr \
  tools/sp11-bt-set-addr.c

BT_MAC="<windows-bluetooth-mac>"
sudo ./scripts/sp11-bluetooth-mac.sh --write-config "$BT_MAC"
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo reboot
```

After the cold boot, validate Bluetooth:

```bash
bluetoothctl list
bluetoothctl show
journalctl -b -u 'sp11-bluetooth-mac@hci0.service' --no-pager -n 20
```

### 1. Build the USB Image

On macOS, the builder uses Docker Desktop with an ARM64 Ubuntu container. It
can download the current Ubuntu Snapdragon X concept ISO. If that ISO includes
a Surface Pro 11 X1E Denali DTB in its casper layers, the builder extracts it
automatically:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso \
  --out build/sp11-ubuntu-live.img \
  --validate
```

If auto extraction fails, or if you need a different Surface Pro 11 variant,
provide a DTB explicitly:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso build/input/ubuntu-x1e.iso \
  --dtb build/input/x1e80100-microsoft-denali.dtb \
  --out build/sp11-ubuntu-live.img
```

An explicit DTB can come from a kernel package that includes SP11 support, or
from a local build of `dwhinham/kernel-surface-pro-11`. Do not substitute the
Surface Laptop 7/Romulus DTB.

The first build can take a while. Expect a multi-gigabyte ISO download, Docker
image/package setup, DTB extraction from Ubuntu's layered `casper/*.squashfs`
files, ext4 filesystem creation, raw-image assembly, and optional validation.
On Docker Desktop for macOS, the raw image copy/write phases can look quiet for
several minutes.

If GRUB displays the menu but the countdown never auto-boots and keyboard input
does not select an entry, build a diagnostic image that bypasses the GRUB menu
and immediately boots the default USB-safe `casper` path:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso path/to/ubuntu-x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate
```

The direct mode is intentionally diagnostic. It removes the interactive GRUB
fallback entries for that image, so keep a normal menu image available while
testing. If direct mode stops before the Ubuntu kernel starts, note the last
message on screen; a stop around `Searching for SP11DATA...` points to an
earlier GRUB storage or partition-discovery problem.

To validate an already-built image without rebuilding:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --validate-image build/sp11-ubuntu-live.img
```

Validation reports the image size and SHA-256 hash, GPT layout, ESP contents,
embedded GRUB menu or direct-boot hints, and the `/dtb/sp11-denali.dtb` file
from the `SP11DATA` partition.

The normal menu image contains:

- an ARM64 removable-media EFI bootloader,
- a USB-safe GRUB entry with `modprobe.blacklist=qcom_q6v5_pas`,
- a USB-safe text/debug GRUB entry for black-screen or installer debugging,
- an ISO-native fallback GRUB entry for loopback debugging,
- a normal GRUB entry for later NVMe-installed boot testing,
- the Ubuntu concept ISO,
- the extracted or provided DTB as `/dtb/sp11-denali.dtb`,
- optional local payload files from `payload/`,
- this repo's README, ADRs, tools, and support scripts under `/support` on the
  USB data partition.

The direct-boot diagnostic image replaces the interactive GRUB menu entries
with the same USB-safe `casper` path used by the first menu entry.

### 2. Write the USB

On macOS, verify the disk first:

```bash
diskutil list /dev/diskX
diskutil info /dev/diskX
```

Then write it:

```bash
./scripts/write-image-to-macos-disk.sh build/sp11-ubuntu-live.img /dev/diskX
```

The script refuses to write unless the disk is external, removable, and USB.
Writing the image also takes several minutes because it streams the full raw
image to the USB device.

### 3. Boot the Surface

1. Disable Secure Boot in the Surface UEFI.
2. Boot from the USB.
3. For the normal menu image, choose
   `Ubuntu for Surface Pro 11 (USB-safe, casper iso-scan)`.
4. If the GRUB menu accepts no input or never auto-boots, rebuild and write the
   direct image with `--grub-mode direct`.
5. If the screen goes black or the graphical installer does not appear, reboot
   and choose `Ubuntu for Surface Pro 11 (USB-safe text/debug, casper iso-scan)`.
6. If the casper `iso-scan` entries fail early, try
   `Ubuntu for Surface Pro 11 (USB-safe, ISO-native fallback)`.
7. If the live session boots, install Ubuntu to a new partition. Do not delete
   Windows.

### 4. Install Ubuntu Carefully

Proceed with installation only if Windows is backed up, BitLocker recovery
information is saved, Secure Boot is disabled, and you have a recovery path
through the live USB. Use manual partitioning or an installer option that keeps
Windows intact.

Because the live USB relies on explicit GRUB DTB injection, do not assume the
installed system can boot without support setup. After the installer finishes,
choose the option to continue testing instead of rebooting, keep the USB
plugged in, and configure the installed target before the first USB-free boot.
The USB image includes a helper for this under `/support/scripts`. If the
installer leaves the installed root mounted at `/target`, run:

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found; run lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
test -d /target/etc || { echo "Mount the installed Ubuntu root at /target first."; exit 1; }
cd "$SP11DATA/support"
sudo ./scripts/prepare-sp11-installed-system.sh --target /target
sudo reboot
```

If `/target` is not mounted, mount the installed Ubuntu root partition there
first. If the installed system fails to boot, boot the direct live USB again
and use it as the recovery environment.

If GRUB reports `file '/boot/sp11-denali.dtb' not found` on an installed
system with a separate `/boot` partition, rerun the current support helper.
Older helper versions always injected `/boot/sp11-denali.dtb`; the current
helper derives `/sp11-denali.dtb` vs `/boot/sp11-denali.dtb` from the generated
GRUB kernel path.

After first successful boot into installed Ubuntu, mount the USB data partition
and rerun the support helpers on the installed system:

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
sudo ./scripts/finish-sp11-installed-system.sh --download --reboot
```

Firmware download requires temporary networking, such as USB-C Ethernet or USB
phone tethering. Without networking, mount the Windows partition and use
`--windows-root` instead of `--download`:

```bash
# The WINROOT will differ
WINROOT="/run/media/$USER/Local Disk"
test -d "$WINROOT/Windows" || { echo "Set WINROOT to the mounted Windows NTFS partition."; exit 1; }

sudo ./scripts/finish-sp11-installed-system.sh \
  --windows-root "$WINROOT" \
  --reboot
```

Quote the Windows root path if it contains spaces. This must be the Windows
NTFS partition containing `Windows/`, not the Linux `/boot/efi` mount or a path
inside the EFI system partition.

If you run firmware setup while booted from USB, the script leaves
`adsp_dtb.mbn` disabled to avoid the known aDSP USB reset failure. Enable aDSP
only after the root filesystem is on NVMe.

If Wi-Fi still toggles back off after installed boot, collect the rfkill
diagnostic bundle:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

The current verified installed-system failure is `phy0` hard-blocked by
`rfkill` even after firmware loads and the WCN7850 interface is created. That
points to missing ath12k `disable-rfkill` kernel/DTB handling rather than a
missing board file.

If the diagnostic helper reports both `DT is missing disable-rfkill` and
`disable-rfkill support not found in installed ath12k modules`, build the
patched qcom-x1e kernel described in
[How To: Build a Patched qcom-x1e Kernel](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md).
The preferred path is to collect source metadata on the Surface, build the
packages in a Docker ARM64 container on a stronger machine, rebuild the USB
image with the generated packages in `payload/kernel-debs/`, then install those
packages back on the Surface.

On the Surface:

```bash
cd "$SP11DATA/support"
./scripts/collect-sp11-kernel-source-metadata.sh \
  --out "$SP11DATA/sp11-kernel-source.env"
```

The contents of your `sp11-kernel-source.env` will look something like this.

```sh
# Surface Pro 11 qcom-x1e kernel source metadata.
# Generated on 2026-06-13T12:23:02Z.
SP11_KERNEL_RELEASE='7.0.0-32-qcom-x1e'
SP11_SOURCE_PACKAGE='linux-qcom-x1e'
SP11_SOURCE_VERSION='7.0.0-32.32'
SP11_BUILD_TARGET='binary-qcom-x1e'
```

On the Docker build host, from this repository root:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

The host `--work-dir` stores Docker control files and copied artifacts. The
actual kernel source and build tree live in the Docker Linux volume
`sp11-qcom-x1e-kernel-build` at `/linux-work` so macOS case-insensitive
filesystems do not collapse Linux kernel files whose names differ only by
case. Successful builds copy generated packages back under
`build/docker-sp11-qcom-x1e-kernel/artifacts/` and, when `--copy-to-payload`
is set, into `payload/kernel-debs/`.

After rebuilding and writing the USB image, install the payload packages on the
Surface:

```bash
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only
sudo reboot
```

If Docker is not available, the same how-to includes an on-device build path.
Keep the previous qcom-x1e kernel installed as a GRUB fallback until the
patched kernel has booted and Wi-Fi rfkill state has been validated. The helper
refuses to install over the generated qcom-x1e ABI unless another installed
qcom-x1e ABI is available as a fallback, unless explicitly overridden with
`--allow-no-fallback`. In the first verified Docker git-fallback build, the
Surface was already running unpatched `7.0.0-32-qcom-x1e`, but the git branch
produced patched `7.0.0-22-qcom-x1e` packages. In that case, boot
`7.0.0-22-qcom-x1e` for the Wi-Fi rfkill test and keep `7.0.0-32-qcom-x1e` as
the fallback.

After reboot, rerun the Wi-Fi rfkill diagnostic from the
[patched qcom-x1e kernel how-to](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
before treating the patched kernel as successful.

Do not replace the installed `board-2.bin` as the next response to the verified
`phy0 Hard blocked: yes` state. The current `board.bin` fallback is enough for
the WCN7850 to probe and create `wlP4p1s0`; the remaining Wi-Fi blocker is the
rfkill kernel/DTB path.

#### Bluetooth

For Bluetooth diagnostics:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-bluetooth.sh
```

If the diagnostic reports a suspicious `00:00:00:00:*` Bluetooth address or no
default BlueZ controller, get the real Bluetooth MAC address from Windows as
described in [How To: Bring Up Bluetooth](docs/how-to/how-to-bring-up-bluetooth.md).
Then configure it explicitly:

```bash
BT_MAC="<your-bluetooth-mac>"
sudo ./scripts/sp11-bluetooth-mac.sh --write-config "$BT_MAC"
```

Build the raw mgmt-socket helper from the current checkout root, either a git
checkout or the live USB `$SP11DATA/support` directory, then install the
udev-triggered systemd service:

```bash
gcc -Wall -Wextra -O2 \
  -o tools/sp11-bt-set-addr \
  tools/sp11-bt-set-addr.c

sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo udevadm trigger --subsystem-match=bluetooth
```

The installed unit runs before `bluetooth.service`, when the controller is
still in its initial DOWN RAW state. It uses `/usr/local/sbin/sp11-bt-set-addr`
instead of `btmgmt`, avoiding the cold-boot D-state hang described in
[ADR031](docs/adr/adr-0031-bluetooth-indexed-public-address.md). See
[ADR032](docs/adr/adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md) for the
current decision.

Validate after a cold boot:

```bash
sudo reboot
# After login:
systemctl status sp11-bluetooth-mac@hci0.service --no-pager
journalctl -u sp11-bluetooth-mac@hci0.service --no-pager -n 20
bluetoothctl show | head -3
```

The journal should report `set-public-address status 0x00 (success)`, and
`bluetoothctl show` should show a powered public controller with the configured
address.

Use the real Bluetooth MAC address for your device. The helper accepts Windows
style `AA-BB-CC-DD-EE-FF` input and stores it as `AA:BB:CC:DD:EE:FF`. Do not
share diagnostic output publicly until you have redacted MAC addresses, UUIDs,
serials, and local network details.

#### Audio

For audio diagnostics:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-audio.sh
```

Do not enable experimental speaker topology or UCM snippets until the topology
file and routing are confirmed for Surface Pro 11.

Audio boot race fix: `alsa-restore.service` was restoring WSA mixer state at
boot before the AudioReach DSP finished loading the audio graph, causing an
APM CMD timeout, SoundWire bus clash, and no audio (only pops). The fix masks
`alsa-restore.service` and uses `sp11-wsa-routing.service` to enable WSA
routing after the DSP graph loads. This is installed automatically by the
support installer. To apply manually:

```bash
sudo ./scripts/sp11-fix-audio-boot-race.sh install
sudo reboot
```

See [ADR-0035](docs/adr/adr-0035-audio-boot-race-alsactl.md) for details.


- Audio topology and UCM configs are in [`payload/audio/`](payload/audio/) and
  installed automatically by the support installer.

## Test Notes

- [2026-06-13 direct live USB test](docs/live-usb-test-20260613.md)
- [2026-06-13 installed NVMe boot test](docs/installed-nvme-boot-test-20260613.md)
- [2026-06-13 installed Wi-Fi rfkill test](docs/installed-wifi-rfkill-test-20260613.md)
- [2026-06-13 Wi-Fi rfkill test after qcom-x1e upgrade](docs/installed-wifi-rfkill-upgrade-test-20260613.md)
- [2026-06-13 Wi-Fi test after Windows firmware and cold boot](docs/installed-wifi-windows-firmware-cold-boot-test-20260613.md)
- [2026-06-14 Wi-Fi rfkill test after patched qcom-x1e boot](docs/installed-wifi-patched-rfkill-test-20260614.md)
- [2026-06-14 Wi-Fi clean USB flow test](docs/installed-wifi-clean-flow-test-20260614.md)
- [2026-06-14 Bluetooth public address test](docs/installed-bluetooth-public-address-test-20260614.md)

### Visual Evidence

Redacted visual evidence for the first successful Wi-Fi and Bluetooth bring-up
is stored under `assets/`:

- [Wi-Fi networks visible in GNOME](assets/wifi/2026-06-14-sp11-wifi-networks-redacted.png)
- [Browser speed test after Wi-Fi connection](assets/wifi/2026-06-14-sp11-speedtest-redacted.webp)
- [Bluetooth settings with a paired speaker](assets/bluetooth/2026-06-14-sp11-bluetooth-search-connect-redacted.png)

## How-To Guides

- [Build a Patched qcom-x1e Kernel](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
- [Bring Up Bluetooth](docs/how-to/how-to-bring-up-bluetooth.md)
- [Bring Up Audio](docs/how-to/how-to-bring-up-audio.md)
- [Compile the Raw mgmt-Socket Bluetooth Helper](docs/how-to/how-to-compile-sp11-bt-set-addr.md)
- [Release Prebuilt Kernel Artifacts](docs/how-to/how-to-release-kernel-artifacts.md)
- [Release Audio Topology Artifacts](scripts/prepare-sp11-audio-release-assets.sh)
- [Generate a Service Report](docs/how-to/how-to-generate-service-report.md)
- [Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts](docs/how-to/how-to-troubleshoot-linux-docker-overlay.md)

## Decision Records

The major bring-up decisions are recorded in `docs/adr/`:

- [ADR001: Target Repo and Scope](docs/adr/adr-0001-target-repo-and-scope.md)
- [ADR002: Boot Shim Image Strategy](docs/adr/adr-0002-boot-shim-image-strategy.md)
- [ADR003: Denali DTB and GRUB Injection](docs/adr/adr-0003-denali-dtb-and-grub-injection.md)
- [ADR004: Firmware Extraction Policy](docs/adr/adr-0004-firmware-extraction-policy.md)
- [ADR005: Wi-Fi Board Fixup](docs/adr/adr-0005-wifi-board-fixup.md)
- [ADR006: Build and Write Guardrails](docs/adr/adr-0006-build-and-write-guardrails.md)
- [ADR007: Auto DTB Extraction and Debug Entries](docs/adr/adr-0007-auto-dtb-extraction-and-debug-entries.md)
- [ADR008: Ubuntu Denali DTB Variants](docs/adr/adr-0008-ubuntu-denali-dtb-variants.md)
- [ADR009: Default Casper ISO Scan Boot](docs/adr/adr-0009-default-casper-iso-scan-boot.md)
- [ADR010: Image Validation Workflow](docs/adr/adr-0010-image-validation-workflow.md)
- [ADR011: GRUB EFI Console Input](docs/adr/adr-0011-grub-efi-console-input.md)
- [ADR012: GRUB Module Tree](docs/adr/adr-0012-grub-module-tree.md)
- [ADR013: Standalone GRUB External Keyboard Test](docs/adr/adr-0013-standalone-grub-external-keyboard-test.md)
- [ADR014: Direct GRUB Autoboot Diagnostic](docs/adr/adr-0014-direct-grub-autoboot-diagnostic.md)
- [ADR015: Direct Live Desktop and Install Gate](docs/adr/adr-0015-direct-live-desktop-and-install-gate.md)
- [ADR016: USB Data Mount and Installed-System Helpers](docs/adr/adr-0016-usb-data-mount-and-installed-system-helpers.md)
- [ADR017: GRUB DTB Path for Separate Boot](docs/adr/adr-0017-grub-dtb-path-for-separate-boot.md)
- [ADR018: Wi-Fi rfkill Bring-Up Gate](docs/adr/adr-0018-wifi-rfkill-bring-up-gate.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](docs/adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](docs/adr/adr-0020-dockerized-arm64-kernel-build.md)
- [ADR021: Git Fallback Kernel Build Toolchain](docs/adr/adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR022: Docker Kernel Build Without fakeroot](docs/adr/adr-0022-docker-kernel-build-without-fakeroot.md)
- [ADR023: Docker Kernel Build Case-Sensitive Work Volume](docs/adr/adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
- [ADR024: Bluetooth, Audio, and Board-Data Bring-Up Gates](docs/adr/adr-0024-bluetooth-audio-and-board-data-gates.md)
- [ADR025: rfkill-Capable DTB Selection](docs/adr/adr-0025-rfkill-capable-dtb-selection.md)
- [ADR026: Prebuilt Kernel Release Artifacts](docs/adr/adr-0026-prebuilt-kernel-release-artifacts.md)
- [ADR027: Bluetooth Public Address](docs/adr/adr-0027-bluetooth-public-address.md)
- [ADR028: Bounded Bluetooth Management Hook](docs/adr/adr-0028-bounded-bluetooth-management-hook.md)
- [ADR029: Bluetooth Cold-Boot Service Retry Profile](docs/adr/adr-0029-bluetooth-cold-boot-service-retry-profile.md)
- [ADR030: Bluetooth btmgmt Batch Sequence](docs/adr/adr-0030-bluetooth-btmgmt-batch-sequence.md)
- [ADR031: Bluetooth Indexed Public Address and No Pre-Apply Restart](docs/adr/adr-0031-bluetooth-indexed-public-address.md)
- [ADR032: Raw mgmt-Socket Bluetooth Cold-Boot Solution](docs/adr/adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md)
- [ADR0033: Surface Pro 11 Audio Topology Gap](docs/adr/adr-0033-audio-topology-gap.md)
- [ADR0034: Right Speaker Silence — SoundWire Port Mapping and Regmap Cache](docs/adr/adr-0034-wsa2-regcache-right-speaker.md)
- [ADR0035: Audio Boot Race — alsactl Restore vs AudioReach DSP Graph Load](docs/adr/adr-0035-audio-boot-race-alsactl.md)
- [ADR0036: Right Speaker Audio via PipeWire audio.position Reorder](docs/adr/adr-0036-right-speaker-audio-position-reorder.md)

## Windows Firmware

The verified Windows install contains the expected firmware inputs:

- `qcdxkmsuc8380.mbn`
- `adsp_dtbs.elf`
- `qcadsp8380.mbn`
- `cdsp_dtbs.elf`
- `qccdsp8380.mbn`
- `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `battmgr.jsn`, `cdspr.jsn`

They are installed from Windows driver-store paths such as:

- `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae`
- `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a`
- `qcdx8380.inf_arm64_*`

Do not commit proprietary firmware blobs to this repository.

## Useful Commands on Windows

Run this only when we need to refresh the hardware report:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\collect-sp11-windows-diagnostics.ps1
```

The collector writes:

```text
%USERPROFILE%\Desktop\sp11-linux-checks\sp11-linux-checks-<timestamp>.zip
```

To collect only the Bluetooth address candidates needed by the Bluetooth
bring-up helper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\collect-sp11-windows-bluetooth-address.ps1
```

## Sources

This project is a synthesis of community bring-up work. The links below are
kept as source credit and as an audit trail for future decisions.

Base projects and install flow:

- Surface Laptop 7 Ubuntu notes by Bryce Hoehn: <https://github.com/bryce-hoehn/linux-surface-laptop-7>
- Surface Pro 11 Arch notes by Dan Whinham: <https://github.com/dwhinham/linux-surface-pro-11>
- linux-surface project and Surface Pro 11 support discussion: <https://github.com/linux-surface/linux-surface> and <https://github.com/linux-surface/linux-surface/issues/1962>
- Ubuntu Snapdragon X concept images and discussion: <https://people.canonical.com/~platform/images/ubuntu-concept/> and <https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800>
- Fedora Snapdragon WoA install notes: <https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install>
- Debian ThinkPad X13s installation notes, useful for WoA boot and firmware patterns: <https://wiki.debian.org/InstallingDebianOn/Thinkpad/X13s>
- WOA-Project Qualcomm reference drivers: <https://github.com/WOA-Project/Qualcomm-Reference-Drivers>

Surface Pro 11 kernel and Wi-Fi rfkill:

- Surface Pro 11 kernel patches by Dan Whinham: [ath12k `disable-rfkill` support](https://github.com/dwhinham/kernel-surface-pro-11/commit/e0c52309e8380b33239b16a85fbedb5da7d12675) and [Denali DTB `disable-rfkill`](https://github.com/dwhinham/kernel-surface-pro-11/commit/906865c001c9a01d1e2271da4db926d519a95cd8)
- Ubuntu Discourse notes by `hot21shot` confirming Surface Pro 11 Bluetooth, Wi-Fi, and graphics progress: <https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/1728>
- Ubuntu Discourse Wi-Fi rfkill and Bluetooth MAC notes by `hot21shot`: <https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/1731>
- Ubuntu Discourse Wi-Fi hard-block report by `haider5c`: <https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/1754>
- Surface Pro 11/12 Hamoa and Purwa discussion by Joerg Glathe and contributors: <https://github.com/jglathe/linux_ms_dev_kit/discussions/57>

Firmware, Bluetooth, and audio follow-up:

- Ubuntu Discourse firmware, board-data, and audio direction by `tobhe`: <https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/1689>
- Zenbook A14 Snapdragon X1 board-data repacking notes by Alex Vinarskis: <https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14#repack-board-2bin>
- Qualcomm board-data encoder reference from QCA Swiss Army Knife: <https://github.com/qca/qca-swiss-army-knife/blob/master/tools/scripts/ath11k/ath11k-bdencoder>
- Linux MSM AudioReach topology project: <https://github.com/linux-msm/audioreach-topology>
- ALSA UCM x1e80100 example for TUXEDO Elite 14: <https://github.com/alsa-project/alsa-ucm-conf/commit/154c602e89fb0da142eac57142569766be606148>
- BlueZ invalid Bluetooth address workaround discussion: <https://github.com/bluez/bluez/issues/107>
