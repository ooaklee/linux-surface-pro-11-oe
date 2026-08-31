# Surface Pro 11 Wi-Fi Clean USB Flow Test - 2026-06-14

Last reviewed: 2026-08-30

> [!IMPORTANT]
> **Immutable historical evidence — not a current procedure.**
> This record preserves the Wi-Fi result observed on 14 June 2026. Its USB
> layout, support helpers, patched kernel, DTB workaround, and follow-up are
> historical and must not be used as current bring-up instructions.

## Current Read-Only Checks

For a newly generated ISO and a current installed system, use:

```sh
lexr image validate "<generated.iso>"
lexr doctor userspace --feature wifi
lexr doctor hardware wifi
```

The image validator checks the generated ISO rather than the written USB or
radio. The userspace doctor checks static package and firmware state. The
hardware doctor adds bounded PCI, driver, loaded device-tree, rfkill and
interface evidence without changing the radio. Neither doctor scans,
associates, reconnects, or proves traffic. Commands and logs that do exercise
Wi-Fi can expose SSIDs, BSSIDs, saved-network names, and interface identifiers.
Redact them before sharing output or screenshots.

## Context

The first successful Wi-Fi test required a manually refreshed
`/boot/sp11-denali.dtb`. A later image validation pass confirmed the patched
kernel packages were present on `SP11DATA`, but the support scripts in the USB
image were stale and could still overwrite `/boot/sp11-denali.dtb` with a DTB
that did not contain `disable-rfkill`.

The direct live USB image was rebuilt from the current repository state and
rewritten to the USB media. The rebuilt image carried:

- patched `7.0.0-22-qcom-x1e` kernel packages under `payload/kernel-debs`,
- current support scripts under `support/scripts`,
- `install-sp11-support.sh` containing the `disable-rfkill` DTB preference,
- the `Using Surface Pro 11 DTB:` log marker for operator verification.

## Clean Flow

From the installed Ubuntu system, `SP11DATA` was mounted and the support helper
was reinstalled from the rebuilt USB.

The helper selected the patched Denali OLED DTB:

```text
Using Surface Pro 11 DTB: /usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
```

The staged boot DTB was verified:

```text
/boot/sp11-denali.dtb contains disable-rfkill
```

After a one-time GRUB boot into the patched kernel, the installed system came
back on:

```text
7.0.0-22-qcom-x1e
```

## Result

The Wi-Fi rfkill diagnostic after reboot reported:

| Check | Result |
| --- | --- |
| Running kernel | `7.0.0-22-qcom-x1e` |
| Device tree model | `Microsoft Surface Pro 11th Edition (OLED)` |
| Wi-Fi device | WCN785x / FastConnect 7800 present as PCI ID `17cb:1107`. |
| Wi-Fi rfkill | `phy0` soft-blocked `no`, hard-blocked `no`. |
| Bluetooth rfkill | `hci0` soft-blocked `no`, hard-blocked `no`. |
| DT `disable-rfkill` property | Present on the WCN7850 `wifi@0` node. |
| Interface state | `wlP4p1s0` was `UP`, `LOWER_UP`, and reconnected. |
| NetworkManager | Automatically reconnected to the previously saved Wi-Fi network after reboot. |
| Network scan | `nmcli device wifi list --rescan yes` listed nearby networks. |

The raw `nmcli` scan output includes local SSIDs and BSSIDs and should not be
committed without redaction. The important public result is that scan,
association, saved-network reconnect, and traffic all worked on the patched
kernel/DTB path.

## Historical Follow-Up

This confirmed the clean USB-to-installed-system flow for that Wi-Fi bring-up.
The recorded follow-up covered:

- normal reboots without `grub-reboot`,
- suspend/resume,
- package upgrades that regenerate GRUB or initramfs,
- whether `7.0.0-22-qcom-x1e` should become the temporary default boot entry
  until a newer qcom-x1e kernel contains the same rfkill behaviour.

The record also recommended keeping `7.0.0-32-qcom-x1e` installed as a fallback
and avoiding `apt autoremove` until the patched path had survived several
ordinary desktop sessions.
