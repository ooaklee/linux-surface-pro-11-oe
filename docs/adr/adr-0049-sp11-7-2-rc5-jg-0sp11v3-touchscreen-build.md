---
id: adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build
title: "ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v3 build of Johan G.'s qcom-x1e 7.2-rc5-jg-0 kernel that enables the MSHW0485 OLED touchscreen over SE2 QSPI, and the out-of-tree geocausa modules that provide runtime QSPI support.
---

> **Current operator notice (2026-08-30):** The v3 out-of-tree module and
> builder commands below are historical, non-prescriptive evidence. Current
> kernels carry the touchscreen stack in-tree. Use `kernel build`,
> `kernel preflight`, `kernel install`, `kernel release prepare`,
> `kernel release validate`, `doctor hardware touchscreen`, `doctor userspace`,
> and `clean`; see
> [CLI ADR016](../../cli/linux-armer/docs/adr/adr-016-native-kernel-release-preparation.md).

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
whose Phase 91 baseline provides three out-of-tree modules that the
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
   Phase 91 baseline (`gpi`, `spi-geni-qcom`, `mshw0485_touch`) against the
   `7.2-rc5-jg-0sp11v3` kernel headers, and install them as higher-priority
   `/lib/modules/<release>/updates/` overrides. `scripts/build-sp11-touchscreen-modules.sh`
   reproduces the build.
3. Regenerate the initramfs **after** deploying the updates modules. The stock
   kernel build embeds its own `gpi.ko.zst` / `spi-geni-qcom.ko.zst` in the
   initramfs and loads them at early boot; without a rebuild the stock
   `gpi` module (which has no QSPI TRE support) binds `a00000.dma-controller`
   permanently and the touch DMA path fails with `CH START completion timeout`.
4. Generalize the installer's DTB selection from `sp11v2` to any
   `sp11v[0-9]+` suffix so a v3 build is preferred when it coexists with the
   plain or v2 build.

## Decision details

The Docker kernel build:

```bash
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

The installer DTB selection (`pick_dtb` in `scripts/install-sp11-support.sh`)
now extracts the numeric suffix after `sp11v` and prefers the newest one:

```bash
sp11="$(printf '%s\n' "$@" | grep -E 'sp11v[0-9]+' || true)"
if [ -n "$sp11" ]; then
  newest_suffix="$(printf '%s\n' "$sp11" | sed -nE 's/.*sp11v([0-9]+).*/\1/p' | sort -n | tail -n 1)"
  printf '%s\n' "$sp11" | grep -E "sp11v${newest_suffix}" | sort -V | tail -n 1
else
  printf '%s\n' "$@" | sort -V | tail -n 1
fi
```

## Consequences

- The v3 kernel boots with the touchscreen DTB enabled; the MSHW0485 controller
  initializes (`touch controller initialized path=hardware`) and the input
  device reports as `Microsoft Surface G6 Touch`.
- Multi-touch, pinch/zoom, and three-finger gestures work through the Linux
  `mshw0485_touch` HID-SPI driver.
- The 2.4 MHz DMIC clock and the audio capture path from v2 are unchanged and
  remain working.
- The touchscreen works only with the geocausa `updates/` modules present and
  an initramfs that loads them; a stock-kernel-only boot binds the stock `gpi`
  driver and the touch DMA path fails.
- The plain `7.2-rc5-jg-0` and `7.2-rc5-jg-0sp11v2` ABIs remain co-installable
  as rollback options but are no longer the recommended Surface Pro 11 kernels.
