---
id: adr-0042-sp11-touchscreen-troubleshooting
title: "ADR0042: Surface Pro 11 Touchscreen — Kernel Integration Troubleshooting"
# prettier-ignore
description: Architecture Decision Record (ADR) documenting the troubleshooting history, root-cause analysis, and remaining blockers for enabling the Surface Pro 11 touchscreen on the jglathe/linux_ms_dev_kit kernel at tag jg/ubuntu-qcom-x1e-7.1.3-jg-0.
---

# ADR0042: Surface Pro 11 Touchscreen — Kernel Integration Troubleshooting

## Status

Historical troubleshooting record (2026-07-17), operationally resolved.

[ADR-0049](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md) records the
working v3 kernel, embedded touchscreen DTB, and exact-ABI module deployment.
[ADR-0055](adr-0055-retire-installed-loose-dtb-injection.md) retires the
installed loose-DTB helper and generated-GRUB rewriting. The failed experiments
and observations below are retained as history, not current installation
guidance.

## Context

ADR-0041 documents the patch set (spi-hid, QSPI mode, GPI DMA, DTS).
This ADR tracks the **attempts to get those patches working at runtime**
on a Surface Pro 11 (Microsoft Denali OLED, Snapdragon X Elite).

The kernel from the former `sp11-qcom-x1e-7.1.3-jg-0-touch` release was
installed but the touchscreen did not work. The release and tag were removed
on 2026-08-07: the packages omitted the touchscreen patches, and the tag
predated and disagreed with the release manifest. Local kernel rebuilds with
config changes were attempted interactively on the device to diagnose and fix
the problem.

### Hardware

- Surface Pro 11 (OLED)
- Touchscreen: QSPI HID-over-SPI device on QUP SE10 (`spi@a88000`)
- SoC: Snapdragon X Elite (X1E80100)
- Boot: EDK2 → GRUB (arm64-efi) → Stubble-wrapped kernel PE → Linux

### File Layout (on development machine)

```
<repo-root>/
├── linux-surface-pro-11-oe/       # This repository
│   └── patches/sp11-touchscreen/  # Touchscreen patch set (15 patches)
└── linux-ms-dev-kit/              # Kernel source checkout
    └── arch/arm64/boot/           # Built kernel images & DTBs
```

- Upstream kernel: `jglathe/linux_ms_dev_kit.git` branch `jg/ubuntu-qcom-x1e-7.1.3-jg-0`
- This repo: `ooaklee/linux-surface-pro-11-oe`

## Attempts and Observations

### 1. Installed release kernel — touchscreen not working

- Kernel: `7.1.3-jg-0-qcom-x1e`
- Symptoms:
  - `lsmod` showed no `spi_hid` or `spi_geni_qcom` modules
  - `/sys/bus/spi/devices/` was empty
  - No touchscreen in `/proc/bus/input/devices`
- Root cause: the kernel .deb was built **without the touchscreen patches**.
  CONFIG_SPI_HID was not set; the patches were never applied to the source
  used for the release build.

### 2. Built patched modules locally

All 15 patches applied clean to the kernel checkout.

Modules built via `make ARCH=arm64 MODNAME modules`:

| Module | Path | Purpose |
|--------|------|---------|
| `spi-hid.ko` | `drivers/hid/spi-hid/` | HID-over-SPI transport driver |
| `spi-hid-of.ko` | `drivers/hid/spi-hid/` | Device-tree probe glue |
| `spi-geni-qcom.ko` | `drivers/spi/` | QSPI 1-4-4 mode SPI controller |
| `gpi.ko` | `drivers/dma/qcom/` | QSPI DMA TRE construction |
| `hid.ko` | `drivers/hid/` | HID core with `BUS_SPI` addition |

**Build trick**: `make olddefconfig` needed `flex`. When `flex` wasn't available,
the build succeeded by copying compiled binaries from the installed kernel
headers (`/lib/modules/$(uname -r)/build/scripts/`) — specifically
`genksyms`, `fixdep`, `modpost`.

### 3. DTB built and installed

DTB built: `arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb`

Verified the DTB contains:
- `spi@a88000` with `compatible = "qcom,geni-spi-qspi"` and `status = "okay"`
- `touchscreen@0` child node with `compatible = "hid-over-spi"`

### 4. Tested installed Stubble image uses its embedded DTB

**Critical finding.** GRUB is configured with `devicetree /sp11-denali.dtb`,
and the DTB at that path has the touchscreen node. However, the live
`/proc/device-tree` showed `spi@a88000` with:
- `compatible = "qcom,geni-spi"` (not `qcom,geni-spi-qspi`)
- `status = "disabled"` (not `"okay"`)
- No `touchscreen@0` child

The observed installed boot chain works as follows:

