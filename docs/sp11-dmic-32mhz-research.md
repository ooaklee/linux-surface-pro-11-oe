---
id: sp11-dmic-32mhz-research
title: "Surface Pro 11 DMIC 3.2 MHz Research"
# prettier-ignore
description: Pinned evidence, paired-ABI protocol, and fail-safe gates for comparing the validated 2.4 MHz Surface Pro 11 DMIC setting with an unproven 3.2 MHz candidate.
---

# Surface Pro 11 DMIC 3.2 MHz Research

## Status and decision boundary

Desk research completed on 2026-08-07 without changing the target, kernel
sources, packages, boot state, or audio state. The 3.2 MHz setting is
**unproven** on the Surface Pro 11. Retain the validated 2.4 MHz setting unless
the paired experiment below demonstrates a repeatable material benefit without
a regression.

P5B hardware work remains blocked by P0. The historical embedded-versus-loose
DTB contradiction has now been corrected in the installer and documentation:
Stubble-wrapped kernels use their per-kernel embedded DTB, while installed
loose-DTB selection and injection are retired. An older
`/boot/sp11-denali.dtb` remains untouched and inert. A privileged read-only
loaded-FDT comparison must still verify the packaged/embedded/active pairing
on the current target before either test ABI is installed or booted.

This record distinguishes three evidence classes:

- **Observed fact:** directly present in a pinned public source, repository
  artifact, or recorded target result.
- **Inference:** a conclusion from those facts that still needs target proof.
- **Demonstration claim:** a claim from the public feature demonstration whose
  implementation and measurement record are unavailable.

## Pinned evidence

- Johan G. kernel baseline
  [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/tree/8f953dd060bc6e8fb86ca2ea8a92f258141c0169),
  tagged `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`.
- Exact baseline
  [Denali DTS](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi),
  [VA macro driver](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/sound/soc/codecs/lpass-va-macro.c),
  and
  [VA macro binding](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/sound/qcom,lpass-va-macro.yaml).
- The validated v3
  [2.4 MHz DTS patch](../patches/sp11-qcom-x1e-7.2-rc5-v3/0001-arm64-dts-qcom-x1-denali-use-2.4-MHz-DMIC-clock.patch)
  and its [device-side decision record](adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md).
- The
  [2026-08-07 kernel reproducibility report](sp11-kernel-reproducibility-report-20260807.md),
  which compares the current build payloads but does not prove future
  byte-for-byte replay.
