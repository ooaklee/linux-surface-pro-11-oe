# Surface Pro 11 Installed Wi-Fi rfkill Test - 2026-06-13

## Context

After [the installed NVMe boot test](installed-nvme-boot-test-20260613.md),
the GRUB `sp11-denali.dtb` path warning was fixed and the system booted with
the Surface Pro 11 DTB loaded from the separate `/boot` filesystem.

The installed-system finish helper had installed firmware support and the
temporary WCN7850 board-file fixup.

## Result

Wi-Fi still did not become usable from the desktop UI. Toggling Wi-Fi on caused
it to immediately return to off.

Diagnostics showed:

| Check | Result |
| --- | --- |
| PCI device | `17cb:1107` Qualcomm WCN785x / FastConnect 7800 present. |
| Driver probe | `ath12k_wifi7_pci` detected `wcn7850 hw2.0`. |
| Firmware load | Firmware loaded and reported a build version. |
| Interface creation | Driver renamed `wlan0` to `wlP4p1s0`. |
| Board file | `/lib/firmware/ath12k/WCN7850/hw2.0/board.bin` exists. |
| Bluetooth rfkill | `hci0` soft-blocked `no`, hard-blocked `no`. |
| Wi-Fi rfkill | `phy0` soft-blocked `no`, hard-blocked `yes`. |
| DT `disable-rfkill` property | Missing from `/sys/firmware/devicetree/base/soc@0/pci@1c08000/pcie@0/wifi@0`. |
| ath12k `disable-rfkill` support | Not found in the installed ath12k modules by string scan. |

## Interpretation

The firmware and board-file steps are far enough along for the driver to bind,
load firmware, and create a network interface. The remaining blocker is a
hardware rfkill state on the Wi-Fi PHY.

This matches the Surface Pro 11 Arch bring-up notes: without extra ath12k and
device-tree handling, Wi-Fi remains hard-blocked by rfkill even though the
device can probe.

## Next Steps

Check whether the installed Ubuntu ath12k module supports the `disable-rfkill`
device-tree property. If it does, test adding `disable-rfkill;` to the
`wifi@0` node under the WCN7850 PCIe port in `/boot/sp11-denali.dtb`.

This is not a module parameter, so `modinfo` alone is not enough. A practical
first check is to run the troubleshooting helper:

```bash
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

The core module-support check performed by the helper is:

```bash
found=0
while IFS= read -r module; do
  case "$module" in
    *.zst) reader=zstdcat ;;
    *.xz) reader=xzcat ;;
    *) reader=cat ;;
  esac
  command -v "$reader" >/dev/null 2>&1 || continue
  if "$reader" "$module" | strings | grep -q 'disable-rfkill'; then
    echo "disable-rfkill support found in $module"
    found=1
  fi
done < <(find "/lib/modules/$(uname -r)" -type f -path '*ath12k*')
test "$found" = 1 || echo "disable-rfkill support not found in installed ath12k modules"
```

If the installed kernel does not support that property, Wi-Fi requires a
patched kernel or module equivalent to the Surface Pro 11 Arch bring-up's
ath12k rfkill patch.