1. Firmware starts **GRUB**.
2. GRUB loads the **Stubble-wrapped kernel PE**.
3. Stubble, as part of that self-executing kernel image, selects the embedded
   DTB and registers it in the EFI Configuration Table before Linux starts.
4. Linux receives that FDT. In this tested path, the loose GRUB
   `devicetree /sp11-denali.dtb` input did not determine the live tree.

Evidence:

- `/sys/firmware/fdt` had a different hash from
  `/boot/sp11-denali.dtb`. This is supporting evidence, not standalone proof,
  because firmware and boot-time fixups can change FDT bytes.
- The live `spi@a88000` properties retained the semantics of the DTB embedded
  in the packaged image and did not acquire the loose file's touchscreen
  changes.
- Replacing the loose file and copying candidates to the EFI System Partition
  did not change those live properties.
- A later test used a unique kernel-command-line marker to prove the intended
  GRUB entry ran, while the active DMIC property still matched the packaged
  embedded DTB. The package build also recorded the Denali DTB passed to
  `ukify --devicetree-auto` for the Stubble-wrapped image.

### 5. Copied DTB to EFI partition — no effect

Copied `/boot/sp11-denali.dtb` to:
- `/boot/efi/x1e80100-microsoft-denali.dtb`
- `/boot/efi/x1e80100-microsoft-denali-el2.dtb`

**No change.** The kernel still used the EFI Configuration Table FDT,
not the files in `/boot/efi/`.

### 6. Historical `dtb=` command-line override experiment

This experiment predated the packaged embedded-DTB resolution and is not the
current installed path. The ARM64 EFI stub in
`drivers/firmware/efi/libstub/fdt.c` supports a
`dtb=` kernel command-line parameter that loads a DTB from the same
filesystem the kernel was loaded from. The logic (lines 249–272):

```c
if (!IS_ENABLED(CONFIG_EFI_ARMSTUB_DTB_LOADER) ||
    efi_get_secureboot() != efi_secureboot_mode_disabled) {
    if (strstr(cmdline_ptr, "dtb="))
        efi_err("Ignoring DTB from command line.\n");
} else {
    status = efi_load_dtb(image, &fdt_addr, &fdt_size);
    ...
}
if (fdt_addr) {
    efi_info("Using DTB from command line\n");
} else {
    fdt_addr = (uintptr_t)get_fdt(&fdt_size);  // fallback to EFI config table
    ...
}
```

Requirements:
- **`CONFIG_EFI_ARMSTUB_DTB_LOADER=y`** — was `n` in the release kernel
- **Secure Boot disabled** — confirmed already disabled on this device

If the status from `efi_load_dtb` is neither `EFI_SUCCESS` nor
`EFI_NOT_READY`, the stub jumps to `goto fail` and the kernel does not boot.

### 7. Rebuilt kernel with `CONFIG_EFI_ARMSTUB_DTB_LOADER=y`

Kernel rebuild (just `make ARCH=arm64 Image`) required:
- `flex`, `bison`, `libssl-dev`, `bc`, `gawk` — installed via apt
- The Image compiled successfully (`arch/arm64/boot/Image`)
- EFI stub kernel built: `arch/arm64/boot/vmlinuz.efi` — correct format:
  `PE32+ executable for EFI (application)`
- Format matches the original Ubuntu kernel (also PE32+)

GRUB cmdline updated to include `dtb=/sp11-denali.dtb`.

**Result: kernel hangs at splash screen.** Possible causes:
- Initrd incompatibility — rebuilt with `update-initramfs -u -k 7.1.3-jg-0-qcom-x1e`
  (size went from 110MB to 108MB) but still no boot
- `make olddefconfig` may have changed critical boot options (confirmed
  NVME, EXT4, PCI, EFI options all matched)
- The `devicetree` directive and `dtb=` cmdline were simultaneously active;
  they may conflict
- The `dtb=/sp11-denali.dtb` path may need to omit the leading `/`
  (EFI file paths are ESP-relative)

### 8. DT overlay (configfs) — not available

`CONFIG_OF_OVERLAY=y` is set in the kernel config, but
`/sys/kernel/config/device-tree/` did not exist. This requires
`CONFIG_OF_OVERLAY_CONFIGFS=y` which was not set. A DT overlay `.dtbo`
was built at `/tmp/sp11-touchscreen-overlay.dtbo` but could not be
applied at runtime.

### 9. `fdtoverlay` — tool available but inaccessible

`fdtoverlay` (from device-tree-compiler) is installed at
`/usr/bin/fdtoverlay`. It can merge an overlay into a base FDT:
```bash
fdtoverlay -i /sys/firmware/fdt -o merged.dtb overlay.dtbo
```
However, `/sys/firmware/fdt` is root-owned and requires sudo.