- AudioReach topology source commit
  [`d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677`](https://github.com/linux-msm/audioreach-topology/tree/d7a5e9d80ad18a7a6844eeb32cacbdeea0e7e677).
- Touchscreen module source commit
  [`6bbcf7a4759a73014047a57e819219dd7f34951a`](https://github.com/geocausa/SP11X1e-touchscreen/tree/6bbcf7a4759a73014047a57e819219dd7f34951a).
- The public
  [feature demonstration](https://www.youtube.com/watch?v=WJqRIeTjUbI),
  used only as a mutable demonstration claim.

## Observed facts

### Clock selection in the exact baseline

The baseline Denali DTS sets `qcom,dmic-sample-rate = <4800000>` under
`&lpass_vamacro`. The validated v3 patch changes that one cell to `2400000`.
No UCM, topology, gain, or codec-driver change forms part of that clock patch.

The exact VA macro driver uses a 9.6 MHz master clock. Its validation accepts
exact divisors 2, 3, 4, 6, 8, and 16 and maps the selected divisor to the DMIC
clock field. Consequently:

| Requested DT value | 9.6 MHz divisor | Driver status |
|---:|---:|---|
| 4,800,000 | 2 | accepted |
| 3,200,000 | 3 | accepted |
| 2,400,000 | 4 | accepted |

The driver reads `qcom,dmic-sample-rate` at probe, rejects an unsupported
value, and defaults to divisor 2 when the property is absent. This proves that
3.2 MHz is a supported controller setting in the pinned code. It does not
prove the physical clock at the microphone pin or the best setting for the
installed microphone parts.

No VA macro driver or binding modification is required for the candidate.
The functional source change is only:

```diff
 &lpass_vamacro {
-	qcom,dmic-sample-rate = <2400000>;
+	qcom,dmic-sample-rate = <3200000>;
 };
```

### Existing target and build evidence

The current records report continuous broadband static at 4.8 MHz and much
clearer, though slightly thin or tinny, two-channel speech capture at 2.4 MHz.
They report no audible music-playback degradation. These are qualitative
observations; there is no objective 2.4-versus-3.2 target dataset.

The reproducibility audit found the packaged Denali OLED DTB byte-identical to
its Stubble-embedded `.dtbauto` copy in both adjacent v3 builds. Its recorded
SHA-256 is
`360f1b9ef87e3de33e6eeeb6fb8179abd385807860e0d177ab4d57cea9d68f7b`.
That establishes package consistency, not which DTB the firmware and bootloader
ultimately supplied to a particular running kernel.

The same audit classified all functional payload differences but found that
the raw Debian packages were not byte-reproducible. APT inputs were also not
snapshot-pinned, so an immutable future replay remains unproven. The P5 pair
must use one reviewed immutable dependency snapshot and adjacent builds; it
must not compare a new candidate against an old package as though their build
inputs were identical.

## Inferences and unknowns

- Because the pinned driver already supports divisor 3, a board-DTS value plus
  distinct ABI metadata is the smallest implementation for 3.2 MHz. Target
  evidence must still confirm probe, capture, suspend, and rollback behavior.
- The installed microphone model and its public clock limits are not pinned.
  Operation at 4.8 and 2.4 MHz does not substitute for a microphone datasheet.
- A 3.2 MHz setting may move interference relative to 2.4 MHz, but neither the
  direction nor magnitude can be inferred from divisor support.
- The live `qcom,dmic-sample-rate` property is the **active-DT requested rate**.
  It is not an electrical measurement. A physical-clock claim requires a safe,
  reviewed oscilloscope/test-point procedure; the A/B decision does not assume
  one is available.

## Demonstration claim

The public demonstration associates this feature set with a 3.2 MHz DMIC
clock. No immutable transcript, timestamped measurement record, microphone
datasheet, or reusable implementation accompanies that claim. Record the video
title, uploader, publication date, timestamp, and exact wording before citing
it in an evidence pack. Do not copy constants or implementation details from
the video, and do not treat it as a safety or provenance source.

## Loaded-DTB prerequisite

[ADR-0042](adr/adr-0042-sp11-touchscreen-troubleshooting.md) and
[ADR-0053](adr/adr-0053-one-shot-experimental-kernel-boot.md) establish the
per-kernel Stubble-embedded DTB as authoritative. ADR-0048, ADR-0049,
[ADR-0055](adr/adr-0055-retire-installed-loose-dtb-injection.md), the audio
how-to, and the installer were corrected on 2026-08-07 to retire installed
loose-DTB selection and injection. The old `/boot/sp11-denali.dtb`, if
present, is inert evidence, not an experimental input, fallback, or proof of
live-FDT provenance.

Before installing or booting the pair:

1. On the known-good fallback, record the ABI, SHA-256 of
   `/sys/firmware/fdt`, the extracted embedded Denali DTB, and any configured
   loose Denali DTB. Decode the live VA macro property and record it as the
   active-DT requested rate.
2. Compare the loaded tree with both candidates. If boot-time fixups prevent a
   byte comparison, use a reviewed canonical tree comparison and a stable set
   of identifying properties rather than declaring a match from the DMIC cell
   alone.
3. Repeat the read-only provenance check for a one-shot canary and verify that
   the next boot returns to the known-good fallback.
4. Confirm that installing a test package leaves any historical loose DTB
   byte-for-byte unchanged and inert, and that the test ABI's embedded DTB is
   its only feature-specific device-tree input.

Do not install either audio ABI while the loaded-DTB source is ambiguous.

## Smallest defensible paired-ABI experiment

Keep `7.2-rc5-jg-0sp11v3-qcom-x1e` installed and unchanged as the persistent
fallback. Build two fresh, co-installable test ABIs adjacently from the same
pinned baseline, patch ancestry, container image, immutable package snapshot,
tool versions, config, and environment:

- OCI index:
  `ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03`;
- resolved ARM64 manifest:
  `sha256:3fe5b610f5c41eeeb56c2995bd4afb4990ac5b80dc980e33f9251eaaa8013615`;
  and
- build targets: `binary-indep binary-qcom-x1e`.

| Role | Proposed ABI | Functional value |
|---|---|---:|
| A: fresh control | `7.2-rc5-jg-0sp11v3dmic2p4ab1-qcom-x1e` | 2,400,000 |
| B: candidate | `7.2-rc5-jg-0sp11v3dmic3p2ab1-qcom-x1e` | 3,200,000 |
| Recovery | `7.2-rc5-jg-0sp11v3-qcom-x1e` | validated 2,400,000 |

The A overlay changes only Debian changelog/version and
`CONFIG_VERSION_SIGNATURE`. The B overlay makes the same ABI changes and the
single Denali DTS-cell change shown above. There is no C, driver, binding,
UCM, topology, gain, speaker, suspend, touchscreen-source, or rebase change.

Build and review gates:

- Produce image, modules, architecture-specific headers, and common headers
  for both ABIs.
- Whitelist only the DTS cell and ABI metadata in the A/B source diff.
- Compare normalized configs, explicitly allowing their
  `CONFIG_VERSION_SIGNATURE` values to differ. Literal config hashes cannot
  match across correctly distinct ABIs.
- Verify each packaged Denali DTB is byte-identical to its matching embedded
  copy; decode A as `2400000` and B as `3200000`. All unrelated packaged and
  embedded DTBs must remain identical.
- Rebuild `gpi`, `spi-geni-qcom`, and `mshw0485_touch` from the pinned
  touchscreen commit against each test ABI. Record module SHA-256, srcversion,
  vermagic, initramfs inventory, and exact release. Preserve the validated
  Phase 75 runtime profile and do not opt in to `sp11_windows_se_init=1`.
- Verify that installing either ABI does not change the persistent fallback or
  a DTB consumed by another ABI.

The audio payloads must remain byte-identical to these controls:

| File | SHA-256 |
|---|---|
| `X1E80100-Microsoft-Surface-Pro-11-tplg.bin` | `e9c74273a3b01bfed3ae53ed80694c35c9b24faed367e31b595b9fb1b95eadee` |
| `Surface11-HiFi.conf` | `26ee458c07328665f28432b05927497a41198f98567059f6b0e1bddfc99f00f5` |
| `MICROSOFT-Surface-Pro-11.conf` | `11dca6935dae9bec85fd7ba1de45eac23387c5fb81114b4287abe3fe8f624696` |
| `x1e80100.conf` | `889e1ecac6a9abf812a3d37a0634579a2235ae683991d6f6e9cd6f5e4f00c6fd` |
| `CMakeLists.txt` | `13cafc687bb09ad13a92bcc5cf0e8afc899e7cd2d68bc208d3dc4aae61f8c518` |

The fixed UCM state routes DMIC0 and DMIC1 to the two capture channels on
`hw:${CardId},3` with VA DEC0/1 volumes 84, which is recorded as 0 dB. DMIC2
and DMIC3 remain unused.

## Capture and analysis protocol

Use raw ALSA rather than PipeWire. Record the exact ALSA card identity, tool
versions, period and buffer sizes, mixer dump, UCM hashes, topology hash, and
kernel/module provenance. Ensure no other process has the microphone open.

Use a fixed, documented fixture:

- fixed room, device position and orientation, source distance, power state,
  thermal state, and warm-up interval;
- 48 kHz, two-channel, `S16_LE` capture with identical ALSA parameters;
- a calibrated loudspeaker at a recorded reference SPL;
- 60 seconds of silence;
- deterministic gated speech-shaped noise and a pinned pink-noise or log-sweep
  stimulus, with generator script, seed, WAV SHA-256, and timing recorded; and
- optional human speech only as a secondary subjective check.

Run at least five balanced, randomized paired rounds. Each A or B run starts
from the fallback, uses a reviewed one-shot boot, and is followed by a verified
return to fallback. Across the matrix, exercise at least five cold and five
warm boots per test ABI. Do not reveal the assignment to the listener or
analyst until capture integrity is checked where practical.

For each boot record:

- ABI, boot entry, loaded-FDT provenance, embedded-DTB hash, and active-DT
  requested rate;
- VA macro probe/runtime errors and audio-related kernel messages;
- WAV hash, `arecord` stderr, XRUNs, and capture duration; and
- UCM, topology, mixer, module, and initramfs identities.

Analyze each channel independently after DC removal. Pre-register the analysis
script and use the same parameters for every file:

- RMS and dBFS, DC offset, near-full-scale and clipped-sample counts;
- Welch power spectral density with a Hann window, one-second segments, and
  50% overlap;
- median noise and identified tonal peaks over 20 Hz-20 kHz and the explicitly
  defined 300 Hz-8 kHz speech band;
- channel imbalance, discontinuities, dropouts, and XRUNs; and
- stimulus SNR calculated from known on/off intervals as
  `10*log10((P_on - P_noise) / P_noise)` when `P_on > P_noise`.

Promotion requires no boot, audio, touch, suspend, or core-device regression
and either at least a 3 dB reduction in an identified interference component or
at least a 1 dB median speech-band SNR improvement. The benefit must have the
same direction in at least four of five paired rounds, and B may not regress by
more than 1 dB on either channel. Equal, mixed, or inconclusive results retain
2.4 MHz.

Raw microphone recordings are private by default. Publish reviewed scripts,
stimulus hashes, scalar metrics, and spectra; publish no personal speech or
unreviewed diagnostic log.

## Regression and stop matrix

| Area | Required comparison on A and B | Stop condition |
|---|---|---|
| Provenance | Source, patch order/hashes, normalized config, packages, packaged/embedded/loaded DTBs, initramfs, modules, UCM and topology | Any unexplained difference or ambiguous loaded DTB |
| Boot/recovery | Five cold, five warm, one-shot selection, automatic return to unchanged fallback | Wrong entry, persistent-default drift, hang, or failed fallback |
| Microphone | Both channels, silence/stimulus metrics, no static, XRUN, dropout, probe error, or more than 0.01% full-scale clipped samples | Any missing channel, continuous static, kernel error, or threshold failure |
| Playback | Documented guarded low-volume left/right/mono smoke and simultaneous playback/capture | Distortion, dropout, reset, routing loss, or unsafe level |
| Suspend | Twenty s2idle cycles with post-resume capture, playback, touch, and Wi-Fi | New failure relative to A, or A cannot establish a qualified control |
| Touch | Exact-ABI modules, 1/2/5/10 contacts and 30-minute stability using the validated runtime profile | DMA timeout, reset, input loss, or profile drift |
| Core devices | Display, keyboard, touchpad, power/lid, NVMe/root, USB, charging/battery, Wi-Fi, Bluetooth and desktop login | Any new failure after boot or resume |

If the fresh 2.4 MHz control cannot pass suspend or another gate, do not call
that a 3.2 MHz regression and do not promote B. Record the experiment as
blocked or inconclusive and retain the validated fallback.

## Rollback

Any stop condition ends the run. Reboot through the physical recovery path or
select the unchanged v3 fallback. Verify its ABI, persistent boot selection,
loaded-DTB provenance, `2400000` active-DT requested rate, embedded DTB,
ABI-matched touchscreen modules and initramfs, UCM/topology hashes, mixer state,
two-channel capture, guarded playback, touch, storage, display, and networking.

Keep failed packages and reviewed logs for forensics. Do not change gain, UCM,
topology, speaker routing, or another kernel feature to rescue the comparison.
Remove experimental packages only after evidence is preserved and uninstall
behavior is known not to alter a DTB consumed by fallback.

## Upstream destination

If one rate is proven, the upstream change is Denali board data in
`arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi`. Prepare the final patch
against current mainline and use `scripts/get_maintainer.pl`; the primary route
is the Qualcomm arm64/DT tree and `linux-arm-msm`, with DT reviewers copied.
There is no ASoC codec-driver or binding patch unless later evidence finds a
separate generic defect.

If 3.2 MHz wins, submit `3200000` with the paired evidence. If 2.4 MHz wins,
retain and submit `2400000` with the same evidence. If the result is
inconclusive, publish the comparison but submit no rate change.

## Licensing and provenance

| Material | Recorded licence/provenance boundary |
|---|---|
| Denali DTS | `BSD-3-Clause`; preserve its SPDX line and Qualcomm/Dale Whinham copyright notices |
| VA macro driver | `GPL-2.0-only` |
| VA macro binding | `GPL-2.0-only OR BSD-2-Clause` |
| AudioReach topology source | Pinned public source is `BSD-3-Clause` |
| Touchscreen modules | Pinned public source is `GPL-2.0-only`; rebuild without source changes for each ABI |
| Public demonstration | Evidence only; mutable media with no reusable source or licence grant |

The source ledger deliberately records `NOASSERTION` for the mixed-license JG
kernel tree rather than applying a blanket repository licence. The modified
Denali DTS is `BSD-3-Clause`; preserve its file-level SPDX and authorship in
any exported patch.

The Surface-specific UCM files have no SPDX identifier in this repository.
They were introduced in project commit
[`890f501ff3f20155960f06c5bf740b8d8685a4c4`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/890f501ff3f20155960f06c5bf740b8d8685a4c4)
and the microphone route was changed in
[`695592192691348d39445198a90ebcc9383eaa94`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/695592192691348d39445198a90ebcc9383eaa94).
Before redistributing or proposing those UCM files upstream, record their exact
origin and licence or classify them as original project work under an
owner-reviewed licence. Do not infer their licence from the separately pinned
BSD-3-Clause topology source.
