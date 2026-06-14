---
id: adrs-adr005
title: "ADR005: Wi-Fi Board Fixup"
# prettier-ignore
description: Architecture Decision Record (ADR) for installing a temporary ath12k WCN7850 board.bin fixup for Surface Pro 11 Wi-Fi.
---

## Context

[ADR004](adr-0004-firmware-extraction-policy.md) covers platform firmware. The
Surface Pro 11 uses Qualcomm FastConnect 7800 / WCN7850 Wi-Fi. The verified
Windows report shows PCI vendor/device `17CB:1107`.

The Surface Pro 11 Arch bring-up extracts a compatible WCN7850 entry from
`board-2.bin` and installs it as `board.bin` when linux-firmware does not have
an exact Surface Pro 11 match.

This is a bring-up workaround, not a permanent distribution-quality fix.

Later installed-system testing showed that this board-file fixup is sufficient
for WCN7850 to probe and create a wireless interface, but it does not resolve
the Surface Pro 11 `phy0 Hard blocked: yes` rfkill state. That rfkill state is
handled separately by [ADR018](adr-0018-wifi-rfkill-bring-up-gate.md),
[ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md), and
[ADR024](adr-0024-bluetooth-audio-and-board-data-gates.md).

## Decision

We will ship a helper that extracts the closest known WCN7850 board entry from
the installed ath12k `board-2.bin` or `board-2.bin.zst` and writes it to
`/lib/firmware/ath12k/WCN7850/hw2.0/board.bin`.

The installed-system setup script will register this helper as an APT
post-invoke action so it can be re-applied after firmware package updates.

## Consequences

Wi-Fi setup can recover from linux-firmware package upgrades during the
experimental period.

The helper relies on the ath12k board encoder script and the board entry
remaining available. If upstream firmware gains an exact Surface Pro 11 board
entry, a future ADR should retire this workaround.

The fixup is intentionally narrow to WCN7850 on Surface Pro 11 and should not
be generalized to other devices without a separate hardware decision.
