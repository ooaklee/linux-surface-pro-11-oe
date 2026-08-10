---
id: adrs-adr019
title: "ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill"
# prettier-ignore
description: Architecture Decision Record (ADR) for building a patched Ubuntu qcom-x1e kernel when installed ath12k lacks Surface Pro 11 disable-rfkill support.
---

## Context

[ADR018](adr-0018-wifi-rfkill-bring-up-gate.md) identified Wi-Fi bring-up as
blocked on ath12k rfkill handling rather than firmware installation. After
upgrading the installed system to Ubuntu's `7.0.0-32-qcom-x1e` kernel, the
Surface Pro 11 still reported:

- `phy0` soft-blocked `no` but hard-blocked `yes`,
- the loaded Denali device tree missing `disable-rfkill`,
- the installed ath12k modules missing `disable-rfkill` support by string
  scan,
- WCN7850 probing, firmware loading, and wireless-interface creation working.

The Surface Pro 11 Arch bring-up uses a two-part fix: ath12k reads a
`disable-rfkill` devicetree property, and the Denali WCN7850 `wifi@0` node sets
that property. A DTB-only edit is not enough unless the running ath12k module
also knows how to read the property.

The Surface Laptop 7 notes include an older blunt workaround that returns
before ath12k configures rfkill at all. That can be useful for bring-up, but it
is broader than necessary for Surface Pro 11 now that a targeted devicetree
property exists.

## Decision

The project will carry a patched Ubuntu qcom-x1e kernel build path for the
Surface Pro 11 Wi-Fi experiment.

The preferred source input is the source package and version recorded by the
running Ubuntu qcom-x1e kernel packages, starting with
`linux-modules-$(uname -r)`, so the rebuilt kernel matches the package stream
currently booting on the device. A public git source mode remains available as
a fallback, but it must be treated as potentially older than packages installed
from PPAs or concept-image repositories.

The project will ship two patch files under `patches/ubuntu-qcom-x1e-7.0/`:

- `0001-wifi-ath12k-add-disable-rfkill-devicetree.patch`,
- `0002-arm64-dts-qcom-x1-denali-disable-rfkill-for-wifi.patch`.

The project will ship `scripts/build-sp11-qcom-x1e-kernel.sh` to download or
clone the kernel source, apply those patches idempotently, and build the
`qcom-x1e` kernel packages. Installation is opt-in through `--install`.

The local rebuild may produce packages with the same qcom-x1e ABI name as the
currently installed kernel. The installer therefore uses package reinstall
semantics for local `.deb` files rather than assuming apt will install an
already-installed version as a new package. Before installing, the helper
checks for a different installed qcom-x1e kernel ABI and refuses to proceed
unless a fallback exists or the operator explicitly passes `--allow-no-fallback`.
Users must keep an older known-good qcom-x1e ABI installed as a GRUB fallback
during this experiment and should not run `apt autoremove` until the patched
kernel has booted and Wi-Fi behavior is known.

The installed DTB injector will prefer the newest versioned Denali DTB path for
each compatible DTB name, so a patched kernel package is less likely to be
followed by copying an older unpatched DTB into `/boot/sp11-denali.dtb`.

## Consequences

Wi-Fi bring-up now depends on a local kernel build. This is slower and riskier
than firmware-only setup, but it directly addresses the verified blocker.

The build should happen on the installed Surface Pro 11 or another ARM64 Linux
system with enough disk space and power. The macOS USB-image builder remains
separate from kernel-package building.

Generated kernel `.deb` files and build trees are local artifacts. They must
not be committed to this repository.

If the patched kernel boots and the diagnostic helper reports both DT and
module `disable-rfkill` support, the next validation is whether `phy0` stops
reporting `Hard blocked: yes` and NetworkManager can scan for Wi-Fi networks.

If the patched kernel fails to boot, use GRUB's advanced options or the direct
live USB to return to an older known-good qcom-x1e kernel.
