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

**Systemd context: unsolved.** After extensive cold-boot testing, the same
`btmgmt` command reliably succeeds from a terminal `sudo` invocation at T+1.7
minutes but consistently hangs (D-state) from a systemd unit, regardless of:

- How long bluetoothd was running (tested 60s, 120s, 300s)
- The `btmgmt` timeout (15s, 60s, 120s)
- Using `kill $(pidof bluetoothd)` instead of `systemctl stop` (direct `kill`
  hangs too)
- Settle duration (works at 10s manually, fails at 300s in unit)

The root cause is unknown. In all failed attempts, `btmgmt` enters
uninterruptible kernel sleep (D-state) that the `timeout` wrapper cannot kill.
The HCI management socket path appears to differ fundamentally when invoked by
a systemd unit vs. a user terminal session.

**Known working workaround:** On cold boot, a user runs:

    sudo bash /usr/local/sbin/sp11-bluetooth-mac --apply --hci hci0 --no-batch --attempts 3 --settle-seconds 10 --btmgmt-timeout 10

This succeeds consistently. The automatic udev/service path remains unsolved.

Historical failures:

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
  testing on cold boot shows the mgmt socket becomes responsive at T+1.7 min;
  120s settle gives margin. The script then kills bluetoothd directly
  (`SIGTERM` via `kill`) rather than `systemctl stop`. Empirical testing
  on the Surface Pro 11 shows that `systemctl stop` from within a systemd
  unit leaves the kernel HCI management channel in a stale state where
  `btmgmt public-addr` enters D-state — regardless of how long bluetoothd
  had been running. A direct `kill` from a child process matches the
  terminal `sudo` execution path that succeeds every time.

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

The automatic systemd service remains unsolved: `btmgmt` hangs in D-state when
invoked by a systemd unit, regardless of timing or bluetoothd lifecycle.
The root cause is unknown.

The current workaround is manual execution after cold boot:

    sudo bash /usr/local/sbin/sp11-bluetooth-mac --apply --hci hci0 --no-batch --attempts 3 --settle-seconds 10 --btmgmt-timeout 10

This succeeds every time from a terminal session.

`wait_for_hci_ready` returns non-zero on timeout so callers can distinguish the
initialized / not-initialized case. The script aborts cleanly when the
controller never initializes rather than striking a half-initialized controller
with `public-addr`.
