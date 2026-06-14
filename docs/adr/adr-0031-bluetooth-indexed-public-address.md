---
id: adrs-adr031
title: "ADR031: Bluetooth Indexed Public Address and Cold-Boot Polling"
# prettier-ignore
description: Architecture Decision Record (ADR) correcting the Surface Pro 11 Bluetooth public-address method after field testing showed the btmgmt batch is a no-op on BlueZ 5.85 and the cold-boot timing requires a stop-bluez / poll / apply / restart sequence.
---

## Context

[ADR030](adr-0030-bluetooth-btmgmt-batch-sequence.md) chose a scripted `btmgmt`
batch sequence (`info`, `power off`, `public-addr`, `info`) piped into one
interactive `btmgmt` process, on the assumption that separate
`btmgmt -i hci0 ...` calls were what timed out during cold-boot testing.

Field testing on the installed Surface Pro 11 (BlueZ 5.85) disproved that
assumption:

**Indexed vs batch.** With the controller in its normal unconfigured boot state
(`DOWN RAW`, address `00:00:00:00:5A:AD`, `btmgmt info` reporting `Index list
with 0 items`):

- Piping a command script into interactive `btmgmt` produces **no output and
  exits 0** — it executes nothing. The ADR030 batch is a silent no-op.
- `btmgmt -i hci0 public-addr <mac>` returns `Set Public Address complete`, and
  after a `bluetooth.service` restart the controller comes up `UP RUNNING` as a
  public controller with `Powered: yes`.

**Cold-boot persistence failures.** After multiple rounds of cold-boot testing,
the boot service never succeeded where the manual sequence always did. The
reasons emerged from successive tests:

1. **Restart-bluetooth-before is harmful.** Executing `systemctl restart
   bluetooth.service` before `btmgmt` causes the restarted bluetoothd to claim
   the controller, making `btmgmt public-addr` fail with status `0x14`
   (Permission Denied). The working pattern is: wait for bluetoothd to
   initialize the controller, stop bluetoothd, apply the address to the
   unclaimed controller, then restart bluetoothd.

2. **Blind `ExecStartPre=stop` is too early.** On cold boot, the unit fires via
   udev very early. Stopping `bluetooth.service` before the daemon has had time
   to download firmware and initialize the controller means the controller
   never becomes reachable at all. The poll must run **while bluetoothd is
   running** so the controller gets initialized first. Then bluetoothd is
   stopped to release the controller before `public-addr`.

3. **Blind sleep is unreliable.** Firmware download plus init takes 60-90s on
   cold boot, not a uniform 20. The poll replaces any fixed delay.

4. **Interactive batch hangs in systemd.** Piping commands into `btmgmt` without
   `-i` opens an interactive `[mgmt]>` prompt waiting for stdin. In a systemd
   context this hangs forever, consuming the `timeout` budget and preventing
   fallback to the working indexed path.

4. **The indexed command works even when `info` doesn't.** In the early cold-boot
   state (before bluetoothd initializes), `btmgmt -i hci0 info` returns
   `Invalid Index (0x11)`, but `btmgmt -i hci0 public-addr` still reaches and
   configures the controller.

## Decision

`scripts/sp11-bluetooth-mac.sh` will:

- attempt `btmgmt -i %I public-addr <mac>` first when setting the address, and
  keep the ADR030 interactive batch only as a fallback for BlueZ builds where
  interactive scripting executes.

- add a `--no-batch` flag that skips the interactive batch fallback entirely.
  The generated boot unit uses this flag to avoid the stdin hang in systemd
  context.

- add a `wait_for_hci_ready()` poll that checks for the existence of the
  `/sys/class/bluetooth/hci0` directory (not the `address` pseudo-file, which
  the wcn7850 driver does not expose as a sysfs attribute). The kernel creates
  the hci0 symlink once firmware download completes. A `[ -d ... ]` test is a
  non-blocking stat call — it never enters D-state.

- after the directory appears, the script settles for `--settle-seconds` (120 in
  the generated unit, i.e. 2 minutes) while bluetoothd is running. Field
  testing on cold boot shows the mgmt socket becomes responsive after ~3.5
  minutes of bluetoothd runtime; 120s settle gives margin beyond the observed
  working point. Restarting bluetoothd between retries proved counterproductive
  — it resets init progress. The settle happens once, then bluetoothd is
  stopped and `btmgmt public-addr` is attempted with `--btmgmt-timeout` (120s
  in the unit) to give the mgmt command room to complete during early kernel
  init.

- generate the boot unit **without** `ExecStartPre` or `ExecStopPost`. The
  script itself stops `bluetooth.service` after the controller is confirmed
  reachable, and restarts `bluetooth.service` on every failure path where it
  was stopped.  `ExecStartPost` restarts `bluetooth.service` on success so
  BlueZ binds the corrected address.

The generated unit profile is:

```
ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 1 --btmgmt-timeout 15
ExecStartPost=-/usr/bin/systemctl restart bluetooth.service
```

The `--restart-bluetooth-before` flag and its config key remain available for
manual use but are no longer enabled by the generated service.

## Consequences

The helper now uses the verified working indexed command on the first attempt,
skips the no-op/hanging batch in systemd context. Readiness is determined by
polling for the `/sys/class/bluetooth/hci0` directory entry — a non-blocking
stat call that cannot hang in D-state.

Once enumerated, the script settles for 2 minutes while bluetoothd runs
(honoring cold-boot timing verified at 3.5 min uptime), then stops
`bluetooth.service` and applies the address with a 120s `btmgmt` timeout.
Retries do not restart bluetoothd (restarting proved counterproductive — it
resets init progress). `ExecStartPost` restarts bluetoothd on success; on
failure, bluetoothd is restarted in-script so the controller is never left
orphaned.

`wait_for_hci_ready` returns non-zero on timeout so callers can distinguish the
initialized / not-initialized case. The script aborts cleanly when the
controller never initializes rather than striking a half-initialized controller
with `public-addr`. On the failure path, the script restarts bluetoothd itself
(not via `ExecStopPost`, which fires on success too and would double-restart),
so a failed address application never leaves Bluetooth dead until the next reboot.

This supersedes the ADR030 assumption that the batch sequence is the working
mechanism. ADR030 is retained as history; the batch remains in the code only as
a portability fallback for non-systemd contexts or different BlueZ builds.

Cold-boot persistence remains to be validated on the device. The mechanism is
proven component-by-component: poll → stop → btmgmt → restart succeeds from
terminal; the polling function is the new variable for the automatic boot path.
