# Surface Pro 11 Wi-Fi rfkill Test After qcom-x1e Upgrade - 2026-06-13

## Context

After the initial installed Wi-Fi rfkill test, the system was upgraded from the
first installed qcom-x1e kernel to `7.0.0-32-qcom-x1e`. This tested whether the
newer Ubuntu qcom-x1e packages already included the Surface Pro 11 ath12k
`disable-rfkill` support.

GRUB DTB injection remained correct after the upgrade:

```text
devicetree /sp11-denali.dtb
```

## Result

The upgraded kernel booted successfully:

```text
7.0.0-32-qcom-x1e
```

Wi-Fi still remained hard-blocked:

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

The dmesg output showed WCN7850 probing, firmware loading, and interface
renaming from `wlan0` to `wlP4p1s0`. It also showed the Surface keyboard
devices being detected through the Surface Aggregator path.

## Interpretation

The qcom-x1e package upgrade improved the baseline and kept the installed boot
path working, but it did not include the required ath12k `disable-rfkill`
support. The Wi-Fi blocker is still kernel-side plus DTB-side rfkill handling.

A DTB-only edit should not be tested yet, because the running ath12k modules do
not know how to read the `disable-rfkill` devicetree property.

## Next Steps

Build and test a patched Ubuntu qcom-x1e kernel that carries both:

- ath12k support for `disable-rfkill`,
- `disable-rfkill;` on the Denali WCN7850 `wifi@0` node.

The build flow is tracked in
[ADR019](adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) and
[the patched-kernel how-to](how-to/how-to-build-patched-qcom-x1e-kernel.md).
