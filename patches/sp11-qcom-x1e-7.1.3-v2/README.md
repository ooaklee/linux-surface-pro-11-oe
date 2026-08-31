# Archived Surface Pro 11 qcom-x1e 7.1.3 v2 patch set

> [!IMPORTANT]
> This directory preserves the source evidence for a superseded kernel. Do not
> use it as current build or installation guidance.

The patch set promoted the device-validated 2.4 MHz Denali DMIC clock and gave
the test result the distinct Debian version `7.1.3-jg-1sp11v2`. It depended on
the archived 7.1.3 compatibility patch set and produced a co-installable
four-package experiment.

The maintained custom kernel branch now carries the accepted hardware support.
Use `lexr kernel build` for that branch, `kernel inspect` for its closed
package set, and `kernel preflight`/`kernel install` with a retained fallback
when qualifying it. The CLI does not apply this archived patch directory.

See [ADR-0046](../../docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for
the device-side decision.
