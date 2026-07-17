---
id: adr-0042-sp11-touchscreen-troubleshooting
title: "ADR0042: Surface Pro 11 Touchscreen — Kernel Integration Troubleshooting"
# prettier-ignore
description: Architecture Decision Record (ADR) documenting the troubleshooting history, root-cause analysis, and remaining blockers for enabling the Surface Pro 11 touchscreen on the jglathe/linux_ms_dev_kit kernel at tag jg/ubuntu-qcom-x1e-7.1.3-jg-0.
---

# ADR0042: Surface Pro 11 Touchscreen — Kernel Integration Troubleshooting

## Status

Draft (2026-07-17). Work in progress.

## Context

ADR-0041 documents the patch set (spi-hid, QSPI mode, GPI DMA, DTS).
This ADR tracks the **attempts to get those patches working at runtime**
on a Surface Pro 11 (Microsoft Denali OLED, Snapdragon X Elite).

The release kernel from
<https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-0-touch>
was installed but the touchscreen did not work. Local kernel rebuilds with
config changes were attempted interactively on the device to diagnose and
fix the problem.

### Hardware

- Surface Pro 11 (OLED)
- Touchscreen: QSPI HID-over-SPI device on QUP SE10 (`spi@a88000`)
- SoC: Snapdragon X Elite (X1E80100)
- Boot: EDK2 → Stubble → GRUB (arm64-efi) → Linux

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

### 4. Kernel uses EFI firmware DTB, NOT GRUB's devicetree directive

**Critical finding.** GRUB is configured with `devicetree /sp11-denali.dtb`,
and the DTB at that path has the touchscreen node. However, the live
`/proc/device-tree` showed `spi@a88000` with:
- `compatible = "qcom,geni-spi"` (not `qcom,geni-spi-qspi`)
- `status = "disabled"` (not `"okay"`)
- No `touchscreen@0` child

The boot chain on this device works as follows:
1. **Stubble** (firmware shim) creates an FDT and registers it in the
   EFI Configuration Table
2. **GRUB** loads `devicetree /sp11-denali.dtb` — this tries to override
   the EFI FDT
3. **Kernel** EFI stub reads from `get_fdt()` (EFI Configuration Table) —
   GRUB's override is **not taking effect** on this platform

Evidence:
- `/sys/firmware/fdt` had a DIFFERENT MD5 than `/boot/sp11-denali.dtb`
- `md5sum /sys/firmware/fdt` ≠ `md5sum /boot/sp11-denali.dtb`
- Live tree confirmed the Stubble-provided DTB was active, not ours

### 5. Copied DTB to EFI partition — no effect

Copied `/boot/sp11-denali.dtb` to:
- `/boot/efi/x1e80100-microsoft-denali.dtb`
- `/boot/efi/x1e80100-microsoft-denali-el2.dtb`

**No change.** The kernel still used the EFI Configuration Table FDT,
not the files in `/boot/efi/`.

### 6. `dtb=` kernel command line parameter — the real fix (but blocked)

The ARM64 EFI stub in `drivers/firmware/efi/libstub/fdt.c` supports a
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

## Root Cause Summary

The Stubble bootloader registers a DTB in the EFI Configuration Table
that defines `spi@a88000` with `compatible = "qcom,geni-spi"` and
`status = "disabled"`. GRUB's `devicetree` directive cannot override
this. The kernel must use either:

| Mechanism | Config Needed | Status |
|-----------|--------------|--------|
| `dtb=` cmdline | `CONFIG_EFI_ARMSTUB_DTB_LOADER=y` | Enabled in rebuild; kernel hangs |
| configfs overlay | `CONFIG_OF_OVERLAY_CONFIGFS=y` | Not yet enabled |
| fdtoverlay + initramfs | N/A (userspace) | Possible fallback |

## Diagnostics Reference

### Check if kernel loaded our DTB
```bash
md5sum /sys/firmware/fdt /boot/sp11-denali.dtb
# If mismatch → kernel ignored GRUB's devicetree
```

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

## Remaining Steps (for future work)

1. **Rebuild kernel initrd** (`update-initramfs -u -k ...`) and try `dtb=sp11-denali.dtb`
   (without leading slash) as the sole override mechanism (remove `devicetree`
   from GRUB)
2. OR: build kernel with `CONFIG_OF_OVERLAY_CONFIGFS=y` and apply overlay at
   runtime after boot
3. OR: use an initramfs hook with `fdtoverlay` to patch the FDT before driver
   probing
4. OR: rebuild a full kernel .deb via `make bindeb-pkg` with all config changes
5. OR: fork the Stubble firmware to fix the DTB at source

## Consequences

- Positive: all patches apply clean, modules compile, DTB builds correctly
- Positive: the root cause (EFI FDT priority over GRUB devicetree) is well
  understood
- Negative: requires a kernel Image rebuild for `CONFIG_EFI_ARMSTUB_DTB_LOADER`,
  which is a slow build step
- Negative: the boot hang regression is not yet diagnosed
- Neutral: when resolved, the applied patches and DTB are complete — no
  further code changes are expected

## Related

- ADR-0041: Surface Pro 11 Touchscreen Kernel Patch Set (patch structure)
- `drivers/firmware/efi/libstub/fdt.c` — DTB loading in EFI stub
- `drivers/of/overlay.c` — runtime DT overlay support
