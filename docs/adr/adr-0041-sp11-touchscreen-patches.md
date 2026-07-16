---
id: adr-0041-sp11-touchscreen-patches
title: "ADR0041: Surface Pro 11 Touchscreen Kernel Patch Set"
# prettier-ignore
description: Architecture Decision Record (ADR) for the structure and sourcing of the Surface Pro 11 touchscreen QSPI HID-over-SPI kernel patches in patches/sp11-touchscreen/.
---

# ADR0041: Surface Pro 11 Touchscreen Kernel Patch Set

## Status

Accepted (2026-07-16).

## Context

The Surface Pro 11 touchscreen is a QSPI (Quad SPI) HID-over-SPI device
attached to the Qualcomm Snapdragon X Elite's SPI10 (qup_se10) bus. The
mainline `spi-geni-qcom` driver does not support QSPI 1-4-4 mode, the
mainline `gpi` DMA driver does not handle QSPI protocol TRE construction,
and no upstream HID-over-SPI transport driver exists.

Patches were sourced from the [x1e-nixos](https://github.com/x1e-nixos)
project, which backported QSPI support from the Android `spi-msm-geni`
driver and authored the `spi-hid` transport driver. These patches must be
adapted for the Ubuntu `qcom-x1e-7.1.3-jg-0` kernel tree (Johan G.'s
fork) and maintained alongside the repository's other patch sets.

## Decision

The touchscreen patches are placed in a dedicated directory,
`patches/sp11-touchscreen/`, with a numbered sequence that encodes the
dependency chain. Patches must be applied in strict numeric order:

| # | Component | Purpose |
|---|-----------|---------|
| 0001 | `drivers/dma/qcom/gpi.c` | QSPI protocol TRE construction: GO WD0 flag fields, SCRATCH_0 passthrough, immediate/chain/link logic |
| 0002 | `drivers/spi/spi-geni-qcom.c` | QSPI 1-4-4 mode: SE_PROTO 9, io mux, lane flags, GPI DMA register reprogramming, mode bits, DT properties |
| 0003-01..11 | `drivers/hid/spi-hid/` | HID-over-SPI transport driver: core, protocol framing, trace events, ACPI/OF/DT probe, power management, panel follower |
| 0004 | `arch/arm64/boot/dts/qcom/` | DTS: SPI10 QSPI node, pinctrl, touchscreen sub-node, GPIO reserved ranges |

### QSPI Sync-Byte Issue

During initial bring-up, the touchscreen returned sync byte `0x12` instead
of the required `0x5a` (`SPI_HID_INPUT_HEADER_SYNC_BYTE`), causing the
`spi-hid` driver to reject every input report.

Root cause: the QSPI lane flag logic in `spi_geni_transfer_one` (patch
0002) unconditionally set `QSPI_QUAD_SDR` (4-lane receive) for all RX
transfers. The SPI HID protocol communicates via single-lane SPI (1-bit on
IO0), so quad-lane sampling interleaved bits across the four IO lines and
produced corrupted data.

The fix is integrated into patches 0002 and 0004:

- **0002** — lane flags default to `QSPI_SINGLE_SDR` (single-lane). The
  driver only enables `QSPI_QUAD_SDR` when the device DTS declares
  `spi-rx-bus-width = <4>` and the transfer is a read (data phase).

- **0004** — the touchscreen DTS node sets `spi-rx-bus-width = <1>` and
  `spi-tx-bus-width = <1>`, accurately describing the single-lane SPI HID
  protocol layered on QSPI hardware.

This approach preserves correct behaviour for QSPI NOR flash devices
(relying on `spi-rx-bus-width = <4>`) while fixing the touchscreen.

### Patch Sourcing and Adaptation

All patches originate from the x1e-nixos project. Adaptations required for
the Ubuntu qcom-x1e kernel tree included:

- **0002**: the 7.1.3 kernel carries TPM SPI fragmentation patches that
  changed context around the QSPI lane flag insertion point. The patch was
  regenerated against `spi-geni-qcom.c` from `jg/ubuntu-qcom-x1e-7.1.3-jg-0`
  with the lane flag fix integrated directly.

- **0004**: the original patch contained bogus `wcd->spi10` DTS labels and
  an incorrect `gpio-reserved-ranges` hunk. These were removed. The patch
  was regenerated against the 7.1.3 Denali DTSI (which differs from the
  7.0 upstream version).

- **0003-03**: the spi-hid core driver patch used 40-char commit hashes in
  `From:` headers. These were shortened to the standard 12-char format for
  `git apply` compatibility.

### Build Integration

The touchscreen patches require Johan G.'s build-compatibility patches
(`patches/jglathe-qcom-x1e-7.1.3/`) for the Debian config annotations and
stubble paths. Both sets are applied together via `--patch-dirs` (see
[ADR-0040](adr-0040-multi-patch-dirs.md)):

```bash
--patch-dirs "patches/sp11-touchscreen patches/jglathe-qcom-x1e-7.1.3"
```

## Alternatives Considered

**Single merged patch directory (rejected).** Merging all patches into one
directory with renumbered files would obscure provenance and complicate
maintenance when the JG build-compatibility patches are updated
independently of the touchscreen driver patches.

**Upstream `spi-hid` driver separately (considered).** The `spi-hid`
driver exists as an independent series on the linux-input mailing list.
Including it as part of this patch set avoids managing a separate kernel
tree merge and keeps the Surface Pro 11 bring-up self-contained. When the
driver lands upstream in a future kernel, the patches can be retired.

## Consequences

- The touchscreen driver probes and the `spi-hid` driver binds to the
  device. The sync byte is correctly validated at `0x5a`.

- The 14 patches are validated against the exact kernel source they target
  (`jg/ubuntu-qcom-x1e-7.1.3-jg-0`). Changes to the kernel tree's
  `spi-geni-qcom.c`, `gpi.c`, or Denali DTSI may require patch regeneration.

- Kernel version upgrades (e.g., future 7.2.x releases) will require
  re-validating the patches against the new source and regenerating any
  that fail due to context changes.

- The spi-hid driver and QSPI patches are expected to be upstreamed
  eventually. When that happens, the corresponding patches in this
  directory should be removed.
