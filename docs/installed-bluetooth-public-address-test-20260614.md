# Surface Pro 11 Bluetooth Public Address Test - 2026-06-14

## Context

After Wi-Fi was working on the patched `7.0.0-22-qcom-x1e` kernel, Bluetooth
firmware loaded but BlueZ did not expose a usable controller.

Before setting the public address, diagnostics showed:

| Check | Result |
| --- | --- |
| Kernel | `7.0.0-22-qcom-x1e` |
| Device tree model | `Microsoft Surface Pro 11th Edition (OLED)` |
| Bluetooth rfkill | Soft-blocked `no`, hard-blocked `no`. |
| HCI transport | `hci0` present on UART. |
| Firmware | QCA WCN7850 firmware and NVM files loaded. |
| Controller address | Placeholder-like `00:00:00:00:*` address. |
| BlueZ | `No default controller available`. |
| `btmgmt` | `Index list with 0 items`. |

The Windows Bluetooth PAN adapter reported a permanent address distinct from
the Wi-Fi adapter address. The exact address is a hardware identifier and is not
recorded here.

## Test

The following commands record the first successful local test. They are
historical, not the current recommended order; use the how-to for the current
manual-validate-first flow.

The Windows Bluetooth address was written to the local config with:

```bash
BT_MAC="<windows-bluetooth-mac>"

sudo ./scripts/sp11-bluetooth-mac.sh \
  --write-config "$BT_MAC" \
  --attempts 8 \
  --settle-seconds 8
sudo ./scripts/sp11-bluetooth-mac.sh --install-systemd
sudo ./scripts/sp11-bluetooth-mac.sh --apply
```

This records the order used during the first successful local test. The
recommended user flow now validates the manual apply before installing the
automatic systemd/udev hook.

This also used an earlier helper revision than the timeout-aware helper now
tracked in this repository. Treat this test as validation of the
Windows-sourced public-address approach plus `bluetooth.service` restart, not
as validation of the current helper implementation.

`btmgmt public-addr` accepted the address, but `btmgmt power on` reported an
invalid-index status. Immediately after the apply attempt, the diagnostic still
reported no BlueZ default controller.

Restarting BlueZ completed the controller handoff:

```bash
sudo systemctl restart bluetooth.service
bluetoothctl show
```

## Result

`bluetoothctl show` reported a public controller with the Windows-sourced
Bluetooth address. The controller was powered on and exposed both central and
peripheral roles.

The visible controller state included:

- manufacturer `0x001d`,
- powered `yes`,
- roles `central` and `peripheral`,
- multiple standard BlueZ service UUIDs,
- advertising features including tx-power, appearance, local-name, and
  secondary channel support.

Redacted visual evidence of the Bluetooth settings pairing flow is stored at
[assets/bluetooth/2026-06-14-sp11-bluetooth-search-connect-redacted.png](../assets/bluetooth/2026-06-14-sp11-bluetooth-search-connect-redacted.png).

## Interpretation

The Surface Pro 11 Bluetooth blocker is not rfkill or firmware loading in this
state. It is the missing or invalid public Bluetooth address.

On the tested system, the successful sequence was:

1. source the real Bluetooth MAC address from Windows,
2. apply it with `btmgmt public-addr`,
3. restart `bluetooth.service`,
4. validate with `bluetoothctl show`.

The helper should treat `public-addr` acceptance as meaningful even when the
immediate `power on` operation reports an invalid-index status. The manual path
should restart `bluetooth.service` before deciding whether the attempt worked.
Future users should validate the manual path before relying on the installed
udev/systemd hook.

## Follow-Up

Validate:

- reboot behavior with the installed udev-triggered service,
- pairing a simple Bluetooth peripheral,
- suspend/resume behavior,
- whether BlueZ remains stable after repeated Wi-Fi/Bluetooth toggles.

Do not publish raw Bluetooth MAC addresses in docs, logs, screenshots, or issue
comments.

## Reboot Test

The first reboot after installing the original helper did not preserve the
working BlueZ controller state. After reboot:

- `uname -r` still reported `7.0.0-22-qcom-x1e`,
- `bluetoothctl show` reported `No default controller available`,
- the installed `/usr/local/sbin/sp11-bluetooth-mac` was an older helper that
  did not support `--status`,
- `sp11-bluetooth-mac@hci0.service` remained stuck in `activating` state,
- the stuck child process was `btmgmt -i hci0 power off`,
- `hciconfig` again showed the placeholder-like `00:00:00:00:*` address.

