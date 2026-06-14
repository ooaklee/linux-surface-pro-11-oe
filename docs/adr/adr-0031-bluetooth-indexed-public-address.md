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
   (Permission Denied). The working pattern is: stop bluetoothd, apply the
   address to the unclaimed controller, then restart bluetoothd.

2. **Blind sleep is unreliable.** A fixed `sleep 20` failed because cold-boot
   firmware download timing varies (60-90s observed). The controller needs to
   be reachable via the management interface before `public-addr` is issued.

3. **Interactive batch hangs in systemd.** Piping commands into `btmgmt` without
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

- add a `wait_for_hci_ready()` poll that probes `btmgmt -i hci0 info` every 5
  seconds (up to 24 polls = 120s) until the controller reports as reachable
  (`hci0:.*Primary`). This replaces the blind `sleep 20` with a readiness gate
  that adapts to actual cold-boot firmware timing. When `--no-batch` is set and
  the HCI is hci0, `wait_for_hci_ready` runs before the first `public-addr`
  attempt.

- generate the boot unit with `ExecStartPre=-/usr/bin/systemctl stop
  bluetooth.service` instead of restarting it. This releases the controller from
  bluetoothd so `btmgmt public-addr` can configure it. After the address is set,
  `ExecStartPost=-/usr/bin/systemctl restart bluetooth.service` starts
  bluetoothd fresh so it binds the corrected address.

The generated unit profile is:

```
ExecStartPre=-/usr/bin/systemctl stop bluetooth.service
ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 1 --btmgmt-timeout 15
ExecStartPost=-/usr/bin/systemctl restart bluetooth.service
```

The `--restart-bluetooth-before` flag and its config key remain available for
manual use but are no longer enabled by the generated service.

## Consequences

The helper now uses the verified working indexed command on the first attempt,
skips the no-op/hanging batch in systemd context, polls for controller readiness
instead of sleeping blind, and stops bluetoothd before applying so the
controller is unclaimed.

This supersedes the ADR030 assumption that the batch sequence is the working
mechanism. ADR030 is retained as history; the batch remains in the code only as
a portability fallback for non-systemd contexts or different BlueZ builds.

Cold-boot persistence remains to be validated on the device. The mechanism is
proven component-by-component: stop → btmgmt → restart succeeds from terminal;
the polling function is the new variable for the automatic boot path.
