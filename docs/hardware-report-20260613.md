# Surface Pro 11 Hardware Report - 2026-06-13

Source: Windows diagnostic report collected from the target Surface Pro 11 over
AnyDesk/Live Share.

## Device

| Field | Value |
| --- | --- |
| Manufacturer | Microsoft Corporation |
| Model | Microsoft Surface Pro, 11th Edition |
| Product name | Microsoft Surface Pro, 11th Edition |
| Product version | `<redacted>` |
| SKU | `Surface_Pro_11th_Edition_2076` |
| UUID | `<redacted>` |
| BIOS | `175.222.235` |
| BIOS date | 2026-02-23 |
| Baseboard | Microsoft Surface Pro, 11th Edition |
| OS | Microsoft Windows 11 Home Insider Preview |
| Build | `29585` |
| CPU | Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz |

The Secure Boot value was blank in the pasted report. Confirm manually before
boot testing.

## Storage

| Disk | Friendly name | Bus | Partition style | Size | Status |
| --- | --- | --- | --- | --- | --- |
| 0 | `MZ9L4512HBLU-00BMV-SAMSUNG` | NVMe | GPT | 476.9 GiB | Online |

| Volume | Label | Filesystem | Size | Type |
| --- | --- | --- | --- | --- |
| Windows RE tools | Windows RE tools | NTFS | 2 GiB | Fixed |
| C: | Local Disk | NTFS | 474.7 GiB | Fixed |

## Firmware Observations

The Windows DriverStore contains the expected Surface Pro 11 Denali firmware
files:

| Firmware | Observed source |
| --- | --- |
| `qcdxkmsuc8380.mbn` | `C:\WINDOWS\System32` and `qcdx8380.inf_arm64_*` |
| `qcdxkmsucpurwa.mbn` | `C:\WINDOWS\System32` and `qcdx8380.inf_arm64_*` |
| `adsp_dtbs.elf` | `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae` |
| `qcadsp8380.mbn` | `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae` |
| `cdsp_dtbs.elf` | `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a` and `qcsubsys_ext_cdsp8380.inf_arm64_9ed31fd1359980a9` |
| `qccdsp8380.mbn` | `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a` and `qcsubsys_ext_cdsp8380.inf_arm64_9ed31fd1359980a9` |
| `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `battmgr.jsn` | `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae` |
| `cdspr.jsn` | `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a` and `qcsubsys_ext_cdsp8380.inf_arm64_9ed31fd1359980a9` |

## Relevant Devices

Windows reports:

- Qualcomm FastConnect 7800 / WCN7850 Wi-Fi:
  `PCI\VEN_17CB&DEV_1107&SUBSYS_110717CB&REV_01`
- Qualcomm FastConnect 7800 Bluetooth UART transport.
- Surface HID keyboard, mouse, touchpad, touchscreen, touch/pen processor, and
  digitizer devices.
- Qualcomm USB3 eXtensible Host Controller and Synopsys USB 3.0 dual-role
  controllers.
- Surface SMF thermal, fan, CPU, display, and system-management clients.
