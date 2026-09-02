---
id: adr-0073-sp11-7-2-2-target-userspace-contract
title: "ADR0073: SP11 7.2.2 Target Userspace Contract"
# prettier-ignore
description: Architecture Decision Record (ADR) mapping the focused 7.2.2 SP11 target series to the maintained OE userspace integrations and their release gates.
---

# ADR0073: SP11 7.2.2 Target Userspace Contract

## Status

Accepted for retrospective build validation on 2026-09-02. Physical
qualification of the exact kernel and userspace release pair remains pending.

## Context

The `sp11/ubuntu-qcom-x1e-7.2.y-target` branch demonstrates the result of the
focused SP11 pull requests against `jg/ubuntu-qcom-x1e-7.2.y`. The
`sp11/ubuntu-qcom-x1e-7.2.y-target-fix-pt-2` retrospective adds two corrections:

- accept AudioReach modules with more than eight input ports; and
- publish the complete Denali QSPI event-ring doorbell address before channel
  activation, while keeping the completion workarounds Denali-gated.

Those changes repair kernel implementation behavior. They must not silently
change a userspace identifier, replace a proven payload, or pull unrelated
experiments from `sp11/integration-7.2.x`.

## Decision

Use the following compatibility classification when propagating the fixes to
the focused pull-request branches and then rebuilding the demonstration target.

| Integration | Kernel contract on the 7.2.2 target | Userspace action |
| --- | --- | --- |
| FullIO audio topology | Card model, protected private-data type values, and playback graph identities are unchanged. The v19c topology reaches its `sp11.sal.4001` widget and fails only at the old eight-input parser bound. | Keep the complete checksum-pinned v19c topology. Revalidate it after the parser fix; do not rebuild merely because comments, type spelling, or kernel implementation structure changed. |
| UCM microphone capture | `VA Capture`, `TX Capture`, `TX_CODEC_DMA_TX_3`, the Denali card model, and the two TX/VA DMIC routes are present. | Keep the existing two-channel Surface UCM. Revalidate both ALSA and PipeWire capture after the card probes. |
| IPTSD pen | BUS SPI, vendor `045e`, product `0c83` for X1E and `0c80` for X1P, the HIDRAW-only bridge, and its report descriptor are preserved. The target replaces global module-policy switches with Kconfig and Denali DT opt-ins. | No configuration, udev, service, or binary edit. Confirm `_IPTSD=y`, one matching HIDRAW device, pen-only IPTSD configuration, and suspend/rebind behavior. |
| Native touchscreen | The QSPI correction changes DMA event delivery, not evdev geometry or names. | No userspace edit. Requalify cold boot, multitouch, recovery, and suspend. |
| IMX681 camera | Sensor name, 3840×2640 SRGGB10 format, endpoint link frequencies, and media graph identity are preserved; target endpoint validation is stricter. | Keep the existing libcamera Simple IPA patch and `imx681.yaml`. Repeat native package, media graph, RAW10, processed-stream, privacy, and suspend gates. |
| Platform profiles | DT-only kernels expose one native `platform-profile-*` class device but no genuine ACPI aggregate files. PPD 0.30 probes only the latter and misspells `balanced-performance` while reading it. | Apply the source-pinned userspace change from ADR0072 and require the 7.2.2/sp11v1-or-newer pairing in Lexr diagnostics. Do not restore a synthetic kernel ACPI hierarchy. |
| Battery | The target omits duplicate SAM BAT1/ACAD providers and retains the DT Qualcomm battery manager. | No payload edit. Verify UPower reports one battery and one AC source without duplicate devices. |
| Firmware, Wi-Fi, Bluetooth, GPU | Neither retrospective correction changes their firmware filenames, private hand-off paths, or userspace service contracts. | No edit. Retain existing checksum and hardware validation gates. |

The protected AudioReach numeric private-data identifiers are identical between
the known-good v21 source and the focused target. The observed v1 failure after
loading the existing topology is stronger compatibility evidence than a source
timestamp: the loader reaches the named SAL module and rejects its declared
ten input ports. A token-incompatible topology would fail earlier or at a
different object. The smallest correction is therefore the parser-bound fix,
not a newly generated binary.

Lexr evaluates userspace compatibility against an installed, complete
`/lib/modules/<ABI>` directory. This permits staging userspace before rebooting
the paired kernel. Live class-device absence remains a separate diagnostic,
so an installed ABI cannot falsely prove that the currently booted runtime is
ready.

## Guardrails

- Propagate the AudioReach correction with the focused protected-audio series
  and the GPI correction with the focused QSPI/touch series.
- Keep Denali-specific behavior gated by `microsoft,denali` or the corresponding
  DT opt-in; do not widen shared-driver quirks to unrelated hardware.
- Do not import the integration branch's cluster-idle disable, SAM D3 override,
  or USB PHY resume experiments. They are independent decisions and do not
  repair the observed audio, microphone, touch, pen, or desktop profile failures.
- Treat identical names and static tests as compatibility evidence, not physical
  qualification. Publish only after the exact target tree and userspace bundle
  pass the feature-specific runtime gates above.

## Consequences

- The only maintained OE userspace source change required by the retrospective
  target is the power-profiles-daemon native-class integration.
- Audio, microphone, IPTSD, camera, battery, firmware, and radio integrations
  retain their existing assets but acquire an explicit 7.2.2 requalification
  obligation.
- The demonstration target can remain a faithful merge simulation of focused
  upstream pull requests instead of becoming another integration branch with
  unrelated fixes.
