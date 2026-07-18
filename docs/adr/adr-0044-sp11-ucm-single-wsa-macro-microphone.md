---
id: adr-0044-sp11-ucm-single-wsa-macro-microphone
title: "ADR0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels"
# prettier-ignore
description: Architecture Decision Record (ADR) for matching the Surface Pro 11 UCM profile to its single WSA macro and exposing the verified two-channel internal microphone path.
---

# ADR0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels

## Status

Accepted (2026-07-18).

Validated on a Surface Pro 11 running `7.1.3-jg-1-qcom-x1e`. The corrected
UCM profile opens its `HiFi` verb, lists `Speaker` and `Mic`, and records a
two-channel, 48 kHz, 16-bit sample from `hw:0,3` with signal on both channels.
PipeWire also exposes the source and records from it after selecting `HiFi`.
Routing is functional, but capture is not considered production-ready because
recordings contain persistent broadband static or scratching noise.

## Context

The Surface Pro 11 audio PCM presents four playback channels, which initially
suggested that the device might expose four independently routable speakers.
The available platform descriptions do not support that interpretation:

- Microsoft's specification describes 2 W stereo speakers and dual studio
  microphones.
- The kernel device tree describes two WSA8845 amplifiers, `SpkrLeft` and
  `SpkrRight`, attached to one SoundWire bus and one WSA macro.
- The ACPI dump identifies the Qualcomm audio DSP and codec resources, but it
  does not describe another pair of speaker endpoints.

The four-channel playback PCM is therefore a DSP transport layout, not proof
of four independent speaker endpoints. The existing PipeWire workaround maps
the audible transport channels to the two stereo endpoints.

Microphone capture was a more actionable gap. ALSA exposed MultiMedia4 capture
as `hw:0,3`, accepting two to four channels at 48 kHz in `S16_LE`, but
PipeWire exposed no source. Opening the UCM `HiFi` verb reproduced the cause:

```text
unable to execute cset 'name='WSA2 WSA RX0 MUX' AIF1_PB'
failed to initialize new use case: HiFi
```

The Surface profile included both `Wsa1Speaker*` and `Wsa2Speaker*` sequences.
The live card has controls prefixed `WSA`, corresponding to the first macro,
but no `WSA2` controls. UCM aborted the entire verb while enabling the
nonexistent second macro, so WirePlumber could not create normal speaker or
microphone profiles.

## Decision

Keep the Surface Pro 11 profile on the single WSA macro described by the
device tree and exposed by the live ALSA card:

- retain the `Wsa1SpeakerEnableSeq.conf` and
  `Wsa1SpeakerDisableSeq.conf` includes;
- remove all `Wsa2SpeakerEnableSeq.conf` and
  `Wsa2SpeakerDisableSeq.conf` includes from the Surface-specific UCM verb;
- retain the two-speaker WSA884x codec sequence, because it configures the
  left and right WSA8845 amplifiers on that one macro;
- declare `CaptureChannels 2` for the internal `Mic` device, matching the two
  DMIC paths enabled by UCM and the dual-microphone hardware specification;
  and
- use a Surface-specific DMIC0/DMIC1 enable sequence with `VA_DEC0 Volume` and
  `VA_DEC1 Volume` set to 84 (0 dB), rather than the shared enable sequences'
  value of 100 (+16 dB), avoiding unnecessary input clipping on this board.

Apply the same definition to the checked-in UCM payload and to the fallback
UCM emitted by `scripts/sp11-audio-topology.sh`, so generated and packaged
profiles cannot drift.

Do not add DMIC2/DMIC3 routes merely because the PCM accepts four capture
channels. The current UCM enables DMIC0 and DMIC1, the platform specification
describes two microphones, and the ACPI data does not provide a four-mic
routing map.

## Alternatives Considered

**Model four independent speakers (rejected).** The four-channel PCM is not a
physical endpoint inventory. Neither the device tree nor the live mixer
controls expose four independently addressable speaker amplifiers.

