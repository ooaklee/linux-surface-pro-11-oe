# Archived Surface Pro 11 qcom-x1e 7.2-rc5 v3 patch set

> [!IMPORTANT]
> This patch set and its out-of-tree touchscreen-module pairing are superseded
> historical evidence. Do not build, install or validate them on a current
> system.

The experiment enabled the MSHW0485 OLED touchscreen over SE2 QSPI, retained
the 2.4 MHz Denali DMIC clock and used the distinct
`7.2-rc5-jg-0sp11v3-qcom-x1e` ABI. At that point runtime support depended on
higher-priority out-of-tree GPI, SPI and touchscreen module overrides.

The maintained custom kernel now carries the touchscreen stack in-tree and
rejects the retired v3 release contract. Build it with
`linux-armer kernel build`; use `linux-armer doctor hardware touchscreen` for
bounded runtime evidence and `linux-armer userspace status` to report stale
module overrides for manual review. No current command installs the historical
modules.

See [ADR-0049](../../docs/adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
for the original build evidence and
[ADR-0050](../../docs/adr/adr-0050-sp11-touchscreen-clean-install-release-flow.md)
for the clean-install retrospective.
