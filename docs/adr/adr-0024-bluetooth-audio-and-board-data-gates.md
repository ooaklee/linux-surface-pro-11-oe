---
id: adrs-adr024
title: "ADR024: Bluetooth, Audio, and Board-Data Bring-Up Gates"
# prettier-ignore
description: Architecture Decision Record (ADR) for separating Surface Pro 11 Wi-Fi board data, Bluetooth MAC handling, and audio topology diagnostics from the Wi-Fi rfkill kernel patch.
---

## Context

[ADR005](adr-0005-wifi-board-fixup.md) installs a narrow WCN7850 `board.bin`
fallback extracted from `board-2.bin`. [ADR018](adr-0018-wifi-rfkill-bring-up-gate.md)
and [ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) identify
the remaining Wi-Fi blocker as platform rfkill handling.

Community reports for the same device now match the local result: Windows
firmware and board data are enough for `ath12k` to probe WCN7850 and create
`wlP4p1s0`, but Wi-Fi remains `Hard blocked: yes` until the kernel and Denali
DTB expose `disable-rfkill`.

The same reports also separate two other hardware bring-up tracks:

- Bluetooth can need a userspace public-address assignment, usually with a
  udev-triggered systemd service that runs `btmgmt public-addr`.
- Audio currently reports missing
  `qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`, and upstream
  discussion points to AudioReach topology firmware plus ALSA UCM
  configuration. Speaker routing can be risky, so this must start with
  diagnostics and conservative staging.

## Decision

The project will keep the current dwhinham-style `board.bin` fallback for
WCN7850. It will not replace the installed `board-2.bin` as the primary
Surface Pro 11 Wi-Fi response, because that targets a different failure mode
and can regress probing on otherwise working systems.

The Wi-Fi rfkill fix remains the patched qcom-x1e kernel and Denali DTB path
from [ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md).

The project will add read-only diagnostics for Bluetooth and audio before
enabling additional hardware behavior:

- `scripts/troubleshoot-sp11-bluetooth.sh` collects rfkill, HCI, BlueZ,
  systemd, and dmesg state.
- `scripts/sp11-bluetooth-mac.sh` provides an explicit, config-driven
  Bluetooth public-address helper. It only applies an address supplied by the
  operator or written to `/etc/default/sp11-bluetooth-mac`.
- `scripts/troubleshoot-sp11-audio.sh` collects ALSA, PipeWire/PulseAudio,
  topology firmware, UCM, module, and dmesg state without changing audio
  routing.

The Windows diagnostics collector will capture network hardware addresses and
Bluetooth PnP properties so users can find candidate Windows MAC-address data
without manually typing long PowerShell commands.

## Consequences

Bluetooth bring-up is explicit and reversible. A wrong Bluetooth MAC address
can break pairing or collide with another device, so the helper refuses obvious
placeholder addresses and does not invent a random address.

Audio bring-up remains diagnostic-only until the topology and UCM mapping are
confirmed for Surface Pro 11. This reduces the risk of enabling unsafe speaker
routes.

The README can now tell users not to chase board-data repacking for the
verified `phy0 Hard blocked: yes` state. If a future system shows board-data
fetch failures instead, that should be treated as a separate diagnostic path.
