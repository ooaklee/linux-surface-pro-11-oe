---
id: adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build
title: "ADR0054: JG 7.2-rc5-jg-0sp11v4 In-Tree Touchscreen Kernel Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v4 build of Johan G.'s qcom-x1e 7.2-rc5-jg-0 kernel, carrying the phase55 MSHW0485 touchscreen stack in tree.
---

# ADR0054: JG 7.2-rc5-jg-0sp11v4 In-Tree Touchscreen Kernel Build

## Status

The `7.2-rc5-jg-0sp11v4-qcom-x1e` kernel was hardware-verified on the
X1E80100 OLED device. The kernel boots, the touchscreen works as the input
device `Microsoft Surface G6 Touch`, the in-tree `mshw0485_touch`,
`spi_geni_qcom`, and `gpi` drivers load, and sound works.

## Context

[ADR-0049](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md) used the
out-of-tree geocausa modules approach for the Surface Pro 11 touchscreen.
There was also a HID-over-SPI patch approach in issue #34 / PR #4. The v4
kernel supersedes both approaches with a straight in-tree port of the phase55
driver stack, so there is no out-of-tree module install step.

The source is the `sp11/qcom-x1e-7.2-rc5-touchscreen-intree` branch of
`ooaklee/linux_ms_dev_kit-sp11` at commit `48d3cf72c` (`arm64: qcom:
x1-denali: add in-tree MSHW0485 touchscreen (phase55)`). The branch is based
on jglathe 7.2-rc5-jg-0.

## Decision

Build the Surface Pro 11 in-tree touchscreen kernel from that fork branch and
commit, using Debian ABI `0sp11v4` and kernel release
`7.2-rc5-jg-0sp11v4-qcom-x1e`.

Carry the phase55 touchscreen stack directly in the kernel source, including
the QSPI changes to the Qualcomm GPI DMA and GENI SPI drivers, the
`mshw0485_touch` driver and its profiles, the required bindings and interface
changes, the Denali device-tree nodes, and the kernel configuration. Do not
use a separate out-of-tree touchscreen module installation.

Use
`patches/sp11-qcom-x1e-7.2-rc5-v4/0001-debian-qcom-x1e-name-SP11-v4-build.patch`
in the packaging repository to name the SP11 v4 build.

## Decision details

The in-tree port changes 12 paths, with approximately 5,180 insertions and 68
deletions:

- `drivers/dma/qcom/gpi.c` (phase55, QSPI)
- `drivers/spi/spi-geni-qcom.c` (phase55)
- `drivers/input/touchscreen/mshw0485_touch.c` (added)
- `drivers/input/touchscreen/g6ts_classifier_profile.h` (added)
- `drivers/input/touchscreen/g6ts_lifecycle_profile.h` (added)
- `drivers/input/touchscreen/Kconfig` (`TOUCHSCREEN_MSHW0485`)
- `drivers/input/touchscreen/Makefile` (`mshw0485_touch.o`)
- `include/linux/spi/spi-geni-qcom-biosref.h` (added)
- `include/dt-bindings/dma/qcom-gpi.h` (`QCOM_GPI_QSPI`)
- `include/linux/dma/qcom-gpi-dma.h` (`qspi` field)
- `arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi` (touchscreen/QSPI
  nodes and 2.4 MHz DMIC clock)
- `debian.master/config/annotations`

The build produces the following Debian package types under
`payload/kernel-debs/sp11v4/`:

- `linux-image`
- `linux-modules`
- `linux-headers`
- `linux-qcom-x1e-headers`

## Consequences

- The phase55 MSHW0485 touchscreen support is part of the kernel build; no
  out-of-tree touchscreen module install step is required.
- The v4 kernel boots on the X1E80100 OLED device and exposes the working
  touchscreen as `Microsoft Surface G6 Touch`.
- The in-tree `mshw0485_touch`, `spi_geni_qcom`, and `gpi` drivers load.
- The Denali device tree carries the touchscreen and QSPI nodes together with
  the 2.4 MHz DMIC clock, and sound works on the verified device.
- This decision supersedes the ADR-0049 out-of-tree geocausa modules approach
  and the HID-over-SPI patch approach from issue #34 / PR #4.
