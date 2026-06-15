---
id: how-to-compile-sp11-bt-set-addr
title: "Compile the Raw mgmt-Socket Bluetooth Helper"
# prettier-ignore
description: How-to guide for building the Surface Pro 11 raw mgmt-socket Bluetooth public-address helper on-device.
---

# How To: Compile the Raw mgmt-Socket Bluetooth Helper

Build `tools/sp11-bt-set-addr.c` directly on the Surface Pro 11 when the
prebuilt binary is not available or when the source has been modified.

## Prerequisites

- Installed Ubuntu with a working C compiler. The Surface Pro 11 concept image
  includes `gcc` by default. If missing:

  ```bash
  sudo apt update && sudo apt install -y gcc
  ```

- The helper source at `tools/sp11-bt-set-addr.c` in the current checkout root.
  This can be either a git checkout or the live USB `$SP11DATA/support`
  directory.

## Procedure

1. Enter the checkout root.

   ```bash
   # Git checkout:
   cd /path/to/linux-surface-pro-11-oe

   # Or live USB support root:
   cd "$SP11DATA/support"
   ```

2. Build the helper.

   ```bash
   gcc -Wall -Wextra -O2 \
     -o tools/sp11-bt-set-addr \
     tools/sp11-bt-set-addr.c
   ```

   The helper uses only POSIX and Linux kernel headers. No `-lbluetooth` or
   BlueZ development packages are needed. All Bluetooth mgmt constants and
   structures are defined inline, keyed to this kernel's header values.

3. Confirm the binary exists and is executable.

   ```bash
   file tools/sp11-bt-set-addr
   # Should report: ELF 64-bit LSB executable, ARM aarch64
   ```

4. Install alongside the systemd orchestration.

   ```bash
   sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
   ```

   The installer copies both `sp11-bt-set-addr` and `sp11-bluetooth-mac` into
   `/usr/local/sbin/`, writes the systemd template unit, and refreshes the udev
   trigger. The unit uses `Wants=bluetooth.service`,
   `Before=bluetooth.service`, and `Type=oneshot`; it does not use
   `RemainAfterExit` or `ExecStartPost`.

5. Test manually (cold-boot path only).

   The helper sends only `MGMT_OP_SET_PUBLIC_ADDRESS` (0x0039) — no power-off,
   no rfkill operation, and no other mgmt command. It relies on the controller
   being in its initial DOWN RAW state before bluetoothd claims it. On a warm
   system, manual testing needs bluetoothd stopped:

   ```bash
   sudo systemctl stop bluetooth.service
   sudo /usr/local/sbin/sp11-bt-set-addr 0 02:11:22:33:44:55
   sudo systemctl start bluetooth.service
   bluetoothctl show | head -3
   ```

   Replace the example MAC with the real Bluetooth address from Windows.
   On a warm boot the helper may still fail with `short write` — the controller
   is often already powered at this point. Cold-boot validation (step 6) is the
   definitive test.

6. Cold-boot validation.

   ```bash
   sudo reboot
   # After login:
   bluetoothctl show | head -3
   journalctl -u sp11-bluetooth-mac@hci0.service --no-pager -n 10
   ```

   The journal should show `set-public-address  status 0x00 (success)`
   followed by `Success: public address set`.

## Troubleshooting

If the compile fails with `gcc: command not found`, install the compiler:

```bash
sudo apt update && sudo apt install -y gcc
```

If the helper exits with `hci0 not found after 120s`, the Bluetooth UART has
not enumerated. Check:

```bash
ls /sys/class/bluetooth/
dmesg | grep -iE 'hci0|wcn7850|bluetooth' | tail -20
```

If `set-public-address` reports `status 0x0d` (invalid params), confirm the
MAC address uses colon-separated hex octets like `02:11:22:33:44:55`, not
dash-separated or unseparated.

If udev does not trigger the service on the next cold boot, reload the rules:

```bash
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=bluetooth
```

## Related Documents

- [ADR032: Raw mgmt-Socket Bluetooth Cold-Boot Solution](../adr/adr-0032-raw-mgmt-socket-bluetooth-cold-boot.md)
- [ADR031: Bluetooth Indexed Public Address and Cold-Boot Polling](../adr/adr-0031-bluetooth-indexed-public-address.md)
- [Bring Up Bluetooth](how-to-bring-up-bluetooth.md)
