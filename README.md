# ARM64 Linux on Microsoft Surface Pro 11

![KDE Plasma running on the Surface Pro 11 with the patched qcom-x1e kernel](assets/desktop/2026-07-15-sp11-kde-plasma-desktop.png)

This repository is the experimental hardware-integration, evidence and release
channel for ARM64 Linux on the Microsoft Surface Pro 11. It carries the
downstream kernel work, device-support payloads, low-level scripts, test
records and architecture decisions for both the Snapdragon X Elite X1E/OLED
and Snapdragon X Plus X1P/LCD variants.

[Lexr.sh](https://github.com/ooaklee/lexr.sh) is the supported companion CLI.
It turns the reviewed integration policy in this repository into guarded image,
kernel, userspace, private hand-off and clean-up workflows. This repository
pins the exact reviewed Lexr revision at [`cli/lexr`](cli/lexr); Lexr owns its
own source, issues and binary-only releases, while kernel and device-support
releases remain on the established
[OE release page](https://github.com/ooaklee/linux-surface-pro-11-oe/releases).

The primary recorded X1E hardware target is:

| Item | Value |
| --- | --- |
| Device | Microsoft Surface Pro, 11th Edition |
| SKU | `Surface_Pro_11th_Edition_2076` |
| CPU | `Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz` |
| Firmware/UEFI | `175.222.235`, dated 2026-02-23 |
| Internal disk | Samsung `MZ9L4512HBLU-00BMV-SAMSUNG`, 476.9 GiB NVMe |
| Windows source checked | Windows 11 Home Insider Preview build `29585` |
| Latest published project kernel | [`sp11v19`](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2.0-jg-0sp11v19), based on Linux 7.2.0 |
| Exact project source | [`2cbd1ec3…`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/2cbd1ec3e2da385e7bd91fd65c63ba5a8fb5b865) |

> Warning: this is not an official Ubuntu, Microsoft, or linux-surface release.
> Keep Windows installed, keep a recovery USB nearby, and expect regressions.

The published `sp11v19` package is a Linux 7.2.0-based downstream integration,
not the latest official Linux kernel. As of 2026-08-31, kernel.org lists stable
7.2.2 and mainline 7.3-rc1; consult the current
[kernel.org release record](https://www.kernel.org/releases.json) rather than
inferring upstream status from the project release number. The final v19
rebuild was package- and source-validated but was not separately boot-tested as
one all-up image. Individual green entries below name hardware evidence gathered
from the relevant accepted integration generation.

## Prerequisites

- Surface Pro 11 with Snapdragon X Elite (`X1E80100`) or Snapdragon X Plus
  (`X1P64100`); evidence differs by variant as recorded below
- Windows backup + BitLocker/Device Encryption recovery key (suspend or decrypt before partition work)
- Secure Boot disabled in Surface UEFI
- Windows recovery USB or another restore path
- USB-C flash drive, 16 GB+; writing an image erases the complete selected disk
- macOS or Linux host with Git, Go 1.26+, Docker and at least 24 GiB of free workspace storage
- Access to the Lexr submodule while its repository is access-controlled
- Temporary alternative networking and an external USB keyboard remain prudent recovery options

## Current support matrix

Legend: ✅ hardware-verified; ⚠️ hardware-verified with material limitations or
older-version scope; 🧪 experimental hardware result, not supported; 🧩
integrated and build-verified without variant-specific hardware acceptance; ❌
unsupported in the current project; ❓ no evidence found.

| Feature | X1E/OLED | X1P/LCD | Evidence boundary |
| --- | --- | --- | --- |
| NVMe boot | ✅ | 🧩 | X1E completed an [installed USB-free boot](docs/installed-nvme-boot-test-20260613.md); X1P shares the device-tree path but lacks an equivalent run. |
| Internal display | ✅ | ✅ | X1P panel boot and brightness were hardware-tested in [OE PR 50](https://github.com/ooaklee/linux-surface-pro-11-oe/pull/50). |
| 3D acceleration | ⚠️ | 🧩 | X1E has older hardware evidence; no separate X1P 3D acceptance run is recorded. |
| Backlight | ✅ DP AUX | ✅ PWM | X1P PWM support is [downstream project commit `350d7bd9…`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/350d7bd9eb51c9fe95dbcc71ee19513ef6630d7f), not an upstream Linux claim. |
| Direct USB 3 | ✅ | 🧩 | X1E passed the guarded USB4 control run; this does not qualify a Surface Dock. |
| USB4/Thunderbolt | ❌; 🧪 retimer-only | ❌ | No production router, domain or tunnel path exists; [kernel PR 24](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/24) remains guarded and X1P trials can hard-lock. |
| Direct USB-C DP video | ⚠️ | 🧩 | X1E passed at 6.15-rc6 but has not been rerun against the current USB4 control; direct DP is not USB4 tunnelling. |
| DisplayPort audio | ❌ | ❌ | The current Denali graph has no DisplayPort DAI. |
| Wi-Fi | ✅ | 🧩 | X1E [scan, association, traffic and reconnect passed](docs/installed-wifi-clean-flow-test-20260614.md); downstream rfkill handling and distribution firmware remain required. |
| Bluetooth | ⚠️ | 🧩 | X1E pairing and A2DP music playback work well. Audible volume changes, but the desktop gauge can jump back to its connection-time position; [issue 58](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/58) tracks that indicator desynchronisation. Suspend coverage remains incomplete. |
| Speakers | ✅ | 🧩 | X1E passed with the [FullIO v19c userspace/kernel pairing](docs/adr/adr-0064-sp11-audio-release-strategy.md); X1P has no separate hardware acceptance. |
| Microphone | ✅ | 🧩 | X1E PipeWire, browser and local capture passed with the v12 + FullIO v19c pairing in [issue 48's closing acceptance](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/48#issuecomment-5436171174); [kernel PR 21](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/21) supplies the current 4.8 MHz kernel path. |
| Touchscreen | ✅ | ✅ | X1P physical touch was explicitly tested in [kernel PR 18](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/18); support is downstream project code. |
| Pen | ⚠️ | 🧩 | X1E pressure, tilt, hover and barrel-button paths passed under [ADR0067](docs/adr/adr-0067-sp11-kernel-hidraw-iptsd-pen-integration.md); eraser, recovery and repeated suspend remain open, and X1P lacks a device run. |
| Attached Flex Keyboard/touchpad | ⚠️ | 🧩 | X1E attached mode has [historical hardware evidence](https://github.com/dwhinham/linux-surface-pro-11/blob/169864c10ce902cf29600ecab4094c0d07ae3376/README.md#L29); the kernel uses the upstream [Surface Aggregator/KIP path](https://github.com/torvalds/linux/commit/c4a069095395ecd1e936f488511dfd9016b9c479). Detached Bluetooth and a current all-up regression remain open. |
| Volume rocker | ✅ | 🧩 | X1E press, hold-repeat and no-spurious-event checks passed in [issue 37](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/37). |
| Battery | 🧩 | 🧩 | Provider arbitration is integrated, but no explicit charging and capacity acceptance record was found. |
| Power profiles | ✅ | 🧩 | X1E desktop mappings for power saver, balanced and performance passed in [kernel PR 16](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/16); `balanced-performance` was exposed but not switched separately. |
| Suspend/resume | ⚠️ | ❓ | X1E remains partial and [issue 39](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/39) is open. |
| Front RGB camera | 🧪 | ❌ | X1E raw and processed browser video passed under [kernel PR 22](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/22), but calibration, auto-exposure, privacy and suspend gates remain; X1P has no camera node. |
| Front privacy LED | 🧩 | ❌ | X1E wiring exists, but polarity, lifetime and privacy behaviour are not qualified. |
| Rear camera | ❌ | ❌ | [Issue 41](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/41) remains open. |
| IR/Windows Hello | ❌ | ❌ | [Issue 42](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/42) remains open. |
| 5G | ❌ | ❌ | No project support evidence is recorded; the primary installed test target is Wi-Fi-only. |

The upstream boundary is narrower than this table. Linux v7.2's
[common Denali device tree](https://github.com/torvalds/linux/blob/v7.2/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi)
enables the common GPU, display, Wi-Fi, NVMe, Bluetooth and USB paths. The
[initial Denali commit](https://github.com/torvalds/linux/commit/0d72ccaa1e840b4c8723a929b2febbedcf5f80cd)
explicitly left touch, pen, cameras and status LEDs incomplete; the project
kernel supplies reviewed downstream integrations for several of those gaps.

## Historical pre-Lexr status snapshot

<details>
<summary>Show the older single-variant bring-up table</summary>

The Surface Pro 11 needs a custom device tree and firmware handling — a stock
ARM64 Ubuntu ISO is not enough. See the
[dwhinham/linux-surface-pro-11 "What's working"](https://github.com/dwhinham/linux-surface-pro-11#whats-working)
list for the upstream Arch status.

| Feature | Status | Notes |
| --- | --- | --- |
| NVMe | ✅ Working | Installed Ubuntu boots from `/dev/nvme0n1p5` with separate `/boot` and `/boot/efi` partitions after support setup. |
| Graphics | ✅ Working | Direct boot reaches the Ubuntu desktop. 3D acceleration for X1E SoCs only; X1P support is on its way from upstream. |
| Backlight | ✅ Working | Night Light and screen brightness controls work. X1E/OLED uses `/sys/class/backlight/dp_aux_backlight`; X1P/LCD uses the [downstream project](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/350d7bd9eb51c9fe95dbcc71ee19513ef6630d7f) `x1p64100-microsoft-denali.dtb` PWM-backlight path. |
| USB3 | ⚠️ Partially | USB-C ports are working, but the Surface Dock connector is presumably not. |
| USB4/Thunderbolt | ❌ Not working | No external display output when using the [official USB4 dock](https://learn.microsoft.com/en-us/surface/surface-usb4-dock). |
| USB-C display output | ✅ Working | Working as of 6.15-rc6 (for DP alt mode). |
| USB-C boot | ✅ Working with `--grub-mode direct` | The normal GRUB menu can display entries but input and timeout are unreliable. Use `--grub-mode direct` for the verified live-USB path. |
| Wi-Fi | ✅ Working | WCN7850/Qualcomm FastConnect 7800 binds to `ath12k_wifi7_pci`, loads firmware, scans, reconnects to a saved network after reboot, and passes traffic on patched git-fallback `7.0.0-22-qcom-x1e` plus an rfkill-capable Denali DTB. Stock/upgraded `7.0.0-32-qcom-x1e` remained hard-blocked. Uses a [kernel hack to disable rfkill](https://github.com/dwhinham/kernel-surface-pro-11/commit/fcc769be9eaa9823d55e98a28402104621fa6784). Continue validating normal reboots, suspend/resume, and package upgrades. |
| Bluetooth | ✅ Working | Public address set via raw `AF_BLUETOOTH` socket C helper (`tools/sp11-bt-set-addr.c`) before `bluetooth.service` starts, avoiding the btmgmt D-state hang. Cold boot service succeeds at T+1s. Pairing, audio, and suspend/resume still need validation. See [how-to-bring-up-bluetooth](docs/how-to/how-to-bring-up-bluetooth.md). |
| Audio — speakers | ✅ Working on installed v6 kernel | Both physical speakers receive the stereo mix through a PipeWire manual sink with reordered `audio.position` labels — the 4-channel PCM is a transport layout mapping physical slots 0 and 2, not a DAPM bypass ([ADR-0036](docs/adr/adr-0036-right-speaker-audio-position-reorder.md)). The rc6 integration kernel (`7.2-rc6-jg-0sp11v6`) carries the wsa884x 2S/4-ohm PA-recovery profile, which fixes the left-speaker audio wedge at sustained full volume ([ADR-0057](docs/adr/adr-0057-sp11-7-2-rc6-jg-0sp11v6-rc-branch-build.md), [ADR-0056](docs/adr/adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md)). `sp11-wsa-routing.service` applies the WSA path with PCM1 closed and exercises a fresh graph at boot, replacing the superseded alsactl boot-race fix ([ADR-0035](docs/adr/adr-0035-audio-boot-race-alsactl.md)). PA Volume is capped at raw 6 (0 dB) and the digital volumes at 81 (−3 dB) by the machine driver; the volume-slider taper is stock cubic, with a log-dB taper accepted but not yet implemented ([ADR-0055](docs/adr/adr-0055-audio-volume-taper-log-db.md)). See [`how-to-bring-up-audio`](docs/how-to/how-to-bring-up-audio.md). |
| Audio — microphone | ✅ Working with 2.4 MHz DMIC clock | The corrected single-WSA-macro UCM profile exposes two-channel internal microphone capture, and Surface-specific unity gain avoids the shared +16 dB default clipping. Setting the Denali DMIC clock to 2.4 MHz eliminates the continuous feedback/static heard at 4.8 MHz and makes recorded speech dramatically clearer. Capture remains slightly tinny or thin. See [ADR-0044](docs/adr/adr-0044-sp11-ucm-single-wsa-macro-microphone.md) and [ADR-0046](docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md). |
| Touchscreen | ✅ Working on installed v6 system | MSHW0485 G6 touchscreen over SE2 QSPI (`spi@a88000`) with GPI DMA, now carried **in-tree** on the 7.2-rc6 build (`7.2-rc6-jg-0sp11v6`) as the phase55 `mshw0485_touch`, `spi-geni-qcom`, and `gpi` drivers — no out-of-tree module install. Multi-touch, pinch/zoom, and three-finger gestures work, and sound is verified on the same build. Supersedes the v3 geocausa OOT-module approach. See [ADR-0054](docs/adr/adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build.md) and [ADR-0049](docs/adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md). |
| Pen | ✅ Supported on X1P/LCD and X1E/OLED; live-validated on X1E/OLED v19 | The matching pen-part-2 kernel and pinned upstream iptsd integration cover both `045e:0c80` and `045e:0c83`, with iptsd touch output disabled. Live X1E testing passed hover/lift, continuous input, pressure, both tilt axes, the barrel button, and normal one-, two-, and three-finger touch with balanced Phase 84 IRQ/report accounting and no transport errors, resets, or daemon restarts. Separate X1P hardware validation, eraser, recovery, repeated suspend/resume, and comprehensive touch/gesture regression qualification remain. Unmodified iptsd v3.1.0 does not expose a second stylus button. See [ADR0067](docs/adr/adr-0067-sp11-kernel-hidraw-iptsd-pen-integration.md). |
| Touchpad | ✅ Working while attached | The Type Cover touchpad uses the Surface Aggregator/KIP `ssam_node_hid_kip_touchpad` path. Detached Bluetooth mode and a current all-up hot-plug regression remain unverified. |
| Suspend/Resume | ⚠️ Partially | Lid suspend works with kernel `6.10+`, but can fail to resume display. |

</details>

This snapshot is retained for archaeology only. It mixes older kernel
generations and must not override the evidence-scoped matrix above.

## Current Lexr workflow

Clone OE with the pinned companion source, then build the provenance-aware Lexr
binary from the submodule:

```sh
git clone --recurse-submodules \
  --branch cli/linux-armer \
  https://github.com/ooaklee/linux-surface-pro-11-oe.git
cd linux-surface-pro-11-oe

(cd cli/lexr && go run ./cmd/lexr-build)
./cli/lexr/bin/lexr version
./cli/lexr/bin/lexr doctor
```

During the access-controlled phase, only contributors who can read the Lexr
repository can initialise the submodule. A clone without `--recurse-submodules`
still contains the complete OE kernel, evidence, scripts and release history;
initialise `cli/lexr` later when access is available. The HTTPS submodule URL
does not need to change when Lexr becomes public.

### Create and validate the Ubuntu Concept image

The Ubuntu Concept Casper adapter is the first implemented image strategy. Its
shortest command selects the audited catalogue source and latest candidate OE
kernel release. Start with the deterministic plan, then create and validate the
same output:

```sh
mkdir -p build/lexr

./cli/lexr/bin/lexr image create \
  --output build/lexr/lexr-ubuntu-sp11.iso \
  --dry-run

./cli/lexr/bin/lexr image create \
  --output build/lexr/lexr-ubuntu-sp11.iso

./cli/lexr/bin/lexr image validate \
  build/lexr/lexr-ubuntu-sp11.iso
```

For a reproducible source decision, download Canonical's dated catalogue image,
record its SHA-256, and pass `--source`, `--source-sha256` and an explicit
`--kernel-release`. The current adapter remasters the vendor Casper filesystem,
preserves the hybrid ISO/GPT layout and vendor media-discovery contract, and
replaces the complete kernel-facing module set. Fedora, Debian, elementary OS
and Pop!_OS remain catalogue-only until they have explicit adapters.

Structural validation is not a hardware acceptance result. An older direct
Ubuntu Concept image reached the X1E desktop, but that does not qualify the
current Lexr remaster or an X1P boot. Keep those runs as explicit release gates.

Add the exact Lexr binary, corresponding source, catalogues and eligible offline
IPTSD bundle to the same image inventory when live recovery needs the companion:

```sh
./cli/lexr/bin/lexr image create \
  --kernel-release latest \
  --companion-source-dir cli/lexr \
  --companion-userspace iptsd \
  --output build/lexr/lexr-ubuntu-sp11-with-companion.iso
```

The embedded `/sp11/lexr-manifest.json` and adjacent
`*.iso.manifest.json` remain the single schema-4 inventory. Its
`companion_bundle` attribute records the executable, source archive, catalogues
and eligible userspace files; private Windows hand-offs are never included.

### Write the validated ISO

Device discovery is read-only. Review the exact whole-device identity and
confirmation before allowing the elevated write:

```sh
./cli/lexr/bin/lexr image devices

./cli/lexr/bin/lexr image write \
  build/lexr/lexr-ubuntu-sp11.iso \
  --device /dev/diskX \
  --dry-run
```

Repeat the command with `sudo` and the exact confirmation phrase emitted by the
current dry run. Lexr rejects blanket confirmation, system-backed storage,
identity drift, active consumers and incomplete read-back verification.

### Install a verified kernel and audit userspace

Kernel downloads continue to resolve against this repository's releases:

```sh
./cli/lexr/bin/lexr kernel release list
./cli/lexr/bin/lexr kernel release download latest \
  --output-dir build/lexr/kernel-bundle

RUNNING_ABI="$(uname -r)"
./cli/lexr/bin/lexr kernel preflight build/lexr/kernel-bundle \
  --root / \
  --fallback-abi "$RUNNING_ABI"

./cli/lexr/bin/lexr kernel install build/lexr/kernel-bundle \
  --root / \
  --fallback-abi "$RUNNING_ABI" \
  --dry-run
```

Only after reviewing the preflight and dry-run receipt should the install be
repeated with `sudo` and `--yes`. Lexr preserves the selected fallback kernel;
it does not change the default kernel, remove the fallback or reboot.

After installation, use the companion to show exactly which userspace support
is missing before pulling or installing anything:

```sh
./cli/lexr/bin/lexr doctor userspace
./cli/lexr/bin/lexr userspace status
./cli/lexr/bin/lexr userspace list
./cli/lexr/bin/lexr userspace pull recommended
```

Restricted platform firmware and the Bluetooth public address use Lexr's
private same-device Windows hand-off, not an ISO or public release. Review the
[Lexr operator documentation](https://github.com/ooaklee/lexr.sh#private-windows-hand-offs)
before collecting or applying those values.

### Inspect obsolete workarounds

Clean-up remains explicit and reversible. Scan first, save the exact plan, and
review every recognised path before applying it:

```sh
./cli/lexr/bin/lexr clean scan
./cli/lexr/bin/lexr clean plan --output lexr-cleanup-plan.json
```

See [Use Lexr with the OE repository](docs/how-to/how-to-use-lexr.md) for the
complete current operator path and its privilege, recovery and dry-run
boundaries.

## Retained manual script workflow

The scripts below preserve low-level reproduction and historical evidence.
They are not the primary orchestration interface and several examples target
older integration generations. Use Lexr for current image, kernel, userspace,
hand-off and clean-up operations unless a hardware investigation explicitly
requires the underlying script.

The custom live-USB builder creates a small ARM64 GRUB boot shim, stores the
Ubuntu Snapdragon X concept ISO on a Linux data partition, and injects the
Surface Pro 11 device tree at boot. This avoids remastering the Ubuntu ISO.

### 1. Build the patched kernel (Docker, on macOS)

```bash
cd /path/to/linux-surface-pro-11-oe
mkdir -p build

# Published v19 integration branch; verify the exact source identity below.
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/integration-7.2.x \
  --image ubuntu:26.04 \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --linux-work-volume sp11-kernel-build-ci \
  --copy-to-payload --reset-source --jobs 8

# OR: Ubuntu concept kernel
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git --work-dir build/docker-sp11-qcom-x1e-kernel \
  --patch-dir patches/ubuntu-qcom-x1e-7.0 \
  --copy-to-payload --reset-source --jobs 4

# OR: SP11 v2 — Johan G.'s 7.1.3 tree with the 2.4 MHz DMIC default
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
  --jobs 4

# OR: SP11 7.2-rc5 v2 — JG 7.2-rc5 baseline with the 2.4 MHz DMIC default
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 8

# OR: SP11 7.2-rc5 v3 — JG 7.2-rc5 baseline with touchscreen + 2.4 MHz DMIC
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3 \
  --copy-to-payload \
  --reset-source \
  --jobs 8

# OR: SP11 7.2-rc5 v4 — in-tree phase55 touchscreen (no OOT modules)
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/qcom-x1e-7.2-rc5-touchscreen-intree \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v4" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v4 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v4 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

The v19 integration is published. On 2026-08-31,
`sp11/integration-7.2.x` resolved to exact source
[`2cbd1ec3e2da…`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/2cbd1ec3e2da385e7bd91fd65c63ba5a8fb5b865).
Remote branches can move, and the script's git mode accepts a branch or tag
rather than an arbitrary commit. Use Lexr's checksum-verified release flow for
repeatable installation, or verify that identity explicitly before treating a
manual build as release provenance.

The release examples use the immutable
`jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` tag. The moving
`jg/ubuntu-qcom-x1e-7.2rc` branch resolved to the same source commit when this
baseline was validated, but should not be used as release provenance.

The v3 build enables the MSHW0485 OLED touchscreen in the device tree, but the
runtime QSPI support ships as an exact-ABI out-of-tree module bundle. After the
v3 kernel and headers are installed, the pinned build helper selects the v3
headers (even when an older kernel is still running), builds all three modules,
and delegates installation, initramfs regeneration, and verification to the
guarded installer:

```bash
./scripts/build-sp11-touchscreen-modules.sh --install
```

The validated controller profile leaves the experimental
`sp11_windows_se_init` parameter off. Do not add it merely because a boot logs
`Invalid proto 9`; that signature means the stock controller was loaded. Run
`sudo ./scripts/troubleshoot-sp11-touchscreen.sh` to classify the boot first.
See [ADR-0050](docs/adr/adr-0050-sp11-touchscreen-clean-install-release-flow.md)
for the clean-install retrospective and [ADR-0049](docs/adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
for the kernel decision.

The v4 build moves the touchscreen support fully in-tree: the fork branch
`sp11/qcom-x1e-7.2-rc5-touchscreen-intree` carries the phase55 `mshw0485_touch`
driver, the QSPI-capable `spi-geni-qcom`/`gpi` controllers, and the Denali
touchscreen/QSPI device-tree nodes. Only the SP11 v4 naming patch
(`patches/sp11-qcom-x1e-7.2-rc5-v4`) is applied on top, so no
`build-sp11-touchscreen-modules.sh` step is required. See
[ADR-0054](docs/adr/adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build.md).

`--patch-dirs` accepts a space-separated list; patches from each directory are
applied in order. The `binary-indep` target is required because the ABI-specific
headers package depends on `linux-qcom-x1e-headers-<abi>` (e.g.
`linux-qcom-x1e-headers-7.1.3-jg-1sp11v2`).

If a new `jg/ubuntu-qcom-x1e-7.1.3-jg-<n>` tag fails `check-config` with
`N config options have been changed`, regenerate the annotations patch before
rerunning the build:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch "jg/ubuntu-qcom-x1e-7.1.3-jg-<n>" \
  --reset-source
```

The helper installs the source package's complete build dependencies, uses the
same compiler and Rust probes as the package build, removes the stale
annotations patch for the previous tag, and writes the replacement into
`patches/jglathe-qcom-x1e-7.1.3/`. Verify the new filename, then rerun the
original build command unchanged.

See the [patched qcom-x1e kernel how-to](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
for the full on-device build path and fallback-kernel safety model.

Build the matching pinned ARM64 iptsd payload before creating a pen test image:

```bash
./scripts/build-sp11-iptsd-docker.sh --copy-to-payload
```

The builder verifies the exact upstream source and emits binaries, hashes,
licenses, and corresponding source under `payload/iptsd-sp11`. See
[Build and Validate the SP11 Pen Integration](docs/how-to/how-to-bring-up-pen.md).

### 2. Build the USB image

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate
```

If auto DTB extraction fails, provide the X1E/OLED DTB explicitly via `--dtb`
or the best-effort X1P/LCD DTB via `--dtb-x1p`. An explicit DTB can come from a
kernel package with SP11 support or from a local build of
`dwhinham/kernel-surface-pro-11`. Do not substitute the Surface Laptop 7/Romulus
DTB. X1P/LCD live boot uses `--grub-mode menu` to select its dedicated entry.

To build a live USB with KDE Plasma available by default, add `--desktop kde`.
See [ADR-0039](docs/adr/adr-0039-kde-plasma-desktop-option.md).

### 3. Write the USB

```bash
diskutil list
diskutil info /dev/diskX  # verify it's the removable USB disk
./scripts/write-image-to-macos-disk.sh build/sp11-ubuntu-live-direct.img /dev/diskX
```

The script refuses to write unless the disk is external, removable, and USB.

### 4. Boot and install

1. Disable Secure Boot in Surface UEFI.
2. Boot from the USB.
3. Install Ubuntu carefully (shrink Windows, create `/`, `/boot`, `/boot/efi`).
4. At the end of the installer, choose **continue testing** and run the
   installed-system preparer before rebooting:

```bash
SP11DEV="$(blkid -L SP11DATA)"
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
[ -z "$SP11DATA" ] && { sudo mkdir -p /mnt/sp11data; sudo mount "$SP11DEV" /mnt/sp11data; SP11DATA=/mnt/sp11data; }
cd "$SP11DATA/support"
sudo ./scripts/prepare-sp11-installed-system.sh --target /target
sudo reboot
```

### 5. Post-install: firmware + kernel + bring-up

After the first installed boot, mount `SP11DATA` and run the finish script
(downloads firmware, installs support helpers, reboots):

```bash
SP11DEV="$(blkid -L SP11DATA)"
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
[ -z "$SP11DATA" ] && { sudo mkdir -p /mnt/sp11data; sudo mount "$SP11DEV" /mnt/sp11data; SP11DATA=/mnt/sp11data; }
cd "$SP11DATA/support"
sudo ./scripts/finish-sp11-installed-system.sh --download --reboot
```

If networking is unavailable, mount the Windows partition and use Windows
firmware instead: `--windows-root "$WINROOT"` (see the script `--help`).
See [Install Surface Pro 11 Firmware](docs/how-to/how-to-install-sp11-firmware.md)
for the source options, aDSP safety policy, and validation checks.

Then install the patched kernel payload from the USB. For an `sp11v3` payload,
keep `gpi.ko`, `spi-geni-qcom.ko`, and `mshw0485_touch.ko` beside the `.deb`
files; the same command installs the exact-ABI module set and verifies the
rebuilt initramfs:

```bash
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh --work-dir "$SP11DATA/payload/kernel-debs" --install-only
sudo reboot
```

Keep the previous qcom-x1e kernel as a GRUB fallback until the patched kernel
has booted and Wi-Fi rfkill state has been validated.

The installer refuses an `sp11v3` kernel with a missing or mismatched module
bundle before invoking `apt`. `--skip-touchscreen-modules` is available for a
deliberate kernel-development install, but touch will remain unavailable until
`install-sp11-touchscreen.sh` completes.

For a direct local installation instead of the USB payload flow, place all four
matching `.deb` packages in one directory and run the same helper against that
directory. An `sp11v3` directory must also contain the release's matching
`gpi.ko`, `spi-geni-qcom.ko`, and `mshw0485_touch.ko` files. For example, with
the verified release artefacts downloaded to `$HOME/Downloads`:

```bash
cd /path/to/linux-surface-pro-11-oe
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/Downloads" \
  --install-only
sudo reboot
```

The historical v6 bundle contains matching image, modules, flavour-header, and
common-header packages for `7.2-rc5-jg-0sp11v6` with the in-tree phase55
touchscreen and the wsa884x PA recovery — no separate module files are needed
([ADR-0056](docs/adr/adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md)).
The v3 bundle added the three out-of-tree touchscreen modules, and the older
`7.1.3-jg-1sp11v2` package set remains a kernel-only rollback option. After
reboot, verify the running kernel and authoritative DMIC clock:

```bash
uname -r
od -An -tu4 -N4 --endian=big \
  /sys/firmware/devicetree/base/soc@0/codec@6d44000/qcom,dmic-sample-rate
```

For those historical bundles only, expected values are
`7.2-rc5-jg-0sp11v6-qcom-x1e` (or
`7.2-rc5-jg-0sp11v3-qcom-x1e`, or
`7.1.3-jg-1sp11v2-qcom-x1e` after selecting the rollback kernel) and `2400000`.
The current published project ABI is `7.2.0-jg-0sp11v19-qcom-x1e`, and its
Denali kernel path uses `4800000`; use the Lexr release flow above for that
generation rather than adapting this archived package procedure.

## Manual post-install bring-up reference

This section records the lower-level procedures behind earlier hardware
acceptance. Some commands and kernel names are generation-specific. Run
`lexr doctor userspace` and consult the current support matrix before applying
one of these procedures to a current installation.

### Touchscreen

After rebooting the v3 kernel, run the read-only diagnostic:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-touchscreen.sh
```

Success requires the v3 device tree, all three loaded module source versions
to match their selected `updates/` files, and the `Microsoft Surface G6 Touch`
input device. `Invalid proto 9` indicates a stale stock SPI controller in the
boot path; `CH START completion timeout` points to a stale or mismatched GPI
DMA module. The diagnostic reports the corresponding repair command.

The guarded installer now **repairs** the stale-initramfs case instead of only
detecting it: it diverts (or removes) the stock in-tree
`kernel/drivers/{dma/qcom/gpi,spi/spi-geni-qcom}.ko*` before `depmod`, adds a
persistent initramfs-tools/dracut guard, and verifies neither module is
built-in. See
[ADR-0053](docs/adr/adr-0053-sp11-touchscreen-stale-initramfs-repair.md). An
r1 install that already stopped with `initramfs also contains a
stock/duplicate` can be recovered manually:

```bash
REL=7.2-rc5-jg-0sp11v3-qcom-x1e
sudo rm -f /lib/modules/$REL/kernel/drivers/dma/qcom/gpi.ko*
sudo rm -f /lib/modules/$REL/kernel/drivers/spi/spi-geni-qcom.ko*
sudo depmod -a $REL
sudo update-initramfs -u -k $REL
```

The captured Windows controller initialization is intentionally not the
default. If the diagnostic proves that the correct modules are loaded and the
Linux-integrated path still fails on a cold boot, reinstall explicitly with
`--windows-se-init` as an A/B recovery test and retain the known-good kernel
fallback.

### Pen

Pen part 2 requires the matching kernel and userspace branches. If
`payload/iptsd-sp11` was included on `SP11DATA`, the installed-system support
flow installs it automatically. To make a missing payload fatal, run:

```bash
cd "$SP11DATA/support"
sudo ./scripts/install-sp11-support.sh --installed-system --require-iptsd
```

The installer verifies the payload, disables the legacy `g6-pen.service`,
masks the generic `iptsd@.service`, and lets udev start one dynamic
`sp11-iptsd@` instance for the matching HIDRAW node. The SP11 udev rule
replaces any earlier generic iptsd request for that node. It deliberately
disables iptsd's virtual touchscreen so the kernel's direct touch device
remains the only touch provider. Do not hard-code a `hidrawN` number; it
changes across recovery and resume.

This installs support into the target system, not the running live desktop.
Follow the complete discovery, functional, suspend/resume, and rollback matrix
in [Build and Validate the SP11 Pen Integration](docs/how-to/how-to-bring-up-pen.md)
before merging either branch.

### Wi-Fi

The WCN7850 needs a patched kernel with rfkill disabled. The `board.bin`
fallback is enough for the adapter to probe; the remaining blocker is the
rfkill kernel/DTB path. See the
[patched qcom-x1e kernel how-to](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
for the full diagnostic and build path.

### Bluetooth

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-bluetooth.sh
```

If the diagnostic reports a `00:00:00:00:*` address, get the real Bluetooth MAC
from Windows (see [how-to-bring-up-bluetooth](docs/how-to/how-to-bring-up-bluetooth.md))
and configure it:

```bash
BT_MAC="<your-bluetooth-mac>"
sudo ./scripts/sp11-bluetooth-mac.sh --write-config "$BT_MAC"
gcc -Wall -Wextra -O2 -o tools/sp11-bt-set-addr tools/sp11-bt-set-addr.c
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo udevadm trigger --subsystem-match=bluetooth
sudo reboot
```

The installed unit runs before `bluetooth.service`, avoiding the cold-boot
D-state hang. See [ADR-0032](docs/adr/adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md).

### Audio

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-audio.sh
```

Install the audio support (UCM profiles, probe-backed routing service, and
GRUB DTB injection), then add the user-level PipeWire speaker sink:

```bash
cd "$SP11DATA/support"
sudo ./scripts/install-sp11-support.sh
./scripts/sp11-pipewire-speaker-sink.sh --install
sudo reboot
```

`sp11-wsa-routing.service` applies the WSA speaker route while PCM1 is closed
and exercises a fresh AudioReach graph before the display manager starts. It
runs after any ALSA-state restore; the distribution ALSA services must not be
masked (the earlier alsactl boot-race diagnosis was superseded — see
[ADR-0035](docs/adr/adr-0035-audio-boot-race-alsactl.md)).

If the topology file is missing, build and install it before running the
support installer:

```bash
cd "$SP11DATA/support"
./scripts/sp11-audio-topology.sh
sudo ./scripts/sp11-audio-topology.sh --install
```

The [audio topology and UCM v2 release](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-topology-v2)
and [v7 kernel bundle](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2.0-jg-0sp11v7)
record the historical 2.4 MHz, manual-routing generation; neither is the
current recommendation. The accepted current userspace is the published
[FullIO v19c release](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-v19c),
whose interfaces are supported from project kernel generation v12 and
validated through v19. Use `lexr userspace status --feature audio` and
`lexr userspace pull audio-fullio-v19c` for that guarded path. The manual sink,
routing and topology helpers in this subsection remain only for reproducing
archived evidence.
The experimental
[7.2-rc5-jg-0sp11v3 r1 kernel bundle](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1)
and the existing
[7.1.3-jg-1 v2 kernel](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-1-v2)
remain available as rollback options.

See [`how-to-bring-up-audio`](docs/how-to/how-to-bring-up-audio.md),
[ADR-0035](docs/adr/adr-0035-audio-boot-race-alsactl.md),
[ADR-0036](docs/adr/adr-0036-right-speaker-audio-position-reorder.md), and
[ADR-0055](docs/adr/adr-0055-audio-volume-taper-log-db.md) for details.

## KDE Plasma (Kubuntu-like Experience)

Kubuntu has no official ARM64 ISO. Two paths to a KDE Plasma desktop:

**Option 1 (recommended): Post-install swap**

```bash
cd "$SP11DATA/support"
sudo ./scripts/sp11-install-kde-desktop.sh
# Once confirmed, optionally remove GNOME:
sudo ./scripts/sp11-install-kde-desktop.sh --purge-gnome -y
```

**Option 2 (experimental): Live USB with KDE**

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso \
  --desktop kde --grub-mode direct \
  --out build/sp11-ubuntu-live-direct-kde.img --validate
```

Both paths are desktop-layer changes only — they do not touch the SP11 kernel,
DTB, firmware, audio, or Bluetooth bring-up. See
[ADR-0039](docs/adr/adr-0039-kde-plasma-desktop-option.md).

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

- [Wi-Fi networks visible in GNOME](assets/wifi/2026-06-14-sp11-wifi-networks-redacted.png)
- [Browser speed test after Wi-Fi connection](assets/wifi/2026-06-14-sp11-speedtest-redacted.webp)
- [Bluetooth settings with a paired speaker](assets/bluetooth/2026-06-14-sp11-bluetooth-search-connect-redacted.png)

## How-To Guides

- [Use Lexr with the OE Repository](docs/how-to/how-to-use-lexr.md)
- [Build a Patched qcom-x1e Kernel](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
- [Bring Up Bluetooth](docs/how-to/how-to-bring-up-bluetooth.md)
- [Bring Up Audio](docs/how-to/how-to-bring-up-audio.md)
- [Build and Validate the SP11 Pen Integration](docs/how-to/how-to-bring-up-pen.md)
- [Run the Legacy G6 Diagnostic Pen Processor](docs/how-to/how-to-run-g6-pen-processor.md)
- [Compile the Raw mgmt-Socket Bluetooth Helper](docs/how-to/how-to-compile-sp11-bt-set-addr.md)
- [Release Prebuilt Kernel Artefacts](docs/how-to/how-to-release-kernel-artifacts.md)
- [Release Audio Topology Artefacts](scripts/prepare-sp11-audio-release-assets.sh)
- [Generate a Service Report](docs/how-to/how-to-generate-service-report.md)
- [Touchscreen Clean-Install and Release Retrospective](docs/adr/adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [Troubleshoot Docker Overlay Mount Failures on Linux Build Hosts](docs/how-to/how-to-troubleshoot-linux-docker-overlay.md)
- [Troubleshoot Docker `exec format error` on x86_64 Linux Build Hosts](docs/how-to/how-to-troubleshoot-docker-exec-format-error.md)
- [Troubleshoot Kernel Git Clone `fetch-pack` Failures](docs/how-to/how-to-troubleshoot-kernel-git-clone-failures.md)

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
- [ADR026: Prebuilt Kernel Release Artefacts](docs/adr/adr-0026-prebuilt-kernel-release-artifacts.md)
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
- [ADR0037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1](docs/adr/adr-0037-jglathe-qcom-7-1-1-stubble-paths.md)
- [ADR0038: Split Compressed Live Image Release Assets](docs/adr/adr-0038-split-compressed-live-image-release-assets.md)
- [ADR0039: KDE Plasma Desktop Option](docs/adr/adr-0039-kde-plasma-desktop-option.md)
- [ADR0040: Multi-Directory Patch Sources (--patch-dirs)](docs/adr/adr-0040-multi-patch-dirs.md)
- [ADR0041: Surface Pro 11 Touchscreen Kernel Patch Set](docs/adr/adr-0041-sp11-touchscreen-patches.md)
- [ADR0042: Touchscreen — Kernel Integration Troubleshooting and Remaining Blockers](docs/adr/adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR0043: Reproducible JG 7.1.3-jg-1 Kernel Builds](docs/adr/adr-0043-jglathe-qcom-7-1-3-jg-1-build-reproducibility.md)
- [ADR0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels](docs/adr/adr-0044-sp11-ucm-single-wsa-macro-microphone.md)
- [ADR0045: Surface Pro 11 2.4 MHz DMIC Clock Test Kernel](docs/adr/adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
- [ADR0046: Default the Surface Pro 11 DMIC Clock to 2.4 MHz](docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md)
- [ADR0047: JG 7.2-rc5-jg-0 Kernel Build](docs/adr/adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)
- [ADR0048: JG 7.2-rc5-jg-0sp11v2 Kernel Build](docs/adr/adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build.md)
- [ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Build](docs/adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR0050: Touchscreen Clean-Install and Release Flow](docs/adr/adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [ADR0051: Remove Broken or Incorrect Releases and Tags](docs/adr/adr-0051-release-and-tag-cleanup.md)
- [ADR0052: Build from the SP11 Integration Kernel Fork](docs/adr/adr-0052-sp11-integration-fork-build.md)
- [ADR0053: Repair Stale Stock-Module Initramfs During Touchscreen Install](docs/adr/adr-0053-sp11-touchscreen-stale-initramfs-repair.md)
- [ADR0054: JG 7.2-rc5-jg-0sp11v4 In-Tree Touchscreen Build](docs/adr/adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build.md)
- [ADR0055: Log-dB Speaker Volume Taper](docs/adr/adr-0055-audio-volume-taper-log-db.md)
- [ADR0056: SP11 7.2-rc5-jg-0sp11v6 Integration Fork Build](docs/adr/adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md)
- [ADR0057: SP11 7.2-rc6-jg-0sp11v6 rc-Branch Integration Build](docs/adr/adr-0057-sp11-7-2-rc6-jg-0sp11v6-rc-branch-build.md)
- [ADR0058: SP11 7.2.0-jg-0sp11v7 Non-rc Integration Line](docs/adr/adr-0058-sp11-7-2-0-jg-0sp11v7-non-rc-integration-line.md)
- [ADR0059: Evidence-Gated G6 HEAT Userspace Pen Processor](docs/adr/adr-0059-evidence-gated-g6-heat-userspace-pen-processor.md)
- [ADR0060: Pen Integration Status: Hover Validated, Tap-to-Click Deferred](docs/adr/adr-0060-pen-integration-status.md)
- [ADR0061: SP11 Platform Profile Framework on Non-ACPI Systems](docs/adr/adr-0061-sp11-platform-profile-framework-non-acpi.md)
- [ADR0062: SP11 7.2.0-jg-0sp11v9 Golden-v32 Audio Kernel Line](docs/adr/adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line.md)
- [ADR0063: SP11 Feedback-Port Offset2 Boot Param](docs/adr/adr-0063-sp11-v10-feedback-port-offset2-parity.md)
- [ADR0064: Dedicated SP11 Audio Release Strategy](docs/adr/adr-0064-sp11-audio-release-strategy.md)
- [ADR0065: SP11 Front Camera C-PHY Integration](docs/adr/adr-0065-sp11-front-camera-cphy-integration.md)
- [ADR0066: SP11 IMX681 libcamera Simple IPA Integration](docs/adr/adr-0066-sp11-imx681-libcamera-simple-ipa.md)
- [ADR0067: SP11 Kernel HIDRAW Bridge and Pinned iptsd Pen Integration](docs/adr/adr-0067-sp11-kernel-hidraw-iptsd-pen-integration.md)
- [ADR0069: Standalone Lexr and OE Workflow Ownership](docs/adr/adr-0069-standalone-lexr-workflow-ownership.md)

## Private Windows firmware and Bluetooth hand-off

Current collection is owned by Lexr's strict version-3 same-device hand-off.
The collector is pinned at
`cli/lexr/tools/collect-sp11-windows-handoff.ps1`; collected directories and
their payloads are private device data and must never be committed, attached to
an issue, placed on an ISO or published in a release. Follow Lexr's
[private hand-off procedure](https://github.com/ooaklee/lexr.sh#private-windows-hand-offs)
for the required protected NTFS parent, controller selection, transfer, import,
application and recovery boundaries.

The verified Windows install contains these key firmware inputs:

- `qcdxkmsuc8380.mbn`
- `adsp_dtbs.elf`
- `qcadsp8380.mbn`
- `cdsp_dtbs.elf`
- `qccdsp8380.mbn`

The retained `scripts/sp11-grab-fw.sh` helper installs these files either by downloading
the latest WOA-Project Qualcomm reference driver set (`--download`) or by
copying the newest matching files from a mounted Windows root
(`--windows-root`). The installed-system finish script invokes this helper.
See [Install Surface Pro 11 Firmware](docs/how-to/how-to-install-sp11-firmware.md)
for the complete eleven-file mapping, including `qcdxkmsucpurwa.mbn` and the
aDSP/cDSP JSON payloads, plus the full procedure and validation steps.

Firmware installation is a one-time step: the files persist under
`/lib/firmware`. Kernel package installation normally rebuilds the new
kernel's initramfs automatically, while firmware needed after the root
filesystem is mounted remains available from `/lib/firmware`. This helper is a
low-level historical path, not a substitute for Lexr's closed, provenance-bound
private hand-off. Do not rerun it for each kernel installation or upgrade.

## Useful Commands on Windows

Run the non-collecting contract self-test from an elevated Windows PowerShell
session before following the complete private collection procedure:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 -SelfTest
```

## Sources

This project is a synthesis of community bring-up work. The links below are
kept as source credit and as an audit trail for future decisions.

Base projects and install flow:

- Lexr companion CLI: <https://github.com/ooaklee/lexr.sh>
- Surface Pro 11 downstream integration kernel: <https://github.com/ooaklee/linux_ms_dev_kit-sp11>
- Surface Laptop 7 Ubuntu notes by Bryce Hoehn: <https://github.com/bryce-hoehn/linux-surface-laptop-7>
- Surface Pro 11 Arch notes by Dan Whinham: <https://github.com/dwhinham/linux-surface-pro-11>
- linux-surface project and Surface Pro 11 support discussion: <https://github.com/linux-surface/linux-surface> and <https://github.com/linux-surface/linux-surface/issues/1962>
- linux-surface iptsd userspace processor: <https://github.com/linux-surface/iptsd>
- turbineBMW Surface Pro 11 Linux integration, used as attributed pen lifecycle and hardware-reference evidence: <https://github.com/turbineBMW/surface-pro-11-linux>
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
