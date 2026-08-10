---
id: adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build
title: "ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v3 build of Johan G.'s qcom-x1e 7.2-rc5-jg-0 kernel that enables the MSHW0485 OLED touchscreen over SE2 QSPI, and the out-of-tree geocausa modules that provide runtime QSPI support.
---

# ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build

## Status

Accepted (2026-08-03).

Validated by a complete `binary-indep binary-qcom-x1e` Docker build that
produced the `7.2-rc5-jg-0sp11v3-qcom-x1e` kernel packages in
`payload/kernel-debs/`, and by device-side testing: the MSHW0485 G6 touch
controller initializes over `spi@a88000`, the input device reports as
`Microsoft Surface G6 Touch`, and multi-touch works. The 2.4 MHz DMIC clock
fix and the audio capture path from the v2 build remain intact.

Deployment amendment (2026-08-06): the original module helper stopped after
`depmod` and left the required initramfs rebuild as a separate documentation
step. A community clean install consequently booted the stock SPI controller
and logged `Invalid proto 9`. The guarded flow now pins the Phase 91 source,
targets the exact v3 ABI, installs all three modules, forces them into the
initramfs, and verifies their source versions. The reported
`sp11_windows_se_init=1` setting is not the general fix and remains opt-in; the
validated development device works with it disabled. See
[ADR-0050](adr-0050-sp11-touchscreen-clean-install-release-flow.md).

Profile clarification (2026-08-07): “Phase 91” identifies the immutable
source revision and test lineage, not the active client behavior profile. The
installer supplies no `mshw0485_touch` profile parameters. At that source
revision, `mode_config_fix=true` and the later Phase 76–91 behavior gates
default to false, so `behavior_stats` reports the Phase 75 runtime profile.

## Context

[ADR-0048](adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build.md) established the
`7.2-rc5-jg-0sp11v2` build as the recommended Surface Pro 11 kernel, fixing the
DMIC clock regression from the plain `7.2-rc5-jg-0` build
([ADR-0047](adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)). The touchscreen
remained non-functional, tracked in
[ADR-0041](adr-0041-sp11-touchscreen-patches.md) and
[ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md): the upstream
`jg/ubuntu-qcom-x1e-7.2rc` device tree defines the touch controller hardware at
`spi@a88000` but leaves it disabled, and no driver existed for the MSHW0485
protocol.

