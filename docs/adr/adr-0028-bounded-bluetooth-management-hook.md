---
id: adrs-adr028
title: "ADR028: Bounded Bluetooth Management Hook"
# prettier-ignore
description: Architecture Decision Record (ADR) for bounding Surface Pro 11 Bluetooth btmgmt commands in the automatic public-address hook.
---

## Context

[ADR027](adr-0027-bluetooth-public-address.md) chose a Windows-sourced
Bluetooth public-address helper for Surface Pro 11. The manual path worked:
`btmgmt public-addr` accepted the address, restarting `bluetooth.service` made
BlueZ expose a powered public controller, and a Bluetooth speaker could be
paired.

The first reboot test exposed a boot-hook reliability issue. The installed
system still had an older helper, and `sp11-bluetooth-mac@hci0.service` stayed
in `activating` state for several minutes. The child process was stuck in:

```text
btmgmt -i hci0 power off
```

During that stuck service state, BlueZ again had no default controller and the
HCI device reported the placeholder-like `00:00:00:00:*` address.

After installing the timeout-aware helper, the service failed cleanly instead
of hanging, but the reboot test exposed a second issue: the generated unit ran
`Before=bluetooth.service` and was also enabled through
`bluetooth.service.wants`. That held BlueZ back until the helper had exhausted
its `btmgmt` attempts. The journal then showed `bluetooth.service` starting and
initializing the management interface only after the helper failed.

## Decision

The automatic Bluetooth public-address helper will bound every `btmgmt`
operation with `timeout`.

`scripts/sp11-bluetooth-mac.sh` will:

- include `SP11_BLUETOOTH_BTMGMT_TIMEOUT` in its local config,
- accept `--btmgmt-timeout N` for manual retry tuning,
- run `btmgmt` commands through a timeout wrapper,
- keep `btmgmt` output redacted by default,
- add a 30-minute `TimeoutStartSec` to the generated systemd unit so the
  recommended retry budget can complete while still remaining bounded,
- run the generated service after `bluetooth.service` instead of before it,
- avoid enabling the helper through `bluetooth.service.wants`,
- remove older `bluetooth.service.wants/sp11-bluetooth-mac@*.service` links
  when reinstalling the helper,
- restart `bluetooth.service` after a successful public-address apply so BlueZ
  rebinds the corrected controller,
- add a small systemd start limit to reduce the impact of any repeated HCI add
  events during controller reset testing,
- bound Bluetooth `btmgmt info` collection in the diagnostic helper,
- document how to stop a stuck older service before retrying.

The project will continue to prefer the manual validate-first flow. Users
should install the automatic hook only after the manual apply and
`bluetooth.service` restart make the controller visible to BlueZ.

## Consequences

The automatic service can fail or retry without blocking boot indefinitely, and
it no longer prevents BlueZ from starting before the address helper runs. This
makes reboot testing safer and gives users a recoverable failure mode when the
Bluetooth management interface stalls.

The timeout does not prove that reboot persistence works. It only prevents the
helper from hanging forever in ordinary killable process states. Reboot
persistence, pairing, suspend/resume, and Bluetooth toggles remain validation
gates.
