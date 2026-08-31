---
id: adr-0053-sp11-touchscreen-stale-initramfs-repair
title: "ADR0053: Repair Stale Stock-Module Initramfs During Touchscreen Install"
# prettier-ignore
description: Architecture Decision Record (ADR) for making the guarded touchscreen installer repair, not merely detect, an initramfs that embeds the stock in-tree gpi/spi-geni-qcom modules beside the updates/ overrides.
---

# ADR0053: Repair Stale Stock-Module Initramfs During Touchscreen Install

## Status

Accepted (2026-08-15).

## Context

The `7.2-rc5-jg-0sp11v3-qcom-x1e` touchscreen stack relies on three
out-of-tree modules (`gpi`, `spi-geni-qcom`, `mshw0485_touch`) installed as
higher-priority overrides under `/lib/modules/<release>/updates/`. The stock
in-tree kernel ships its own `gpi.ko.zst` and `spi-geni-qcom.ko.zst` under
`/lib/modules/<release>/kernel/`, both owned by the `linux-modules-<release>`
package and both built as replaceable modules (`CONFIG_QCOM_GPI_DMA=m`,
`CONFIG_SPI_QCOM_GENI=m`).

Ubuntu `initramfs-tools` with its default `MODULES=most` performs an
`auto_add_modules` sweep that embeds essentially the whole in-tree driver tree
in the initramfs. The non-hostonly dracut path does the same. The result is an
initramfs that contains **both** the stock `kernel/drivers/.../gpi.ko.zst` and
the `updates/drivers/.../gpi.ko` override (and the same for `spi-geni-qcom`).

The guarded installer added the overrides and rebuilt the initramfs, but only
**detected** the duplicate in its post-build verification and then `die`d:

```text
error: initramfs also contains a stock/duplicate gpi.ko: .../kernel/drivers/dma/qcom/gpi.ko.zst
```

This is exactly ADR-0050 validation-matrix item 2 (a stale stock-module
initramfs followed by guarded repair). The case was listed as outstanding in
the r1 release notes. Two independent clean installs reproduced the hard
failure and recovered by manually deleting the stock copies and rebuilding:

1. `luminarx7` on Ubuntu Discourse
   [post 2084](https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/2084):
   "Stock/duplicate modules in initramfs … Fixed by removing redundant stock
   copies and rebuilding initramfs."
2. A local Surface Pro 11 OLED install of the r1 bundle, which hit the same
   refusal and was repaired by removing the stock `.ko.zst` files, running
   `depmod`, and re-running `install-sp11-touchscreen.sh`.

Leaving the stock module present is a real functional risk: the stock `gpi`
driver has no QSPI TRE support, and if it binds the DMA controller at early
boot the touch path fails with `CH START completion timeout` (ADR-0049).

## Decision

The installer will **repair** the stale initramfs as part of the install, not
merely refuse it. Concretely, `install-sp11-touchscreen.sh` now:

1. **Neutralises the stock in-tree modules before `depmod`.** For each
   compression variant of `kernel/drivers/dma/qcom/gpi.ko*` and
   `kernel/drivers/spi/spi-geni-qcom.ko*`, the script resolves the usr-merged
   path and either `dpkg-divert --rename`s the file when it is dpkg-owned, or
   removes it when it is not. The diversion prevents a later
   `apt --reinstall linux-modules-<release>` from silently restoring the stock
   copy; the removal fallback covers non-dpkg and offline (`--root`) installs.

2. **Guards every future initramfs rebuild.** The generated initramfs-tools
   hook deletes any `gpi.ko*` / `spi-geni-qcom.ko*` found under a `kernel/`
   path in `$DESTDIR` after the `auto_add_modules` sweep, and a new dracut
   module (`/usr/lib/dracut/modules.d/90sp11-touchscreen/module-setup.sh`)
   performs the same cleanup in `$initdir`. The `updates/` overrides are never
   matched because the pattern is restricted to `*/kernel/*`.

3. **Rejects a built-in driver early.** The installer verifies that neither
   `gpi.ko` nor `spi-geni-qcom.ko` appears in `modules.builtin`, so a future
   `=y` configuration fails before any mutation instead of silently making the
   override scheme impossible.

4. **Keeps the existing post-rebuild verification** as the final gate. If a
   stock/duplicate still appears after the repair, the installer fails loudly
   (referencing this ADR) rather than proceeding.

## Consequences

- The touchscreen install becomes self-repairing and idempotent for a fresh
  install, a stale-initramfs system, and a reinstall over an already-working
  v3 stack.
- The on-disk repair is recorded as a dpkg diversion, so `dpkg -V` reports the
  divergence cleanly and `apt --reinstall` no longer restores the stock copy.
- The persistent hooks keep future `update-initramfs -u -k all` and dracut
  rebuilds clean even if the stock files are later reintroduced.
- The repair is per-ABI: a new kernel ABI has a fresh module tree, so the
  installer must be re-run for that release, matching DKMS-style out-of-tree
  module behaviour.
- Reverting to stock modules requires removing the diversion
  (`dpkg-divert --remove --rename`) and reinstalling the kernel modules
  package, then rebuilding the initramfs.

## Related

- [ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR0050: Touchscreen Clean-Install and Release Flow](adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [geocausa Phase 91 controller source](https://github.com/geocausa/SP11X1e-touchscreen/blob/6bbcf7a4759a73014047a57e819219dd7f34951a/phase55/modules/spi-geni-qcom.c)
