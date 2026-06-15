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
Bluetooth public address from Windows with the raw mgmt-socket C helper
(`tools/sp11-bt-set-addr.c`).

The helper opens an `AF_BLUETOOTH` / `SOCK_RAW` / `HCI_CHANNEL_CONTROL` socket
directly and issues `MGMT_OP_SET_PUBLIC_ADDRESS` (0x0039). It runs **before**
`bluetooth.service` starts, while the controller is still in its DOWN RAW
state. No power-cycle, no rfkill toggle, no userspace management CLI, no
D-state hangs (see ADR032).

## Prerequisites

- Installed Ubuntu booted on the patched qcom-x1e kernel.
- `bluez` installed.
- A C compiler (`gcc` is present by default on the concept image).
- A current checkout root for these support files. This can be either a git
  checkout or the live USB `$SP11DATA/support` directory.
- Access to Windows or a Windows diagnostic report from the same device.
- The real Bluetooth MAC address for the device.

Do not use the Wi-Fi MAC address unless Windows confirms it is also the
Bluetooth radio address. Do not invent or randomize an address.

The helper stores the configured address in `/etc/default/sp11-bluetooth-mac`
with root-only permissions.

## Procedure

1. Enter the checkout root.

Use either a git checkout:

```bash
cd /path/to/linux-surface-pro-11-oe
```

Or the live USB support root:

```bash
cd "$SP11DATA/support"
```

2. Confirm the Linux-side failure mode.

```bash
sudo ./scripts/troubleshoot-sp11-bluetooth.sh --dmesg-lines 220 \
  | tee ~/sp11-bluetooth-before.txt
```

`sp11-bluetooth-mac.sh --install-systemd` does not install this diagnostic
script; run it from the checkout or live USB support tree.

Look for:

- `hci0` present,
- Bluetooth rfkill soft-blocked `no` and hard-blocked `no`,
- QCA WCN7850 firmware loading,
- `No default controller available`,
- a suspicious address such as `00:00:00:00:*`.

3. Boot Windows and find the Bluetooth address.

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

4. Compile the raw mgmt-socket helper on-device.

```bash
gcc -Wall -Wextra -O2 \
  -o tools/sp11-bt-set-addr \
  tools/sp11-bt-set-addr.c
```

See [Compile the Raw mgmt-Socket Bluetooth Helper](how-to-compile-sp11-bt-set-addr.md)
for details and troubleshooting.

5. Write the Bluetooth MAC config.

Replace the placeholder with the real Bluetooth MAC:

```bash
BT_MAC="<windows-bluetooth-mac>"

sudo ./scripts/sp11-bluetooth-mac.sh --write-config "$BT_MAC"
```

6. Install the automatic udev/systemd cold-boot hook.

```bash
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
```

The installer copies `sp11-bt-set-addr` and `sp11-bluetooth-mac` into
`/usr/local/sbin/`, writes the systemd template unit, and deploys the udev
trigger. The generated unit uses `Wants=bluetooth.service` (pulls bluetoothd
into the boot transaction) and `Before=bluetooth.service` (sets the public
address while the controller is in its DOWN RAW state). The service is
`Type=oneshot` with no `RemainAfterExit` and no `ExecStartPost`; bluetoothd
proceeds immediately after `sp11-bt-set-addr` exits and downloads firmware
against the already-corrected address.

7. Cold-boot and validate.

```bash
sudo reboot
```

After login:

```bash
bluetoothctl show | head -5
journalctl -u sp11-bluetooth-mac@hci0.service --no-pager -n 10
```

The journal should show `set-public-address  status 0x00 (success)` followed
by `Success: public address set` at approximately T+1s from boot.
`bluetoothctl show` should report a powered controller with the real public
address.

## Expected Output

After a successful cold boot:

- `bluetoothctl list` shows a controller,
- `bluetoothctl show` no longer says `No default controller available`,
- The journal confirms `set-public-address  status 0x00 (success)` and
  `Success: public address set`,
- The diagnostic no longer flags the known invalid `00:00:00:00:*` address.

## Validation

```bash
bluetoothctl list
bluetoothctl show
journalctl -b -u 'sp11-bluetooth-mac@hci0.service' --no-pager
```

These checks prove the controller is visible to BlueZ and that the address was
set on this boot. They do not prove peripherals pair successfully, audio
profiles work, or suspend/resume behavior is correct.

## Privacy and Safety

Bluetooth MAC addresses are hardware identifiers. Do not commit raw diagnostic
logs, Windows service reports, registry output, or unredacted command output.

The diagnostic helper redacts MAC-like values by default. Use
`--show-addresses` only for local debugging. The MAC helper's status output is
also redacted by default.

## Troubleshooting

### Helper short write on first attempt

The journal may show `short write 0/12` on the first mgmt attempt. This is
normal — the mgmt channel is not yet ready while firmware initialises. The
helper retries every second for up to 60 attempts. A single `short write`
followed by `set-public-address  status 0x00 (success)` on the next attempt is
expected.

### set-public-address status 0x0d (invalid params)

Confirm the MAC address uses colon-separated hex octets (`84:B1:E2:54:EC:2B`),
not dash-separated or unseparated.

### hci0 not found after 120s

The Bluetooth UART has not enumerated. Check:

```bash
ls /sys/class/bluetooth/
dmesg | grep -iE 'hci0|wcn7850|bluetooth' | tail -20
```

### No default controller available (persistent)

Check the service journal:

```bash
journalctl -b -u 'sp11-bluetooth-mac@hci0.service' --no-pager
```

If the log shows repeated `short write` failures without a success line, the
mgmt channel may not be ready or may be held by stale tooling from an older
test. The current cold-boot path does not use `btmgmt`, but older manual tests
may have left one running:

```bash
sudo pkill -9 btmgmt || true
```

If the controller shows the correct address in the journal but bluetoothd still
reports no controller after a cold boot, reinstall the systemd unit and reboot:

```bash
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo systemctl reset-failed 'sp11-bluetooth-mac@hci0.service'
sudo reboot
```

### Service timed out (start-post operation)

If the journal shows `start-post operation timed out`, the installed unit may
have a stale `RemainAfterExit=yes` or `ExecStartPost`. Reinstall:

```bash
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo systemctl daemon-reload
sudo systemctl reset-failed 'sp11-bluetooth-mac@hci0.service'
```

The current unit uses `Type=oneshot` without `RemainAfterExit` or
`ExecStartPost`. It exits cleanly after setting the address, and bluetoothd
proceeds via the `Before=` ordering.

### Compile failure

```bash
gcc -Wall -Wextra -O2 \
  -o tools/sp11-bt-set-addr \
  tools/sp11-bt-set-addr.c
```

The helper uses only POSIX and Linux kernel headers. No `-lbluetooth` or BlueZ
development packages are needed. If `gcc` is missing:

```bash
sudo apt update && sudo apt install -y gcc
```

### Stale wants dependency from older install

If a previous install created
`/etc/systemd/system/bluetooth.service.wants/sp11-bluetooth-mac@hci0.service`,
rerun the installer. The current installer removes that older dependency link
and relies on the udev trigger instead.

## Related Documents

- [ADR032: Raw mgmt-Socket Bluetooth Cold-Boot Solution](../adr/adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md)
- [ADR031: Bluetooth Indexed Public Address and Cold-Boot Polling](../adr/adr-0031-bluetooth-indexed-public-address.md)
- [Compile the Raw mgmt-Socket Bluetooth Helper](how-to-compile-sp11-bt-set-addr.md)
