---
id: adrs-adr018
title: "ADR018: Wi-Fi rfkill Bring-Up Gate"
# prettier-ignore
description: Architecture Decision Record (ADR) for treating Surface Pro 11 Wi-Fi bring-up as blocked on ath12k rfkill handling rather than firmware or board-file installation.
---

## Context

[ADR004](adr-0004-firmware-extraction-policy.md) covers platform firmware
installation, and [ADR005](adr-0005-wifi-board-fixup.md) covers the temporary
WCN7850 board-file fixup. [ADR017](adr-0017-grub-dtb-path-for-separate-boot.md)
fixed the installed-system GRUB DTB path so hardware bring-up can be evaluated
with the intended Surface Pro 11 device tree.

After those steps, installed Ubuntu still could not enable Wi-Fi. Diagnostics
showed that:

- the Qualcomm WCN785x PCI device `17cb:1107` is present,
- `ath12k_wifi7_pci` binds to the device,
- firmware loads and reports a version,
- a wireless interface is created,
- `/lib/firmware/ath12k/WCN7850/hw2.0/board.bin` exists,
- Bluetooth on the same combo device is not hard-blocked,
- Wi-Fi `phy0` is soft-blocked `no` but hard-blocked `yes`.

The Surface Pro 11 Arch bring-up documents the same class of issue. Its kernel
adds ath12k support for a `disable-rfkill` device-tree property and then sets
`disable-rfkill;` on the Denali WCN7850 `wifi@0` node.

## Decision

The project will treat installed Wi-Fi bring-up as blocked on rfkill handling,
not on firmware download or board-file extraction.

The next Wi-Fi experiment should first determine whether the installed Ubuntu
ath12k module supports the `disable-rfkill` device-tree property. This property
is not a module parameter, so the check should inspect the installed ath12k
module contents or the kernel source/patch set rather than relying on `modinfo`:

- if the module supports it, test adding `disable-rfkill;` to the installed
  `/boot/sp11-denali.dtb` WCN7850 `wifi@0` node and rebooting;
- if the module does not support it, document that Wi-Fi needs a patched kernel
  or ath12k module equivalent to the Surface Pro 11 Arch bring-up.

Firmware and board-file helpers should not be rerun as the primary response to
`Hard blocked: yes`, because they do not control the platform rfkill state.

The project will ship `scripts/troubleshoot-sp11-wifi-rfkill.sh` to collect the
rfkill state, WCN7850 PCI probe, device-tree property state, installed ath12k
module support, firmware directory contents, and filtered dmesg lines in one
repeatable command.

## Consequences

The current firmware helper work remains useful, but it is not sufficient for
Wi-Fi on this target.

The README should distinguish "driver and firmware probe works" from "Wi-Fi is
usable". A created wireless interface is not enough when `rfkill` reports a
hardware block.

The next durable fix may be outside this repository's shell scripts if the
installed Ubuntu kernel lacks the ath12k `disable-rfkill` property support.
