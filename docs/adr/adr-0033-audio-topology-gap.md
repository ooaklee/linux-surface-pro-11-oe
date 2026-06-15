---
id: adr-0033-audio-topology-gap
title: "ADR0033: Surface Pro 11 Audio Topology Gap"
# prettier-ignore
description: Architecture Decision Record (ADR) for the missing X1E80100-Microsoft-Surface-Pro-11-tplg.bin topology file that prevents ALSA sound card instantiation.
---

# ADR0033: Surface Pro 11 Audio Topology Gap

## Status

Accepted — Track A completed (2025-06-15). Speakers produce audio via generated
topology. PipeWire UCM auto-profile remains unresolved.

## Results: Track A (2025-06-15)

| Check | Result |
|---|---|
| Topology build | CRD→SP11 topology compiled with m4+alsatplg, 36KB binary |
| Card instantiation | Card0 `X1E80100Microso` appears with 4 playback + 2 capture PCMs |
| Mixer controls | WSA SpkrLeft/Right PA Volume, DAC, BOOST, mixer routes present |
| Speaker playback | 4ch 440Hz sine via `speaker-test hw:0,1` produces audio |
| No WSA errors | Clean dmesg during playback |
| PipeWire ACP | Card detected, UCM loaded, but `auto-profile = false` — no automatic sink creation |
| PCM channels | Device 0=2ch, Device 1=4ch (MultiMedia2 → WSA CODEC DMA RX 0)

## Context

### Pre-Track-A failure state

Before Track A, the Surface Pro 11 Ubuntu bring-up reached the Qualcomm
X1E80100 audio stack far enough to load ADSP/CDSP firmware and enumerate audio
components, but the `snd-x1e80100` card did not instantiate:

```text
qcom-apm gprsvc:service:2:1: Direct firmware load for qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin failed with error -2
snd-x1e80100 sound: ASoC: failed to instantiate card -2
```

This left ALSA with no sound cards and PipeWire with only `Dummy Output`.

### Post-Track-A state (2025-06-15)

The topology has been built from the CRD template and installed. Card0 now
instantiates cleanly, mixer controls are present, and speaker output is
confirmed via `speaker-test hw:0,1 -c 4 -f 440`. PipeWire sees the card but
does not auto-create a sink due to ACP `auto-profile = false`. See Results
table above for full state.

## Findings

### Topology Filename Source

The AudioReach topology loader constructs the firmware path in
`sound/soc/qcom/qdsp6/topology.c` as:

```text
qcom/{card->driver_name}/{card->name}-tplg.bin
```

For this machine driver, `card->driver_name` is `x1e80100`. `card->name` is
parsed by the Qualcomm common sound-card helper from the sound-card node's
`model` property, falling back to deprecated `qcom,model` only for older
device trees.

The observed filename therefore means the active DTB's sound-card node name is
already effectively:

```text
X1E80100-Microsoft-Surface-Pro-11
```

It should not be treated as a sanitised transformation of the root DTB model
`Microsoft Surface Pro 11th Edition (OLED)`. In Dan Whinham's current kernel
tree, the Denali include explicitly sets the sound-card model to
`X1E80100-Microsoft-Surface-Pro-11`.

References:

- Linux `audioreach_tplg_init()` topology filename construction:
  <https://github.com/torvalds/linux/blob/master/sound/soc/qcom/qdsp6/topology.c>
- Linux Qualcomm sound-card `model` parsing:
  <https://github.com/torvalds/linux/blob/master/sound/soc/qcom/common.c>
- Dan Whinham Surface Pro 11 Denali DTS include:
  <https://github.com/dwhinham/kernel-surface-pro-11/blob/x1e80100-6.18-rc7-sp11/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi>

## Verification (2025-06-15)

### Topology Filename Path: Confirmed

`audioreach_tplg_init()` at `sound/soc/qcom/qdsp6/topology.c:1312-1330`. Filename:

```
qcom/{card->driver_name}/{card->name}-tplg.bin
```

