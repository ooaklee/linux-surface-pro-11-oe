---
id: adrs-adr032
title: "ADR032: Raw mgmt-Socket Bluetooth Cold-Boot Solution"
# prettier-ignore
description: Architecture Decision Record (ADR) replacing btmgmt-based Bluetooth public-address bring-up with a raw mgmt-socket C helper that avoids D-state hangs entirely and runs before bluetoothd.
---

## Context

[ADR031](adr-0031-bluetooth-indexed-public-address.md) concluded that
`btmgmt` hangs in uninterruptible D-state when invoked from a systemd unit on
cold boot, regardless of settle duration, retry profile, or bluetoothd
lifecycle. The root cause was unknown, and the only reliable path was a
manual terminal `sudo` invocation after every cold boot.

A collaborative investigation (2026-06-15) tested several alternatives:

1. **Fixed-opcode raw mgmt socket** — opening `socket(AF_BLUETOOTH, SOCK_RAW,
   BTPROTO_HCI)`, binding `HCI_CHANNEL_CONTROL`, and sending
   `MGMT_OP_SET_PUBLIC_ADDRESS` (0x0039) directly. This bypasses btmgmt's
   terminal I/O, readline, and stdin polling entirely.

2. **Power-off-before-address** — sending `MGMT_OP_SET_POWERED` (0x0005) with
   power-off before the public-address command, then polling
   `MGMT_OP_READ_INFO` until the controller actually transitions. This worked
   from a terminal but failed from systemd because `write()` to the mgmt
   socket returned 0 bytes after `systemctl stop bluetooth.service` left the
   channel stale.

3. **Pre-bluetoothd timing** — running the helper `Before=bluetooth.service`
   via a systemd unit, before bluetoothd has claimed the controller. At this
   point the controller is in its initial DOWN RAW state and accepts
   `MGMT_OP_SET_PUBLIC_ADDRESS` directly — no power-off sequence needed.

Approach 3 succeeded on two consecutive cold boots and became the chosen
path.

## Key Findings

**The mgmt socket does not reproduce btmgmt's D-state hang.** A raw
`AF_BLUETOOTH` socket with `SO_RCVTIMEO` always returns bounded results.
btmgmt's hang is caused by its terminal I/O layer, not by the kernel mgmt
socket.

**`MGMT_OP_SET_PUBLIC_ADDRESS` is 0x0039, not 0x0052.** The initial
implementations used 0x0052 from an incorrect assumption; the Ubuntu
7.0.0-22-qcom-x1e kernel headers define it as 0x0039. 0x0052 is
`MGMT_OP_ADD_ADV_PATTERNS_MONITOR`.

**The controller accepts `public-addr` in DOWN RAW state.** When the service
runs before bluetoothd starts, the WCN7850 controller has not yet been
powered or claimed by the management daemon. The raw mgmt socket can set the
public address directly — no power-off, no rfkill unblock, no settle period.

**`Before=bluetooth.service` is the correct ordering.** The address is set
before bluetoothd starts. bluetoothd then downloads firmware, binds the
already-correct address, and the controller comes up as a public device.

**Reopening the socket on write failure is necessary.** On cold boot, the
first mgmt `write()` frequently returns 0 bytes because the kernel's HCI
mgmt channel is still initialising. Reopening the socket and retrying
(up to 60 attempts at 1s intervals) handles this transient condition.

## Decision

Replace the btmgmt-based `ExecStart` in `sp11-bluetooth-mac@.service` with a
raw mgmt-socket C helper (`tools/sp11-bt-set-addr.c`).

The helper:

- Opens `socket(AF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI)` with a 5-second
  `SO_RCVTIMEO`.
- Polls `/sys/class/bluetooth/hciN` for controller enumeration (120s max).
- Reopens the socket and retries on any write/socket failure (up to 60
  attempts, 1s intervals).
- Sends `MGMT_OP_SET_PUBLIC_ADDRESS` (0x0039) with the 6-byte MAC address
  from `/etc/default/sp11-bluetooth-mac`.
- Validates the command status response (targeting event index and opcode).
- Exits 0 on `MGMT_STATUS_SUCCESS`, non-zero on any other outcome.

The generated systemd unit:

```
[Unit]
Wants=bluetooth.service
Before=bluetooth.service

[Service]
Type=oneshot
TimeoutStartSec=5min
ExecStart=/usr/local/sbin/sp11-bt-set-addr 0 ${SP11_BLUETOOTH_MAC}
```

The oneshot exits immediately after setting the address. Without
`RemainAfterExit`, systemd considers the unit complete as soon as ExecStart
returns (T+1s). bluetoothd then proceeds via the `Before=` ordering.
`Wants=` ensures bluetoothd is pulled into the boot transaction even if
nothing else requests it.

The pre-bluetoothd timing makes the helper independent of power-off
sequencing, rfkill racing, and firmware-download settle periods. The udev
trigger (`ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host"`)
remains unchanged.

No part of the helper uses btmgmt, bluez libraries, or interactive terminal
I/O. All Bluetooth mgmt constants and structures are defined inline, matched
to the installed kernel's `mgmt.h` values.

## Consequences

Bluetooth public-address bring-up works on cold boot without manual
intervention. The D-state hang documented in ADR031 is fully bypassed.

The generated service no longer uses `ExecStartPre` for rfkill unblock or
settle-sleep. Controller readiness is handled by the helper's internal
retry-and-reopen loop.

The helper stores no state between boots. On each invocation it opens a
fresh mgmt socket, sends exactly one command, and exits. The 60-attempt
retry budget covers transient failures during kernel initialisation.

Cold boot failure is bounded: the service completes in ≤1 minute (60
retries × 1s) or exits non-zero with a clear diagnostic.

The existing bash helper (`scripts/sp11-bluetooth-mac.sh`) remains available
for `--write-config`, `--install-systemd`, `--status`, and manual
`--apply` fallback. The manual terminal path also continues to work if the
service is disabled, because the C helper is just a standalone binary.

## Validation

Two consecutive cold boots on 2026-06-15 confirmed:

- `sp11-bluetooth-mac@hci0.service` succeeds at T+1s.
- Journal shows `set-public-address status 0x00 (success)`.
- `bluetoothctl show` reports the corrected public address.
- Bluetooth service is `active (running)`.

Failures on the first retry attempt (`short write 0/12`) are expected and
handled by the retry loop. The second attempt consistently succeeds.

## Related Documents

- [ADR031: Bluetooth Indexed Public Address and Cold-Boot Polling](adr-0031-bluetooth-indexed-public-address.md)
- [ADR028: Bounded Bluetooth Management Hook](adr-0028-bounded-bluetooth-management-hook.md)
- [ADR027: Bluetooth Public Address](adr-0027-bluetooth-public-address.md)
- [How To: Compile the Raw mgmt-Socket Bluetooth Helper](../how-to/how-to-compile-sp11-bt-set-addr.md)
- [How To: Bring Up Bluetooth](../how-to/how-to-bring-up-bluetooth.md)
