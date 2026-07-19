---
id: adr-0046-sp11-default-2p4mhz-dmic-clock
title: "ADR0046: Default the Surface Pro 11 DMIC Clock to 2.4 MHz"
# prettier-ignore
description: Architecture Decision Record (ADR) for making 2.4 MHz the default Surface Pro 11 digital-microphone clock after successful device-side validation.
---

# ADR0046: Default the Surface Pro 11 DMIC Clock to 2.4 MHz

## Status

Accepted (2026-07-18).

## Context

The Surface Pro 11 Denali device tree previously configured the VA macro's
digital-microphone clock at 4.8 MHz. With the corrected two-channel UCM path
and unity decoder gain, that configuration captured intelligible speech but
also produced continuous broadband static and visible idle activity. The same
noise was present in raw ALSA capture, so it was not specific to Firefox,
PipeWire, or a desktop portal.

Software-side experiments did not provide an acceptable correction:

- decoder-mode changes did not materially alter the noise;
- an 80 Hz high-pass and 8 kHz low-pass filter improved clarity but left the
  static audible; and
- WebRTC noise suppression lowered idle activity but degraded speech quality
  substantially.

[ADR-0045](adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md) therefore defined a
co-installable `7.1.3-jg-1dmic2p4-qcom-x1e` kernel with the Denali clock changed
to 2.4 MHz in the Stubble-embedded DTB. The separate ABI preserved the working
4.8 MHz kernel as a rollback option while the hardware-level change was
evaluated.

## Decision

Use 2.4 MHz as the default DMIC clock for Surface Pro 11 Denali kernel builds:

```dts
qcom,dmic-sample-rate = <2400000>;
```

Future Surface Pro 11 kernel patch sets and packaged Stubble images must carry
this value unless new device-side evidence demonstrates a regression. The
4.8 MHz value is no longer the preferred default.

The `7.1.3-jg-1dmic2p4` ABI and prerelease remain useful as the isolated
validation artifact. Future general-purpose builds do not need to retain the
`dmic2p4` experiment suffix once the accepted property is integrated into
their normal versioned patch set.

The first standard package set carrying this decision is
`7.1.3-jg-1sp11v2`, published as
[`sp11-qcom-x1e-7.1.3-jg-1-v2`](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-1-v2).
It uses `patches/sp11-qcom-x1e-7.1.3-v2`; the diagnostic patch set remains
unchanged for provenance. The matching corrected UCM is published in
[`sp11-audio-topology-v2`](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-topology-v2).

Keep a known-good kernel installed during the first boot of any newly packaged
kernel. This is a general rollback precaution and is no longer evidence that
the 2.4 MHz clock itself is considered experimental.

## Device-Side Evidence

The test kernel was installed and booted on a Surface Pro 11. A remote
read-only inspection confirmed the running release:

```text
7.1.3-jg-1dmic2p4-qcom-x1e
```

Reading the authoritative live device tree confirmed that the Stubble-embedded
Denali DTB was active:

```text
/sys/firmware/devicetree/base/soc@0/codec@6d44000/qcom,dmic-sample-rate
2400000
```

The installed package set was internally consistent at version
`7.1.3-jg-1dmic2p4`:

- `linux-image-7.1.3-jg-1dmic2p4-qcom-x1e` (`arm64`)
- `linux-modules-7.1.3-jg-1dmic2p4-qcom-x1e` (`arm64`)
- `linux-headers-7.1.3-jg-1dmic2p4-qcom-x1e` (`arm64`)
- `linux-qcom-x1e-headers-7.1.3-jg-1dmic2p4` (`all`)

ALSA UCM exposed both expected logical devices:

```text
Speaker  Speaker playback
Mic      Internal microphones
```

PipeWire exposed `Surface Pro 11 Speakers` and
`Built-in Audio Internal microphones`. During the inspection, Firefox had
active left and right capture streams connected to the internal microphone,
while music playback was active through the Surface speaker sink.

The device test produced the following observed result compared with the
4.8 MHz kernel:

- the continuous microphone feedback/static was no longer audible;
- recorded speech was dramatically clearer and described as almost perfect;
- capture retained a slightly tinny or thin quality; and
- music playback showed no audible degradation.

The live kernel identity, live DTB value, audio graph, and simultaneous
capture/playback state tie the result to the packaged 2.4 MHz configuration
rather than an unused loose DTB.

## Alternatives Considered

**Retain 4.8 MHz and rely on filtering (rejected).** Filtering did not remove
the static without compromising voice quality, while the 2.4 MHz kernel
removed the dominant defect at its source.

**Keep 2.4 MHz as an opt-in experiment (rejected).** Target validation showed
a substantial capture improvement and no audible speaker regression. Keeping
the inferior 4.8 MHz setting as the default would preserve a known defect.

**Treat desktop volume-meter activity as the acceptance test (rejected).** The
decision is based on an actual recording and playback comparison, supported by
live kernel and device-tree inspection. Meter activity alone is not a reliable
measure of perceived microphone quality.

**Claim microphone bring-up is complete (rejected).** The dominant static is
resolved, but the remaining tinny character deserves separate investigation
and objective recording comparisons.

## Consequences

- Surface Pro 11 microphone capture defaults to the validated 2.4 MHz clock.
- The persistent static associated with the tested 4.8 MHz configuration is
  no longer accepted as an unavoidable software limitation.
- Speaker routing and playback configuration remain unchanged.
- Documentation must describe the microphone as working with a remaining
  tonal-quality limitation, rather than as unusable because of static.
- Future audio work can focus on the thin/tinny tonal balance, microphone
  response, gain staging, and objective measurements instead of broadband
  static suppression.
- Validation currently covers one Surface Pro 11 and a subjective listening
  comparison. Additional units and repeatable captured samples would improve
  confidence but are not required to retain 2.4 MHz as the default.
- Kernel and UCM releases are versioned separately but cross-linked because
  the UCM corrects routing, gain, and channel count while the kernel clock
  removes the dominant static.

## Related

- [ADR-0033: Surface Pro 11 Audio Topology Gap](adr-0033-audio-topology-gap.md)
- [ADR-0042: Touchscreen — Kernel Integration Troubleshooting and Remaining Blockers](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR-0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels](adr-0044-sp11-ucm-single-wsa-macro-microphone.md)
- [ADR-0045: Surface Pro 11 2.4 MHz DMIC Clock Test Kernel](adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
- [`patches/sp11-qcom-x1e-7.1.3-v2/README.md`](../../patches/sp11-qcom-x1e-7.1.3-v2/README.md)