`card->driver_name` = `"x1e80100"` (DAI link table in `snd_soc_x1e80100.c`).
`card->name` = `"X1E80100-Microsoft-Surface-Pro-11"` (from `model` property of
the sound-card DT node, parsed in `sound/soc/qcom/common.c:38` via
`snd_soc_of_parse_card_name(card, "model")`). The observed dmesg error matches
exactly. **Confirmed**.

### Topology-Less Fallback: Not Present

`q6apm_audio_probe()` at `sound/soc/qcom/qdsp6/q6apm.c:720-723` unconditionally
returns the result of `audioreach_tplg_init()`. Topology load failure returns
`-ENOENT` from `request_firmware()` → ASoC component probe failure → card
instantiation fails. **There is no fallback path** to create a partial card.

### DTS Wiring: Confirmed

dwhinham's Denali DTSI has exactly 2 DAILINKs:
- `wsa-dai-link` → WSA_CODEC_DMA_RX_0
- `va-dai-link` → VA_CODEC_DMA_TX_0

No RX_CODEC_DMA, TX_CODEC_DMA, or DisplayPort DAILINKs are defined.

### Active System: Two WSA Macros

`/proc/device-tree/soc@0/` shows 5 codec nodes:
- `codec@6aa0000` — WSA macro 1 (drives L+R stereo speakers)
- `codec@6b00000` — WSA macro 2 (likely tweeter pair on SP11 HW)
- `codec@6ac0000` — RX macro (WCD939x headphone)
- `codec@6ae0000` — TX macro (WCD939x mic)
- `codec@6d44000` — VA macro (voice-activation mic

The DTS only references `WSA_CODEC_DMA_RX_0` (first WSA macro). The second WSA
macro, headphone RX, and TX mic are present on the HW but not wired in the
current DTS sound node.

### Closest Topology Sources in audioreach-topology

| M4 Template | DAI links | Match |
|---|---|---|
| `X1P42100-Microsoft-Surface-Pro-12in.m4` | WSA_RX_0, VA_TX_0 | **Exact semantic match** |
| `X1E80100-CRD.m4` | WSA_RX_0, VA_TX_0, TX_TX_3, DP_0-7 | Extra links, but same M4 used for 10+ devices incl. Romulus |

### What dwhinham Likely Uses

The `sp11-grab-fw.sh` does not include any `tplg.bin`. The kernel tree has no
topology generation. The most likely mechanism: the Arch kernel either bundles a
CRD/EVK-derived topology under the SP11 card name, or has a local patch to skip
it. The "distorted" speakers reported are consistent with a crude topology
fallback.

### Hardware Risk: Confirmed

jglathe's audio wiki explicitly warns speaker/amp damage is possible with
incorrect UCM/topology. The machine driver's `x1e80100_snd_init()` limits WSA
digital volume to 81/127 (-3 dB) and PA volume to 6/31, but these are
card-level and apply to any loaded topology.

### DTS WSA-Macro Evidence (Original) for Reference

The earlier draft claimed that Surface Pro 11 was uniquely dual-WSA among
X1E80100 boards and that it used both `WSA_CODEC_DMA_RX_0` and
`WSA_CODEC_DMA_RX_1`. That claim is not supported by the checked DTS files.

The upstream mainline Denali OLED DTS currently contains the root device model
but not a complete Surface Pro 11 sound-card node. Dan Whinham's current Denali
sound-card node is modelled as a single WSA macro path using
`WSA_CODEC_DMA_RX_0`, like Surface Laptop 7 / Romulus. It does not describe a
second WSA macro or `WSA_CODEC_DMA_RX_1`.

Other X1E80100 boards are not uniformly single-WSA either: upstream Lenovo Yoga
Slim 7x and Medion SPRCHRGD 14 S1 DTS files reference both `lpass_wsamacro` and
`lpass_wsa2macro`, but still route playback through `WSA_CODEC_DMA_RX_0`.

Therefore, the current evidence says:

- Surface Pro 11 may still have board-specific speaker/amp quirks, but the
  "unique dual-WSA using RX0 and RX1" statement is unproven.
- Existing dual-WSA-looking DTS examples should be studied before creating a
  Surface-specific topology.
- Any conclusion about physical tweeter/woofer split needs confirmation from
  the active DTB, Windows ACPI/DSDT, schematics, or measured SoundWire
  enumeration on the actual device.

References:

- Upstream X1E80100 DTS directory:
  <https://github.com/torvalds/linux/tree/master/arch/arm64/boot/dts/qcom>
- Dan Whinham Surface Pro 11 kernel tree:
  <https://github.com/dwhinham/kernel-surface-pro-11>

### Community Audio Bring-Up Reference

`dwhinham/linux-surface-pro-11` reports audio as partial: speakers work but may
sound distorted, and microphones are too distorted to be useful. The repository
does not contain a Surface-specific topology symlink or audio setup script that
explains this directly.

A later issue comment points to `jglathe/linux_ms_dev_kit` and its SP11/SP12
discussion. That discussion links to jglathe's Snapdragon X audio setup notes.
Those notes do **not** recommend blindly symlinking a random CRD topology.
Instead, the working pattern is:

1. build a generated AudioReach topology from an `audioreach-topology` branch,
2. install matching ALSA UCM files,
3. add required UCM/setup symlinks,
4. keep speaker volume very low because WSA speaker-amplifier safety operating
   area configuration is incomplete on Linux.

The warning is material: jglathe explicitly notes that damaging speaker/amp
hardware is possible, and cites a case where mixer experimentation caused
hardware damage and constant power drain.

References:

- dwhinham Surface Pro 11 status table:
  <https://github.com/dwhinham/linux-surface-pro-11>
- dwhinham issue comment pointing to jglathe work:
  <https://github.com/dwhinham/linux-surface-pro-11/issues/12#issuecomment-4011158877>
- jglathe SP11/SP12 discussion:
  <https://github.com/jglathe/linux_ms_dev_kit/discussions/57>
- jglathe Snapdragon X audio setup notes:
  <https://github.com/jglathe/linux_ms_dev_kit/wiki/Enabling-sound-on-the-HP-Omnibook-X14,-Lenovo-Thinkbook-16>
- AudioReach topology project:
  <https://github.com/linux-msm/audioreach-topology>

### No Confirmed Topology-Less Fallback

The checked upstream AudioReach topology loader returns the
`request_firmware()` error when `{card->name}-tplg.bin` is missing. The Qualcomm
common sound-card parser handles DT links, widgets, routes, and aux devices,
but it does not provide an obvious "topology missing, continue with simple DAI
routing" fallback for this AudioReach card.

A kernel patch to make topology optional is possible as an experiment, but it
should be treated as a third research track, not as known existing behavior. If
attempted, it must prove that the resulting card has usable controls/routes and
does not allow unsafe speaker amplifier states.

## Decision

The topology is required. There is no kernel fallback. The CRD M4 template is
already used as the single source for Romulus, EVK, TUXEDO, HP, Lenovo, ASUS,
and Dell X1E80100 topologies. The SP11 DTS has the same DAI-link structure as
Romulus (WSA_CODEC_DMA_RX_0 + VA_CODEC_DMA_TX_0). CRD is the safest starting
point.

### Track A — Immediate: Build SP11 Topology from CRD M4 Template

1. Clone `linux-msm/audioreach-topology`
2. Add entry to `CMakeLists.txt`:
   `"X1E80100-CRD;X1E80100-Microsoft-Surface-Pro-11;qcom/x1e80100;"`
3. Build: `mkdir build && cd build && cmake .. && make`
4. Install: copy `X1E80100-Microsoft-Surface-Pro-11-tplg.bin` to
   `/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`
5. Reboot, check `dmesg` for card instantiation
6. Low-volume test: set volume to 10%, play a short clip via PipeWire, watch
   dmesg for WSA errors
7. Validate: `wpctl status` should show WSA sink (not Dummy Output),
   headphones/DSP/HDMI paths may appear in topology but remain unroutable
   without corresponding DTS DAI links

Safety gates (mandatory):
- **Speaker volume at 10% maximum** for first playback
- **No `alsamixer`** exploration of WSA/PA gain controls
- Capture full `dmesg`, `wpctl status` (before + after), `aplay -l` state
- Stop **immediately** on: distortion, heat, abnormal battery drain (~>1W
  delta), or WSA overcurrent/temperature kernel warnings
- Preferred first path: headphones (if RX_CODEC_DMA_RX_0 enumerates and works)
  since headphones bypass WSA speaker amplifiers

### Track B — Medium-Term: Proper Dual-WSA Topology + UCM

After Track A confirms basic audio pipeline works:

1. Add WSA_CODEC_DMA_RX_1 DAI link to DTS to drive the second WSA macro
   (tweeters)
2. Create an M4 topology template with both WSA_RX_0 and WSA_RX_1 device
   subgraphs
3. Add crossover routing in topology (low-pass → WSA_RX_0/woofers,
   high-pass → WSA_RX_1/tweeters)
4. Install matching UCM profiles in `/usr/share/alsa/ucm2/conf.d/`
5. Implement speaker protection (temperature/voltage/excursion limits) via
   ALSA controls

### Track A.1 — PipeWire Stop-Gap and UCM Debugging

Before changing DTS or topology again, keep the proven ALSA path available to
desktop apps:

1. Use `scripts/sp11-pipewire-speaker-sink.sh --install --enable-route` to
   create a user-level PipeWire sink that wraps `hw:X1E80100Microso,1`
   directly.
2. Keep the config removable and local to the user; it is not a replacement for
   a correct UCM profile.
3. Collect `pactl list cards`, `wpctl status`, `wpctl inspect`, and
   `alsaucm` output after reboot to distinguish a UCM match failure from ACP
   refusing to auto-select the loaded UCM profile.
4. Do not proceed to headphone or second-WSA DTS work until the current speaker
   path can be selected from PipeWire or the manual-sink workaround is confirmed
   reliable.

### Track C — Research: Skip-Topology Kernel Patch

Not recommended as primary path. The verified code confirms topology load is
unconditional. A prototype patch would need to:
- Skip `audioreach_tplg_init` return if file not found
- Prove DAPM routes/controls are usable without topology
- Not expose unsafe speaker states

This is strictly experimental and not for daily use.

## Consequences

### Positive

- CRD-derived topology is the same basis used by 10+ other X1E80100 devices
  (Romulus/SL7, EVK, HP, Lenovo, ASUS, Dell, TUXEDO) — proven path
- Machine driver's card-level WSA volume limits (-3 dB digital, minimal PA
  gain) apply regardless of topology — partial hardware protection is already
  in the kernel
- Headphone output (RX_CODEC_DMA_RX_0) could work immediately if the CRD
  topology DSP graph connects even without an explicit DAI link in the DTS
- The `audioreach-topology` CMake build is a standard, reproducible toolchain
  (M4 → C header → compiled topology binary)

### Negative

- Only one WSA macro will be driven (WSA_CODEC_DMA_RX_0) — stereo via a single
  macro's 2-channel output, not the full 4-speaker (woofer+tweeter per channel)
  setup
- Headphone/mic/DisplayPort DSP graphs in the CRD topology will exist but may
  be unroutable without corresponding DAI links in the DTS
- Internal speaker testing carries real electrical risk: WSA884x smart
  amplifiers can overdrive speakers if gain staging is wrong

### Neutral

- Bluetooth/HDMI-DP audio are separate transports unaffected by this work
- PipeWire UCM profile auto-detection depends on card name matching — the
  SP11 card now has a matching profile, but ACP still reports
  `auto-profile = false` and does not create a sink. Manual PipeWire ALSA
  wrapping is the lowest-risk desktop stop-gap.