The working configuration was reached cooperatively with the geocausa
[SP11X1e-touchscreen](https://github.com/geocausa/SP11X1e-touchscreen) project,
whose pinned Phase 91 source provides three out-of-tree modules that the
7.2-rc5-jg-0 kernel does not carry: a QSPI-aware `gpi` DMA engine driver, a
`spi-geni-qcom` controller driver that recognizes GENI protocol 9 (QSPI) and
performs the Linux-integrated QSPI SE preparation, and the `mshw0485_touch`
HID-SPI client driver.

### Device tree enablement

The touchscreen runs over the SE2 QSPI controller at `0xa88000` (spi10).
`hamoa.dtsi` already declares the hardware as both `i2c10` and `spi10` (both
`status = "disabled"`) and provides the `qup_spi10_data_clk` /
`qup_spi10_cs` pinctrl states. The v3 DTS patch:

- enables GPI DMA instance 1 (`dma-controller@a00000`),
- keeps `i2c10` disabled,
- adds the QSPI data pins GPIO 49/50 (`qup1_se2`),
- attaches the touchscreen child node with GPIO 48 reset, GPIO 51 interrupt,
  and GPIO 64 power, and
- enables the `spi@a88000` node.

The upstream driver only probes the node as a SPI slave unless it recognizes
the resident GENI protocol. The geocausa `spi-geni-qcom` accepts protocol 9 on
`a88000.spi` as a QSPI controller (`qcom,biosref-qspi`), which is the native
boot-time protocol of the Surface Pro 11 G6 touch controller.

## Decision

Build the `sp11v3` (touchscreen) variant of the 7.2-rc5-jg-0 baseline as the
new standard Surface Pro 11 kernel:

1. Apply `patches/sp11-qcom-x1e-7.2-rc5-v3` after
   `patches/jglathe-qcom-x1e-7.2-rc5`. The set restores the validated 2.4 MHz
   Denali DMIC clock, enables the touchscreen in the Denali device tree, and
   gives the result the distinct Debian ABI `7.2-rc5-jg-0sp11v3`, preserving
   the v2 ABI as a co-installable rollback option.
2. Build the runtime QSPI support as out-of-tree modules from the geocausa
   Phase 91 source pin (`gpi`, `spi-geni-qcom`, `mshw0485_touch`) against the
   `7.2-rc5-jg-0sp11v3` kernel headers, and install them as higher-priority
   `/lib/modules/<release>/updates/` overrides. `scripts/build-sp11-touchscreen-modules.sh`
   reproduces the build.
3. Regenerate the initramfs **after** deploying the updates modules. The stock
   kernel build embeds its own `gpi.ko.zst` / `spi-geni-qcom.ko.zst` in the
   initramfs and loads them at early boot; without a rebuild the stock
   `gpi` module (which has no QSPI TRE support) binds `a00000.dma-controller`
   permanently and the touch DMA path fails with `CH START completion timeout`.
4. Retire the installed loose-DTB selector and GRUB injection on the tested
   Stubble path. Each ABI uses the DTB embedded in its exact Stubble-wrapped
   image. The installer removes only the former managed helper and hooks,
   preserves any existing loose file unchanged, and uses normal live-root GRUB
   generation.

## Decision details

The Docker kernel build:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

The touchscreen module build and guarded install, against the installed v3
headers:

```bash
./scripts/build-sp11-touchscreen-modules.sh --install
```

The built modules land in `/lib/modules/7.2-rc5-jg-0sp11v3-qcom-x1e/updates/`
at the same relative paths as the in-tree counterparts:

- `drivers/dma/qcom/gpi.ko`
- `drivers/spi/spi-geni-qcom.ko`
- `drivers/input/touchscreen/mshw0485_touch.ko`

The installer writes explicit initramfs-tools and dracut inclusion
configuration, regenerates the exact target ABI, then checks that module
selection and the initramfs use the geocausa source versions. No separate
`dracut` or `update-initramfs` command is required.

Under [ADR-0055](adr-0055-retire-installed-loose-dtb-injection.md), the
installer retires the deployed `/usr/local/sbin/sp11-grub-inject-dtb` helper
and its managed kernel hooks. It leaves an existing `/boot/sp11-denali.dtb`
byte-for-byte untouched as inert evidence and does not use it for live-FDT
provenance. Each v3 or experimental Stubble image carries its exact
authoritative DTB.

For the new `sp11v3r2` candidate, [ADR-0056](adr-0056-controlled-sp11-module-signing.md)
supersedes this historical unsigned-module flow. The three exact-ABI modules
must carry signatures from the same pinned certificate as the kernel build;
the public certificate is a required bundle member and the encrypted private
key remains outside Git and release output. Secure Boot remains disabled.

## Consequences

- The v3 kernel boots with the touchscreen DTB enabled; the MSHW0485 controller
  initializes (`touch controller initialized path=hardware`) and the input
  device reports as `Microsoft Surface G6 Touch`.
- Multi-touch, pinch/zoom, and three-finger gestures work through the Linux
  `mshw0485_touch` HID-SPI driver.
- The release uses Phase 91 source but the Phase 75 default runtime profile;
  later behavior gates remain opt-in until independently validated.
- The 2.4 MHz DMIC clock and the audio capture path from v2 are unchanged and
  remain working.
- The touchscreen works only with the geocausa `updates/` modules present and
  an initramfs that loads them; a stock-kernel-only boot binds the stock `gpi`
  driver and the touch DMA path fails.
- The plain `7.2-rc5-jg-0` and `7.2-rc5-jg-0sp11v2` ABIs remain co-installable
  as rollback options but are no longer the recommended Surface Pro 11 kernels.
- Co-installed kernels do not share a mutable installed DTB; rollback depends
  on the known-good Stubble image, initramfs, modules, and physical recovery
  path.
