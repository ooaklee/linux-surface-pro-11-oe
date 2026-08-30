# Archived Surface Pro 11 qcom-x1e 7.2-rc5 v2 patch set

> [!IMPORTANT]
> This directory preserves a superseded audio test build. It is not current
> kernel build or installation guidance.

The patch set promoted the validated 2.4 MHz Denali DMIC clock and created the
co-installable `7.2-rc5-jg-0sp11v2-qcom-x1e` ABI while retaining the original
test packages for rollback. Its result informed the maintained source-tree
integration.

Build the current reviewed branch with `linux-armer kernel build`, retain a
known-good fallback, and qualify the resulting audio pairing with the native
userspace and hardware doctors. The CLI deliberately does not apply this
archived patch directory.

See [ADR-0046](../../docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for
the device-side evidence.