This confirms that the boot-time hook must bound `btmgmt` calls and that the
installed system needs the updated helper before reboot persistence can be
judged. It does not invalidate the manual public-address flow, which previously
made `bluetoothctl show` report a powered public controller after restarting
`bluetooth.service`.

The next validation step is to rebuild the USB payload with the current helper,
install the updated support scripts onto the installed Ubuntu system, and repeat
the manual and reboot tests.

## Updated Helper Manual Retest

After rebuilding the USB payload and reinstalling support helpers from
`/mnt/sp11data/support`, running the helper from the USB copy regenerated the
systemd unit and created:

```text
/etc/systemd/system/bluetooth.service.wants/sp11-bluetooth-mac@hci0.service
```

The manual apply path then reported:

```text
hci0 Set Public Address complete
Configured Bluetooth public address for hci0.
```

`bluetoothctl show` again reported a public controller with the
Windows-sourced Bluetooth address. The first captured output still showed
`Powered: no` and `PowerState: off-enabling`, so the next check is to confirm
that the controller settles to `Powered: yes` before repeating the reboot
persistence test.

A follow-up `bluetoothctl show`, `bluetoothctl power on`, `sleep 5`, and
`bluetoothctl show` sequence confirmed that the public controller settled to:

```text
Powered: yes
PowerState: on
Discoverable: yes
Pairable: yes
```

That confirms the updated manual path can restore a usable BlueZ controller.
Reboot persistence remains the next validation gate.

## Timeout-Aware Helper Pre-Ordering Reboot Retest

After rebooting with the timeout-aware helper installed but before changing the
unit ordering, the system still booted the patched `7.0.0-22-qcom-x1e` kernel,
but BlueZ again reported:

```text
No default controller available
```

The helper no longer hung indefinitely. It failed cleanly after bounded
`btmgmt` attempts, and `sp11-bluetooth-mac --status` still redacted the
configured address. The service journal showed the generated helper running
before `bluetooth.service`; BlueZ then initialized its management interface only
after the helper had already failed.

This narrows the reboot blocker to unit ordering, not to the public-address
method. The automatic hook should run after `bluetooth.service` is available,
then restart Bluetooth after applying the address.

The repository helper has been updated for that ordering. A fresh installed
helper plus reboot is still required to validate persistence on hardware.

## After-Ordering Cold-Boot Retest

After reinstalling the corrected helper and doing a full shutdown followed by
power-on, the system still booted the patched `7.0.0-22-qcom-x1e` kernel, but
BlueZ again reported:

```text
No default controller available
```

The service was no longer installed through `bluetooth.service.wants`; it was
loaded as a static udev-triggered unit. It failed cleanly after five attempts:

```text
btmgmt command timed out after 8s.
Attempt 5 failed to set the Bluetooth public address.
Failed to configure Bluetooth public address for hci0.
Current hci0 address: 00:00:00:xx:xx:xx
```

This points to two remaining cold-boot issues:

- the installed local config still supplied the older five-attempt retry
  budget,
- `After=bluetooth.service` alone did not reproduce the manual recovery path,
  which had restarted `bluetooth.service` before applying the public address.

The next helper revision should make the generated boot unit independent from
older local retry values and should restart `bluetooth.service` before the
boot-time public-address apply.

## Cold-Boot Profile Hot-Patch Retest

The hot-patched unit then ran the stronger 12-attempt profile from the command
line after boot. It still failed:

```text
btmgmt command timed out after 12s.
Attempt 12 failed to set the Bluetooth public address.
Failed to configure Bluetooth public address for hci0.
Current hci0 address: 00:00:00:xx:xx:xx
```

Diagnostics continued to show:

```text
btmgmt: Index list with 0 items
hciconfig: hci0 DOWN RAW
bluetoothctl: No default controller available
```

The kernel log still showed successful WCN7850 Bluetooth firmware setup:

```text
Bluetooth: hci0: QCA Downloading qca/hmtbtfw20.tlv
Bluetooth: hci0: QCA Downloading qca/hmtnv20.bin
Bluetooth: hci0: QCA setup on UART is completed
```

This makes retry length and service ordering insufficient by themselves. The
next test should follow the community Surface Pro 11 workaround more closely by
piping a short command script into `btmgmt`, then running a second `public-addr`
batch.