## Resolution Summary

On the tested installed path, GRUB loads a Stubble-wrapped kernel PE. Stubble
then selects the DTB embedded in that exact image and registers the FDT before
Linux starts. The loose GRUB `devicetree` input did not override that
per-kernel pairing.

The operational resolution is to rebuild the complete qcom-x1e package so its
Stubble image embeds the intended Denali DTB. ADR-0049 records that resolution
for v3 and its working touchscreen deployment. The earlier override ideas are
historical experiments, not supported fallbacks:

| Historical mechanism | Config needed | Recorded result |
|-----------|--------------|--------|
| `dtb=` cmdline | `CONFIG_EFI_ARMSTUB_DTB_LOADER=y` | Rebuilt image hung; rejected for the current path |
| configfs overlay | `CONFIG_OF_OVERLAY_CONFIGFS=y` | Was unavailable and was not pursued |
| `fdtoverlay` + initramfs | N/A (userspace) | Considered only; not the packaged resolution |

The same handoff was reconfirmed on `7.1.3-jg-1-qcom-x1e` while preparing a
2.4 MHz DMIC clock experiment. A diagnostic GRUB entry was proven active by a
unique kernel-command-line marker, but the live device tree retained the
embedded 4.8 MHz value. Replacing `/boot/sp11-denali.dtb` and placing a test
DTB on the EFI System Partition also had no effect. The successful package
build log shows `ukify` receiving the Denali OLED DTB through
`--devicetree-auto` and writing the Stubble-wrapped kernel image.

## Diagnostics Reference

### Compare live and loose FDT bytes
```bash
sudo md5sum /sys/firmware/fdt /boot/sp11-denali.dtb
# A mismatch is supporting evidence only; boot-time fixups can change FDT bytes.
```

Do not infer provenance from that hash comparison alone. Compare the exact
packaged and Stubble-embedded DTBs, then verify stable identifying properties
in the active tree. When boot-time fixups prevent byte equality, use a reviewed
canonical tree comparison.

### Check live device tree for touchscreen
```bash
cat /proc/device-tree/soc@0/geniqup@ac0000/spi@a88000/compatible | tr '\0' '\n'
cat /proc/device-tree/soc@0/geniqup@ac0000/spi@a88000/status | tr '\0' '\n'
ls /proc/device-tree/soc@0/geniqup@ac0000/spi@a88000/touchscreen@0/
```

### Check kernel config for critical DTB/overlay options
```bash
grep -E "EFI_ARMSTUB_DTB_LOADER|OF_OVERLAY_CONFIGFS|OF_OVERLAY|SPI_HID" /boot/config-$(uname -r)
```

### Check if spi-hid module will bind
```bash
modinfo spi-hid | grep alias
modinfo spi-geni-qcom | grep alias
```

### Check boot process (EFI stub logging)
```bash
sudo dmesg | grep -iE "fdt|device.tree|dtb|EFI stub"
```

## Operational Resolution and Follow-Up

1. ADR-0049 resolves the touchscreen DTB requirement by rebuilding the
   complete qcom-x1e package and embedding the modified Denali DTB in the
   exact Stubble-wrapped v3 kernel image.
2. ADR-0055 retires the deployed loose-DTB helper and both managed kernel hooks
   before another kernel package is installed. A successful live-root
   `update-grub` is required, and the old loose file remains untouched and
   inert.
3. Future DT experiments must use distinct co-installable ABIs, verify that
   each packaged Denali DTB matches its Stubble-embedded copy, and compare the
   active tree semantically after boot.
4. Keep a boot-tested packaged kernel, its initramfs and modules, and physical
   recovery media available throughout testing.

The `dtb=` loader, configfs overlay, initramfs overlay, and Stubble-fork ideas
above are retained only as rejected or uncompleted historical alternatives.

## Consequences

- Positive: the handoff and per-kernel embedded-DTB requirement are understood,
  and ADR-0049 records a working packaged resolution.
- Positive: co-installed ABIs can retain exact kernel/DTB pairing without a
  shared mutable installed file.
- Caution: a live-FDT/loose-file hash mismatch is not standalone provenance
  proof because boot-time fixups can alter bytes.
- Historical: the `dtb=` rebuild hang was not diagnosed, but that path is not
  needed by the current packaged resolution.

## Related

- [ADR-0041: Surface Pro 11 Touchscreen Kernel Patch Set](adr-0041-sp11-touchscreen-patches.md)
- [ADR-0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR-0055: Retire Installed Loose-DTB Injection](adr-0055-retire-installed-loose-dtb-injection.md)
- `drivers/firmware/efi/libstub/fdt.c` — DTB loading in EFI stub
- `drivers/of/overlay.c` — runtime DT overlay support
