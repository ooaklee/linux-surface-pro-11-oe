---
id: adrs-adr030
title: "ADR030: Bluetooth btmgmt Batch Sequence"
# prettier-ignore
description: Architecture Decision Record (ADR) for using a scripted btmgmt batch sequence when setting the Surface Pro 11 Bluetooth public address.
---

## Context

[ADR027](adr-0027-bluetooth-public-address.md) chose a trusted
Windows-sourced Bluetooth public address. [ADR028](adr-0028-bounded-bluetooth-management-hook.md)
bounded the management commands, and [ADR029](adr-0029-bluetooth-cold-boot-service-retry-profile.md)
gave the boot service a larger cold-boot retry profile.

The cold-boot profile still failed on hardware. The service ran the expected
12 attempts and no longer depended on the old five-attempt local config, but
every separate `btmgmt` invocation timed out. Diagnostics still showed:

```text
btmgmt: Index list with 0 items
hciconfig: hci0 DOWN RAW
```

The Ubuntu Discourse Surface Pro 11 workaround by `hot21shot` uses a different
shape: pipe a small command script into `btmgmt`, then run a second `btmgmt`
batch with only `public-addr`. The report notes that this sequence came from
trial and error to make Bluetooth management accept the MAC address on the
Surface Pro 11.

## Decision

`scripts/sp11-bluetooth-mac.sh` will set the public Bluetooth address with a
scripted `btmgmt` batch before falling back to the previous single-command
path.

The first batch will run:

```text
info
power off
public-addr <windows-bluetooth-mac>
info
exit
```

The second batch will run:

```text
public-addr <windows-bluetooth-mac>
exit
```

The helper will treat `Set Public Address complete` in either batch as success
and will then rely on the existing `bluetooth.service` restart to let BlueZ
bind the corrected controller. The helper will avoid extra separate
`btmgmt -i hci0 power on` calls after acceptance because those separate calls
are the operations that timed out during cold-boot testing.

## Consequences

The helper now more closely follows the community-reported Surface Pro 11
Bluetooth workaround instead of decomposing it into multiple independent
`btmgmt` processes.

Piping the address through stdin also avoids placing the real Bluetooth MAC in
the `btmgmt` process command line, although the address remains present in the
root-only helper process memory and in `/etc/default/sp11-bluetooth-mac`.

This is still a hardware hypothesis until retested on the Surface Pro 11. If
the batch accepts the address, `bluetoothctl show` remains the validation gate;
unit success alone is not sufficient.
