---
id: how-to-bring-up-bluetooth
title: "Bring Up Bluetooth"
# prettier-ignore
description: How-to guide for validating and configuring Surface Pro 11 Bluetooth public-address handling on Ubuntu.
---

# How To: Bring Up Bluetooth

Use this procedure when Wi-Fi works on the patched qcom-x1e kernel but
Bluetooth appears as `hci0` without a usable BlueZ controller.

## Purpose

On the tested Surface Pro 11, the Bluetooth UART transport and WCN7850 firmware
load, but Linux reports a placeholder-like controller address:

```text
00:00:00:00:5A:AD
```

BlueZ then reports no default controller. The next gate is to set the real
Bluetooth public address from Windows with `sp11-bluetooth-mac`.

## Prerequisites

- Installed Ubuntu booted on the patched qcom-x1e kernel.
- `bluez` installed, including `btmgmt`.
- `timeout` from `coreutils`, normally present on Ubuntu.
- Surface Pro 11 support helpers installed under `/usr/local/sbin`.
- Access to Windows or a Windows diagnostic report from the same device.
- The real Bluetooth MAC address for the device.

Do not use the Wi-Fi MAC address unless Windows confirms it is also the
Bluetooth radio address. Do not invent or randomize an address.

The helper stores the configured address in `/etc/default/sp11-bluetooth-mac`
with root-only permissions.

## Procedure

1. Confirm the Linux-side failure mode.

```bash
sudo /usr/local/sbin/troubleshoot-sp11-bluetooth --dmesg-lines 220 \
  | tee ~/sp11-bluetooth-before.txt
```

Look for:

- `hci0` present,
- Bluetooth rfkill soft-blocked `no` and hard-blocked `no`,
- QCA WCN7850 firmware loading,
- `No default controller available`,
- a suspicious address such as `00:00:00:00:*`.

2. Boot Windows and find the Bluetooth address.

Copy `tools/collect-sp11-windows-bluetooth-address.ps1` to the Windows install
or run it from a checked-out copy of this repository. Then run PowerShell as
Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\collect-sp11-windows-bluetooth-address.ps1
```

The script prints BTHPORT registry candidates and matching Bluetooth,
Qualcomm, FastConnect, and WCN adapters. Use the Bluetooth adapter
`PermanentAddress` when present. If the script returns more than one candidate,
keep the output private and compare it with Bluetooth adapter details in Device
Manager or the diagnostic report. Do not publish the raw MAC address.

3. Reboot Ubuntu and write the Bluetooth MAC config.

Replace the placeholder with the real Bluetooth MAC:

```bash
BT_MAC="<windows-bluetooth-mac>"

sudo /usr/local/sbin/sp11-bluetooth-mac \
  --write-config "$BT_MAC" \
  --attempts 8 \
  --settle-seconds 8 \
  --btmgmt-timeout 8
```

4. Try a manual apply before enabling the automatic hook.

```bash
sudo systemctl restart bluetooth.service
sudo /usr/local/sbin/sp11-bluetooth-mac --apply
sudo systemctl restart bluetooth.service
```

On the first successful local test, `btmgmt public-addr` accepted the address
while the immediate power-on step reported an invalid-index status. Restarting
`bluetooth.service` was still enough for BlueZ to bind the controller.

5. Validate the controller.

```bash
sudo /usr/local/sbin/sp11-bluetooth-mac --status
bluetoothctl list
bluetoothctl show
sudo /usr/local/sbin/troubleshoot-sp11-bluetooth --dmesg-lines 220 \
  | tee ~/sp11-bluetooth-after.txt
