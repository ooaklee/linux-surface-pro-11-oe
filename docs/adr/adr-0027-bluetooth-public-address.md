---
id: adrs-adr027
title: "ADR027: Bluetooth Public Address"
# prettier-ignore
description: Architecture Decision Record (ADR) for setting the Surface Pro 11 Bluetooth public address from a trusted Windows source.
---

## Context

After the patched qcom-x1e Wi-Fi rfkill path succeeded, Bluetooth firmware also
loaded on the installed Surface Pro 11 system. The local diagnostic showed:

- `hci0` exists on the UART transport,
- Bluetooth rfkill is not soft-blocked or hard-blocked,
- QCA WCN7850 firmware and NVM files load,
- BlueZ reports no default controller,
- `btmgmt` reports no management indexes,
- `hciconfig` reports `hci0` as `DOWN RAW`,
- the controller address is `00:00:00:00:5A:AD`.

That address is not a usable device-unique public Bluetooth address. Community
reports for this hardware class use a udev-triggered service that runs
`btmgmt public-addr` with the real Bluetooth MAC address sourced from Windows.

Local testing confirmed this path. After applying the Windows Bluetooth address
with `btmgmt public-addr`, `btmgmt power on` still reported an invalid-index
status, but restarting `bluetooth.service` made `bluetoothctl show` report a
powered public controller.

## Decision

We will treat the invalid Bluetooth public address as the next Bluetooth
bring-up gate.

The project will not invent, randomize, or derive a Bluetooth MAC address from
the Wi-Fi MAC. The operator must supply the Bluetooth address from Windows, the
Windows diagnostic bundle, or another trusted source.

`tools/collect-sp11-windows-bluetooth-address.ps1` will provide the preferred
Windows-side collection path so users do not have to retype registry and
adapter queries by hand.

`scripts/sp11-bluetooth-mac.sh` will:

- store the operator-provided address in root-readable
  `/etc/default/sp11-bluetooth-mac`,
- reject obvious placeholder addresses,
- wait for HCI readiness before applying the address,
- run repeated `btmgmt public-addr` attempts,
- treat accepted `public-addr` writes as meaningful even if immediate power-on
  status is noisy,
- install a udev-triggered systemd service for normal boot persistence,
- verify the current HCI address after applying.

`scripts/troubleshoot-sp11-bluetooth.sh` will redact MAC-like values by default
and flag known invalid address patterns such as `00:00:00:00:*`.

## Consequences

The Bluetooth fix is explicit, auditable, and reversible. It avoids publishing
private hardware addresses and avoids creating address collisions.

Users must boot Windows or inspect a Windows diagnostic report to obtain the
real Bluetooth MAC address before enabling the service.

The helper can still require a `bluetooth.service` restart after manual
application. Follow-up ADRs record the boot ordering used for reboot
persistence. Peripheral pairing remains a separate validation gate.

The automatic hook remains removable with `sp11-bluetooth-mac
--uninstall-systemd`; it does not remove the local config file because that
file contains the operator-supplied address.