**Add a second WSA macro to the topology (rejected).** The live kernel card
does not expose `WSA2` controls, and the Surface device tree describes one WSA
macro. Inventing another macro would make UCM diverge further from the board.

**Add DMIC2 and DMIC3 (rejected).** Four-channel capture is allowed by the
DSP frontend, but no board-level evidence maps another microphone pair. Blind
routes risk recording zeros, duplicated channels, or an unrelated input.

**Create another manual PipeWire node (deferred).** A manual source could
bypass UCM, as the current speaker sink does. Fixing the UCM activation error
first restores the standard ALSA/WirePlumber integration point and avoids a
second permanent workaround.

## Consequences

- The `HiFi` verb no longer fails on nonexistent `WSA2` mixer controls.
- UCM exposes both the speaker and internal microphone devices.
- Internal microphone capture has an explicit two-channel contract.
- Surface-specific microphone gain starts at unity rather than +16 dB.
- Persistent microphone static remains unresolved; this decision fixes UCM
  activation, channel count, and clipping, not the underlying noise source.
- The existing four-channel speaker transport and PipeWire channel reorder
  remain unchanged.
- This decision does not claim that every physical acoustic transducer inside
  a speaker module can be controlled independently; it records the two
  endpoints exposed by the Linux hardware description.
- Speaker distortion and the manual PipeWire speaker sink remain separate
  follow-up work.

## Validation

On the target device:

```bash
alsaucm -c hw:0 set _verb HiFi list _devices
arecord --dump-hw-params -D hw:0,3 -d 1 /dev/null
arecord -D hw:0,3 -f S16_LE -r 48000 -c 2 -d 5 sp11-mic-test.wav
```

The corrected profile listed `Speaker` and `Mic`. The recording was stereo,
48 kHz, 16-bit PCM, and audio statistics reported non-silent content on both
channels. Selecting the `HiFi` card profile created the PipeWire source
`Built-in Audio Internal microphones`; a second recording through that source
also completed successfully. Reducing decoder gain from +16 dB to 0 dB
removed full-scale clipping from the controlled DMIC1 sample. DMIC2 produced
an anomalous full-scale stream and DMIC3 was silent, so the existing DMIC0 and
DMIC1 routes were retained.

Quiet-room recordings still showed continuous activity and audible broadband
static. DMIC0 was the cleaner of the two routed inputs, while DMIC1 was roughly
10 dB noisier in controlled samples. Selecting low-power, default, or
high-performance VA decoder modes did not materially change the measurements.
An 80 Hz high-pass plus 8 kHz low-pass filter improved clarity but left audible
static. WebRTC noise suppression lowered the idle level at the cost of much
worse voice quality, so neither workaround is part of the default profile.

A 2.4 MHz DMIC clock comparison requires a rebuilt test kernel. Replacing
`/boot/sp11-denali.dtb`, using GRUB's `devicetree` command, and copying a test
DTB to the EFI System Partition all left the live value at 4.8 MHz. This is the
Stubble handoff already recorded by ADR-0042: the active Denali DTB is embedded
in the Stubble-wrapped kernel image. A valid clock comparison therefore
requires patching the Denali DTS and rebuilding the complete `linux-image`
package so `ukify` embeds the modified DTB. ADR-0045 defines the independently
installable `7.1.3-jg-1dmic2p4-qcom-x1e` build used for that comparison.

## References

- [Surface Pro 11th Edition technical specifications](https://learn.microsoft.com/en-us/surface/tech-specs/surface-pro-snapdragon-tech-specs)
- [Surface Pro 11 Qualcomm ACPI dump](https://github.com/linux-surface/acpidumps/tree/master/surface_pro_11_qcom)
- [ADR-0033: Surface Pro 11 Audio Topology Gap](adr-0033-audio-topology-gap.md)
- [ADR-0036: Right Speaker Audio via PipeWire audio.position Reorder](adr-0036-right-speaker-audio-position-reorder.md)
- [ADR-0042: Surface Pro 11 Touchscreen Kernel Integration Troubleshooting](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR-0045: Surface Pro 11 2.4 MHz DMIC Clock Test Kernel](adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
