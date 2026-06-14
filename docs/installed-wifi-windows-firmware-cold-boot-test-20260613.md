# Surface Pro 11 Wi-Fi Test After Windows Firmware and Cold Boot - 2026-06-13

## Context

After the installed Ubuntu boot was stable on `7.0.0-32-qcom-x1e`, firmware was
copied from the mounted Windows NTFS partition with:

```bash
sudo ./scripts/finish-sp11-installed-system.sh \
  --windows-root "/run/media/<user>/Local Disk"
```

The helper installed Qualcomm platform firmware, left `adsp_dtb.mbn` enabled
because the root filesystem was on NVMe, installed the WCN7850 `board.bin`
fixup, and refreshed initramfs for both installed qcom-x1e kernels.

The first reboot after firmware installation briefly changed the failure mode:
the WCN7850 PCI device was present, but `ath12k_wifi7_pci` failed during probe
with MHI/global-reset errors, so the desktop did not show a Wi-Fi device.

After a full cold boot, the device returned to the earlier probe-and-rfkill
state.

## Result

The cold-boot diagnostic ran on:

```text
7.0.0-32-qcom-x1e
```

Wi-Fi was visible in the desktop UI again, but could not be enabled.

| Check | Result |
| --- | --- |
| Device tree model | `Microsoft Surface Pro 11th Edition (OLED)` |
| Compatible | `microsoft,denali-oled microsoft,denali qcom,x1e80100` |
| PCI Wi-Fi | `17cb:1107` WCN785x / FastConnect 7800 present. |
| Network interface | `wlP4p1s0` created but down. |
| Bluetooth rfkill | `hci0` soft-blocked `no`, hard-blocked `no`. |
| Wi-Fi rfkill | `phy0` soft-blocked `no`, hard-blocked `yes`. |
| DT `disable-rfkill` property | Missing from `wifi@0`. |
| ath12k `disable-rfkill` support | Not found in installed ath12k modules. |
| Board file | `/lib/firmware/ath12k/WCN7850/hw2.0/board.bin` present. |

The dmesg output showed WCN7850 probing successfully:

```text
ath12k_wifi7_pci 0004:01:00.0: Wi-Fi 7 Hardware name: wcn7850 hw2.0
ath12k_wifi7_pci 0004:01:00.0: fw_version 0x1103006c ...
ath12k_wifi7_pci 0004:01:00.0 wlP4p1s0: renamed from wlan0
```

It also still showed missing audio topology firmware:

```text
Direct firmware load for qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin failed with error -2
```

## Interpretation

Windows firmware extraction and the WCN7850 board-file fixup are sufficient for
the stock qcom-x1e kernel to probe Wi-Fi after a cold boot.

The remaining Wi-Fi blocker is still the platform rfkill path: the loaded DTB
does not contain `disable-rfkill`, and the installed ath12k modules do not
contain support for that property.

This result separates board data from rfkill. A missing board-data failure
would show failed board-file lookup or firmware probe errors before interface
creation. The verified state has a created `wlP4p1s0` interface and a hard
rfkill block, so replacing `board-2.bin` is not the next fix for this machine.

The transient post-firmware MHI/global-reset failure appears recoverable by a
full cold boot. If it recurs consistently, retest with `adsp_dtb.mbn` disabled
to isolate aDSP bring-up from Wi-Fi PCIe/MHI bring-up.

## Next Steps

Continue with the patched qcom-x1e kernel experiment from
[ADR019](adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) and
[the patched-kernel how-to](how-to/how-to-build-patched-qcom-x1e-kernel.md).

The patched kernel must provide both:

- ath12k support for `disable-rfkill`,
- `disable-rfkill;` on the Denali WCN7850 `wifi@0` device-tree node.
