---
id: adrs-adr029
title: "ADR029: Bluetooth Cold-Boot Service Retry Profile"
# prettier-ignore
description: Architecture Decision Record (ADR) for giving the Surface Pro 11 Bluetooth boot service an explicit cold-boot retry profile.
---

## Context

[ADR027](adr-0027-bluetooth-public-address.md) chose a trusted
Windows-sourced Bluetooth public address. [ADR028](adr-0028-bounded-bluetooth-management-hook.md)
then bounded `btmgmt` calls and moved the generated systemd service after
`bluetooth.service`.

The next full shutdown and power-on test still failed to expose a default
BlueZ controller. The udev-triggered service failed cleanly, but the journal
showed it using the older local retry profile:

```text
btmgmt command timed out after 8s.
Attempt 5 failed to set the Bluetooth public address.
Failed to configure Bluetooth public address for hci0.
Current hci0 address: 00:00:00:xx:xx:xx
```

This indicates that the generated boot unit should not rely on whatever retry
values happen to exist in `/etc/default/sp11-bluetooth-mac`. It also indicates
that ordering after `bluetooth.service` is not enough by itself. The earlier
manual success path restarted `bluetooth.service` before applying the public
address and restarted it again afterward.

## Decision

The generated `sp11-bluetooth-mac@.service` unit will use an explicit
cold-boot profile:

- restart `bluetooth.service` before applying the public address,
- call `sp11-bluetooth-mac --apply` with `--attempts 12`,
  `--settle-seconds 20`, and `--btmgmt-timeout 12`,
- keep the post-apply `bluetooth.service` restart from ADR028,
- keep `TimeoutStartSec=30min` so the larger retry budget remains bounded.

The helper will also gain `--restart-bluetooth-before` and the matching
`SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE` config key for explicit local
testing. The option is false by default for manual runs and enabled by the
generated boot service.

## Consequences

Cold-boot testing becomes independent from stale local retry values written by
older helper versions. This should make the automatic path closer to the
manual sequence that already produced a usable public Bluetooth controller.

The service can now spend longer during cold-boot Bluetooth bring-up before it
fails. The 30-minute systemd timeout and `btmgmt` per-command timeouts keep
that bounded.

This still does not prove reboot persistence. The Surface Pro 11 must be
retested with the new generated unit after reinstalling the helper from a
rebuilt USB image.
