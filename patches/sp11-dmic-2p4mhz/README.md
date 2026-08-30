# Archived Surface Pro 11 2.4 MHz DMIC experiment

> [!IMPORTANT]
> This directory is immutable historical patch evidence, not a current build
> input or operator procedure. Do not apply it to a current kernel package set.

The experiment produced the distinct
`7.1.3-jg-1dmic2p4-qcom-x1e` ABI and showed that a 2.4 MHz Denali DMIC clock
removed the continuous microphone static observed at 4.8 MHz without an
audible playback regression. That result led to the maintained source-tree
integration; the current custom kernel branch owns the accepted setting.

Build the maintained branch with `linux-armer kernel build`, inspect its closed
bundle with `linux-armer kernel inspect`, and qualify audio with
`linux-armer doctor userspace --feature audio` plus
`linux-armer doctor hardware audio`. The CLI deliberately does not inject this
archived patch set into an arbitrary kernel ref.

See [ADR-0045](../../docs/adr/adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
for the isolated experiment and
[ADR-0046](../../docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for the
device evidence and accepted default.