```

Passing validation means BlueZ lists a controller and `bluetoothctl show`
returns controller details. It does not prove pairing, audio profiles,
reboot persistence, or suspend/resume behavior yet.

`sp11-bluetooth-mac --status` redacts hardware addresses by default. Use
`--show-addresses` only for local debugging when you will not paste the output
into a public issue or document.

6. Install the automatic udev/systemd hook after manual validation succeeds.

```bash
sudo /usr/local/sbin/sp11-bluetooth-mac --install-systemd
sudo udevadm trigger --subsystem-match=bluetooth
```

The install step installs a udev trigger for `hci*` add events. The generated
service pulls in `bluetooth.service` via `After=` and `Wants=`. When the
controller appears via udev, the unit:

1. Polls the sysfs address file (`/sys/class/bluetooth/hci0/address`) every 5s
   **while bluetoothd is running** until the kernel enumerates the controller.
   This is a non-blocking file read — it never hangs in D-state, unlike
   `btmgmt info` which enters uninterruptible kernel sleep during firmware
   download.
2. Stops `bluetooth.service` so bluetoothd releases the controller.
3. Sets the public address with `btmgmt -i hci0 public-addr <mac>`.
4. Restarts `bluetooth.service` so BlueZ binds the corrected address.

Reboot once and rerun the validation commands.

The boot-time unit uses `--no-batch --attempts 3 --settle-seconds 1
--btmgmt-timeout 15`. `--no-batch` skips the interactive `btmgmt` (without
`-i`) batch fallback, which hangs in systemd context, and engages the sysfs
readiness poll. When `--no-batch` is set, the helper polls
`/sys/class/bluetooth/hci0/address` for controller enumeration **while
bluetoothd is running**, then stops `bluetooth.service` before issuing
`public-addr`.

The boot service stops `bluetooth.service` only after the controller reports
reachable. Restarting `bluetooth.service` instead would cause bluetoothd to
claim the controller, making `btmgmt public-addr` fail with status `0x14`
(Permission Denied). After the address is set, `ExecStartPost` restarts
`bluetooth.service` so BlueZ binds the corrected public address.

## Expected Output

After a successful apply:

- `sp11-bluetooth-mac --status` reports the configured address,
- `bluetoothctl list` shows a controller,
- `bluetoothctl show` no longer says `No default controller available`,
- the diagnostic no longer flags the known invalid `00:00:00:00:*` address.

## Validation

Use:

```bash
rfkill list
btmgmt info
bluetoothctl list
bluetoothctl show
journalctl -b -u bluetooth.service -u 'sp11-bluetooth-mac@*.service' --no-pager
```

These checks prove the controller is visible to BlueZ and that the address hook
ran. They do not prove peripherals pair successfully.

## Privacy and Safety

Bluetooth MAC addresses are hardware identifiers. Do not commit raw diagnostic
logs, Windows service reports, registry output, or unredacted command output.

The diagnostic helper redacts MAC-like values by default. Use
`--show-addresses` only for local debugging. The MAC helper's status output is
also redacted by default.

## Troubleshooting

If `btmgmt` still reports `Index list with 0 items`, confirm that `hci0` exists
with:

```bash
hciconfig -a
dmesg -T | grep -iE 'bluetooth|hci0|qca|wcn|firmware' | tail -n 120
```

If `sp11-bluetooth-mac --apply` fails, retry with more delay:

```bash
sudo /usr/local/sbin/sp11-bluetooth-mac \
  --apply \
  --attempts 12 \
  --settle-seconds 12 \
  --btmgmt-timeout 12
```

If the automatic service is stuck from an older helper, stop it before retrying:

```bash
sudo systemctl stop 'sp11-bluetooth-mac@hci0.service'
sudo pkill -9 -x btmgmt || true
sudo systemctl restart bluetooth.service
```

If a previous install created
`/etc/systemd/system/bluetooth.service.wants/sp11-bluetooth-mac@hci0.service`,
rerun `sudo /usr/local/sbin/sp11-bluetooth-mac --install-systemd`. The current
installer removes that older dependency link and relies on the udev trigger
instead.

If the address applies but BlueZ still has no default controller, collect the
before/after diagnostics and do not enable the automatic hook yet.

If `sp11-bluetooth-mac --apply` says the address was accepted but the
controller still does not appear, restart Bluetooth once:

```bash
sudo systemctl restart bluetooth.service
bluetoothctl show
```

To remove the automatic hook:

```bash
sudo /usr/local/sbin/sp11-bluetooth-mac --uninstall-systemd
```

This leaves `/etc/default/sp11-bluetooth-mac` in place so you can reinstall the
hook without retyping the address. Remove that file manually if you want to
discard the local address config.

## Related Documents

- [ADR027: Bluetooth Public Address](../adr/adr-0027-bluetooth-public-address.md)
- [ADR029: Bluetooth Cold-Boot Service Retry Profile](../adr/adr-0029-bluetooth-cold-boot-service-retry-profile.md)
- [ADR030: Bluetooth btmgmt Batch Sequence](../adr/adr-0030-bluetooth-btmgmt-batch-sequence.md)
- [ADR024: Bluetooth, Audio, and Board-Data Bring-Up Gates](../adr/adr-0024-bluetooth-audio-and-board-data-gates.md)
- [Surface Pro 11 Bluetooth public address test](../installed-bluetooth-public-address-test-20260614.md)
- [Generate a Service Report](how-to-generate-service-report.md)
