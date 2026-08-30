# Surface Pro 11 Wi-Fi rfkill Test After Patched qcom-x1e Boot - 2026-06-14

> [!IMPORTANT]
> **Immutable historical evidence — not a current procedure.**
> This record preserves the patched-kernel Wi-Fi observations made on 14 June
> 2026. Its kernel and DTB workaround, live-network commands, and next steps are
> retained as evidence, not as current bring-up or remediation guidance.

## Current Read-Only Check

Inspect the current static Wi-Fi support state with:

```sh
linux-armer doctor userspace --feature wifi
```

The doctor checks package and firmware files without probing the radio. It does
not inspect live rfkill state, scan, associate, reconnect, or prove traffic.
The historical `nmcli`, `iw`, and journal commands below can expose SSIDs,
BSSIDs, saved-network names, MAC addresses, and interface identifiers; redact
their output before sharing it.

## Context

The Surface Pro 11 installed system had previously upgraded to
`7.0.0-32-qcom-x1e`, but that kernel still reported Wi-Fi as hard-blocked.
The first successful Docker git-fallback kernel build produced patched
`7.0.0-22-qcom-x1e` packages instead of matching `7.0.0-32-qcom-x1e`.

Before booting the patched kernel, `/boot/sp11-denali.dtb` was manually
refreshed from:

```text
/usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
```

The staged DTB was verified to contain `disable-rfkill`, and GRUB was verified
to inject `devicetree /sp11-denali.dtb` for the separate `/boot` layout.

## Result

The one-time GRUB boot into the patched kernel succeeded:

```text
7.0.0-22-qcom-x1e
```

The Wi-Fi rfkill diagnostic reported:

| Check | Result |
| --- | --- |
| Device tree model | `Microsoft Surface Pro 11th Edition (OLED)` |
| Compatible | `microsoft,denali-oled microsoft,denali qcom,x1e80100` |
| PCI Wi-Fi | `17cb:1107` WCN785x / FastConnect 7800 present. |
| Driver probe | `ath12k_wifi7_pci` detected `wcn7850 hw2.0`. |
| Firmware load | Firmware loaded and reported a build version. |
| Interface creation | `wlP4p1s0` created and marked `UP`, with `NO-CARRIER` before association. |
| Bluetooth rfkill | `hci0` soft-blocked `no`, hard-blocked `no`. |
| Wi-Fi rfkill | `phy0` soft-blocked `no`, hard-blocked `no`. |
| DT `disable-rfkill` property | Present on the WCN7850 `wifi@0` node. |
| ath12k `disable-rfkill` string scan | Not found by the helper, despite the runtime rfkill state clearing. |
| Board file | `/lib/firmware/ath12k/WCN7850/hw2.0/board.bin` present. |
| Network scan | Working; GNOME listed nearby Wi-Fi networks. |
| Association | Working; the system connected to a Wi-Fi network. |
| Traffic | Working; a browser speed test completed successfully. |

The dmesg output showed WCN7850 probing successfully:

```text
ath12k_wifi7_pci 0004:01:00.0: Wi-Fi 7 Hardware name: wcn7850 hw2.0
ath12k_wifi7_pci 0004:01:00.0: fw_version 0x1103006c ...
ath12k_wifi7_pci 0004:01:00.0 wlP4p1s0: renamed from wlan0
```

It also still showed the known missing audio topology firmware:

```text
Direct firmware load for qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin failed with error -2
```

## Interpretation

The patched qcom-x1e kernel plus rfkill-capable Denali DTB cleared the verified
Wi-Fi hard-block gate. This is the first local test where `phy0` reports
`Hard blocked: no`.

The helper's module string scan is best-effort and produced a false-negative
or non-authoritative result in this boot. Runtime validation should prioritise:

- the running kernel ABI,
- the loaded DTB property,
- `rfkill` soft/hard state,
- WCN7850 probe and interface creation.

Follow-up testing confirmed that NetworkManager/GNOME can scan, associate,
authenticate, and pass traffic over Wi-Fi. A browser speed test completed at
approximately 436 Mbps download and 302 Mbps upload.

Redacted visual evidence:

- [Wi-Fi networks visible in GNOME](../assets/wifi/2026-06-14-sp11-wifi-networks-redacted.png)
- [Browser speed test after Wi-Fi connection](../assets/wifi/2026-06-14-sp11-speedtest-redacted.webp)

## Historical Next Steps

The following commands and recommendations are retained as part of the dated
investigation. They operate on the live network and are not part of the current
`linux-armer` static validation flow.

The recorded stability work covered repeated boots, suspend/resume cycles, and
normal desktop use.

The recorded quick post-boot check was:

```bash
nmcli radio wifi on
nmcli device status
nmcli device wifi list --rescan yes
```

The recorded reconnection fallback used GNOME Settings or:

```bash
nmcli device wifi connect "<ssid>" --ask
```

The recorded diagnostic collection for a later failure was:

```bash
iw dev
sudo iw dev wlP4p1s0 scan | head -n 120
journalctl -b -u NetworkManager --no-pager | tail -n 120
```

The record also recommended keeping `7.0.0-32-qcom-x1e` installed as a fallback
and avoiding `apt autoremove` until Wi-Fi behaviour was known after several
boots.
