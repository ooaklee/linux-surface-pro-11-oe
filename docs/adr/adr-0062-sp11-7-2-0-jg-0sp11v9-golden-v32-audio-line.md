---
id: adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line
title: "ADR0062: SP11 7.2.0-jg-0sp11v9 Golden-v32 Audio Kernel Line"
# prettier-ignore
description: Architecture Decision Record (ADR) for integrating the Golden v32 audio stack (VI+CPS feedback, pull-mode, DMIC 4.8 MHz) as the 7.2.0-jg-0sp11v9 kernel line, paired with the matching userspace UCM and canonical topology, retiring the PipeWire speaker-sink workaround, and accepting the DMIC capture regression on this line.
---

# ADR0062: SP11 7.2.0-jg-0sp11v9 Golden-v32 Audio Kernel Line

## Status

Accepted and hardware-verified (2026-08-23). The
`7.2.0-jg-0sp11v9-qcom-x1e` kernel boots on the X1E80100 OLED device with the
ported Golden v32 audio stack live: the boot-time probe configures the
protected SP/SPVI graph with VI+CPS feedback ("SP11 stage SP/SPVI enabled with
VI+CPS feedback accepted"), WirePlumber creates a native PipeWire sink
("Built-in Audio Pro"), stereo playback is audible with correct L/R mapping
(left tone from the left speaker, right tone from the right speaker), and a
clean cold-boot regression pass shows the stack coming up with no crash loop
and no workaround config. The v8 kernel remains the GRUB rollback entry.

Known, accepted limitation: DMIC capture is not available on this line (see
Consequences). Microphone bring-up is tracked as sub-issue
[linux-surface-pro-11-oe#48](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/48)
of [#33](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/33) (Surface Pro 11 feature-parity tracking).

## Context

### What the v9 line replaces

Speaker audio on the 7.1.5-based v8 line worked only through userspace
workarounds. The native sink was unusable (right speaker gated by the WSA2
regcache issue, [ADR-0034](adr-0034-wsa2-regcache-right-speaker.md)), and
correct stereo positions were achieved by a custom PipeWire sink that reordered
channels onto the hardware ([ADR-0036](adr-0036-right-speaker-audio-position-reorder.md),
`sp11-pipewire-speaker-sink.sh` / `50-sp11-speakers.conf`). The machine also
ran a self-built CRD-derived topology ([ADR-0033](adr-0033-audio-topology-gap.md),
`linux-msm/audioreach-topology@d7a5e9d`) and an OE-authored UCM
(`Surface11-HiFi.conf`) written against the old wsa884x control set.

### The Golden v32 audio stack

geocausa's upstream SP11 audio work ("Golden v32", kernel
`7.1.5-sp11-render-parity-v4+`, promoted default per
`deploy/golden-v32/manifest.json`) provides: wsa884x lifecycle and softclip
controls, soundwire-qcom shared master port with Offset2, lpass-wsa-macro
lifecycle fixes, and the q6apm-dai/audioreach SP11 pull-mode transport with a
VI+CPS feedback sidechain (SP/SPVI speaker protection).
[PR #17](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/17) ports this
stack onto the 7.2.0-jg-0 integration line as `7.2.0-jg-0sp11v9-qcom-x1e`,
with the audio modules reviewed against the Golden v32 manifest
(`deploy/golden-v32/manifest.json`) during the port.

### Bring-up findings (the pairing gap)

Installing the v9 kernel alone was not sufficient; the v8-era userspace
actively conflicted with it:

1. **No native sink.** WirePlumber attempted native nodes (`pro-output-0/4/5`,
   `pro-input-2`) and every activation aborted ("Object activation aborted:
   PipeWire proxy destroyed"). The OE UCM referenced controls the Golden v32
   kernel no longer provides in the same form: `WSA WSA_COMP1/2 Switch` (now
   `WSA_Softclip0/1 Enable`), the `MultiMedia2` mixer graph (now
   `MultiMedia1`), `SpkrLeft VISENSE Switch 0` (now 1, required for the VI
   sidechain), `PA Volume` capped at 6 (now full 0..31 with protection), and
   the topology-defined `WSA WSA_AIF_VI Mixer WSA_SPKR_VI_1/2` widgets absent
   from the CRD topology.
2. **Raw opens mislead.** `speaker-test -D hw:0,0` returned -EINVAL with
   `ASoC: no backend DAIs enabled for MultiMedia1 Playback` (expected: no
   mixer routing outside UCM); `hw:0,1` (MultiMedia2) failed on channel count
   under the new topology.
3. **The UCM path still played.** `speaker-test -D default` produced sound
   from both speakers — proving the kernel transport was healthy and
   isolating the problem to the UCM/topology pairing.
4. **The canonical pairing fixed it.** Installing geocausa's UCM
   (`deploy/ucm2/Qualcomm/x1e80100/SP11-HiFi.conf`, card conf) and his
   canonical topology (`deploy/render-parity/X1E80100-Microsoft-Surface-Pro-11-Render-Parity-tplg.bin`,
   sha256 `1b0c7217fc67bb11da002b06563dd8c411b0f0e35ac40778bff3d65093061c9d`,
   matching `canonical_topology_sha256` in the Golden v32 manifest) at
   `qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin` (the name
   `audioreach_tplg_init` requests) made the boot-time probe configure the
   full protected graph and produced the native sink.
5. **The workaround became fatal.** With the canonical topology, the workaround
   sink's target (`hw:X1E80100Microso,1`, MultiMedia2) no longer opens
   (ENOENT), so its context-level adapter creation aborted pipewire (exit 234)
   in a restart loop until the conf was removed.
6. **DMIC capture is absent.** The canonical topology (30256 bytes) embeds no
   `VA_CODEC_DMA_TX_0`/DMIC capture widgets — only the VI-sidechain
   `WSA_CODEC_DMA_TX_0/1 Protection` paths — whereas the retired OE topology
   exposed `VA_CODEC_DMA_TX_0 Capture` and `TX_CODEC_DMA_TX_3 Capture`.
   Combined with geocausa's UCM defining no capture device, no PipeWire source
   is created and raw capture has no PCM to open.

## Decision

- Adopt `7.2.0-jg-0sp11v9-qcom-x1e` (PR #17) as the audio integration line,
  replacing the v8 7.1.5-based line.
- Pair the kernel with the matching userspace: geocausa's UCM
  (`deploy/ucm2/Qualcomm/x1e80100/`) and his canonical Golden v32 topology
  binary (`deploy/render-parity/X1E80100-Microsoft-Surface-Pro-11-Render-Parity-tplg.bin`,
  sha256-verified), installed under the exact firmware filename the kernel
  loads at card probe.
- Retire the PipeWire speaker-sink workaround (`50-sp11-speakers.conf`,
  `sp11-pipewire-speaker-sink.sh`): the native sink provides stereo with
  correct positions; ADR-0036's reorder no longer applies.
- Version-lock the userspace pairing to the kernel: UCM and topology are now
  kernel-line-specific artefacts with recorded hashes
  (`deploy/golden-v32/manifest.json`), installed as part of the audio
  bring-up, not separate workarounds.
- Keep the v8 kernel as the GRUB rollback entry until the cold-boot
  regression pass completes.
- Accept the DMIC capture regression on this line and track microphone restore
  (a topology variant merging the VA/DMIC capture graph into the canonical
  speaker/VI graph, plus a UCM `Mic` device) as a separate ticket.

## Consequences

- Native sink with correct stereo positions; no custom sink configuration.
- VI+CPS speaker protection is live: the UCM pins PA at the validated
  operating point (24, +27 dB) and the machine driver caps the WSA_RX digital
  volume at 81 (-3 dB) as the protection ceiling; the VI sidechain is
  bypassed by the kernel if unavailable.
- Pull-mode transport in effect (ring 3840 / period 1920 accepted at probe);
  protection OOB memory maps are set up at stream setup.
- The UCM/topology are now coupled to the kernel line — upgrading the kernel
  without the matching pairing regresses to the "no native sink" state; this
  ADR and the manifest hashes are the reference.
- v8-era artefacts (CRD topology build, OE `Surface11-HiFi.conf`, workaround
  docs/scripts) become legacy and must be cleaned up in the OE repo install
  flow (`sp11-audio-topology.sh`, install scripts, related ADRs).
- **Accepted regression: DMIC capture is unavailable on this line.** The
  canonical Golden v32 topology (`deploy/render-parity`, sha256
  `1b0c7217…`) defines no DMIC/VA capture graph — only the VI-sidechain
  `WSA_CODEC_DMA_TX_0/1 Protection` paths — while the retired OE topology
  carried `VA_CODEC_DMA_TX_0 Capture` and `TX_CODEC_DMA_TX_3 Capture`. The
  4.8 MHz DMIC clock (superseding the 2.4 MHz test kernel,
  [ADR-0045](adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)) therefore has no
  capture route, and geocausa's UCM defines no capture device. Restoring the
  mic requires a topology variant that merges the VA/DMIC capture graph with
  the canonical speaker/VI graph plus a UCM `Mic` device — tracked as
  sub-issue
  [linux-surface-pro-11-oe#48](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/48)
  of [#33](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/33)
  (feature-parity tracking), out of scope for this line.
- Operational notes: topology changes require a reboot (loaded at card
  probe); a session crash can leave the DSP stream half-open, making ALSA
  opens return -112 (ENOTCONN) until a session restart or reboot; the rtkit
  realtime-priority warning is benign.

## Related ADRs

- [ADR-0033](adr-0033-audio-topology-gap.md) — superseded pairing source
- [ADR-0034](adr-0034-wsa2-regcache-right-speaker.md) — structurally fixed in v9 (no WSA2 macro)
- [ADR-0036](adr-0036-right-speaker-audio-position-reorder.md) — workaround retired
- [ADR-0045](adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md) — superseded by 4.8 MHz DMIC
- [ADR-0052](adr-0052-sp11-integration-fork-build.md), [ADR-0054](adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build.md), [ADR-0056](adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md), [ADR-0057](adr-0057-sp11-7-2-rc6-jg-0sp11v6-rc-branch-build.md), [ADR-0058](adr-0058-sp11-7-2-0-jg-0sp11v7-non-rc-integration-line.md) — kernel build line history
