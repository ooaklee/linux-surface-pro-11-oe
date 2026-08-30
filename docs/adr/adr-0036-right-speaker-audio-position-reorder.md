---
id: adr-0036-right-speaker-audio-position-reorder
title: "ADR0036: Right Speaker Audio via PipeWire audio.position Reorder"
# prettier-ignore
description: Architecture Decision Record (ADR) for mapping PipeWire channels onto the Surface Pro 11 four-slot speaker PCM.
---

> **Current operator notice (2026-08-30):** The former PipeWire reorder and WSA
> helper commands below are retained as dated audio evidence, not current
> instructions. Use `userspace audio release prepare`,
> `userspace audio release validate`, `userspace install audio`, `doctor hardware audio`, and `clean`; see
> [CLI ADR019](../../cli/linux-armer/docs/adr/adr-019-native-audio-release-preparation.md).

# ADR0036: Right Speaker Audio via PipeWire audio.position Reorder

## Status

Accepted with corrected rationale (2026-08-16). The right speaker is physical
PCM slot 2, so PipeWire's `audio.position` reorder sends the right mix there.
It does not bypass DAPM. AudioReach's virtual-mixer getter/setter consumes only
control value zero; the displayed second `off` value is not an independent
right-channel gate. The historical interpretation below is retained as test
context. The current machine driver also caps both PA controls at raw 6
(0 dB), so the former raw-31 recommendation is invalid.

## Problem

The right speaker on the Surface Pro 11 was silent. The kernel's DAPM
framework in `lpass-wsa-macro.c` gates the right DMA RX path — the
`WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2` control's second bit (`Front
Right`) reads `off` and immediately flips back to `off` when forced on via
`amixer`. This prevents any audio signal from reaching the right WSA884x
amplifier through the normal DAPM power-up sequence.

See [ADR-0034](adr-0034-wsa2-regcache-right-speaker.md) for the full
investigation of the DAPM gate, regmap cache, and SoundWire port mapping
hypotheses.

## Discovery

During testing on 2026-06-19, raw `speaker-test -D hw:0,1 -c 4` occasionally
produced audio from the right speaker on ch2 (labeled `Rear Left` by ALSA).
This happened after a sound card rebind put the DSP in a non-standard state.
While the DAPM gate prevented the right DMA bit from being enabled through
`amixer`, the physical channel ch2 was still capable of carrying audio when
the DSP graph was in the right state.

The key insight: the DAPM gate is on the **mixer control** level
(`WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2` bit 1), not on the physical
SoundWire port. If PipeWire's channelmix can route signal to ch2 without
going through the gated mixer path, the right speaker will produce audio.

## Solution

Reorder PipeWire's `audio.position` labels in the speaker sink config from
the default `[ FL FR RL RR ]` to `[ FL RL FR RR ]`.

### How it works

With the default ordering `[ FL FR RL RR ]`:
- ch0 = FL (Front Left) → receives left input from mix-matrix
- ch1 = FR (Front Right) → receives right input from mix-matrix
- ch2 = RL (Rear Left) → receives nothing (zeroed in matrix)
- ch3 = RR (Rear Right) → receives nothing (zeroed in matrix)

The right physical speaker is on ch2. With the default labeling, ch2 is
`RL` and receives no signal. The right input goes to ch1 (`FR`), which is
DAPM-gated.

With the reordered labels `[ FL RL FR RR ]`:
- ch0 = FL (Front Left) → receives left+right sum from mix-matrix
- ch1 = RL (Rear Left) → receives nothing
- ch2 = FR (Front Right) → receives left+right sum from mix-matrix
- ch3 = RR (Rear Right) → receives nothing

By labeling ch2 as `FR`, PipeWire's channelmix routes signal to it. The
DAPM gate on the mixer control doesn't prevent this because PipeWire writes
directly to the PCM buffer — the signal reaches the physical channel
regardless of the mixer's DAPM state.

### Mix-matrix

```
channelmix.mix-matrix = "[ 0.5 0.5, 0.0 0.0, 0.5 0.5, 0.0 0.0 ]"
```

- ch0 (FL) = 0.5×Left + 0.5×Right → left speaker (mono sum)
- ch1 (RL) = silence
- ch2 (FR) = 0.5×Left + 0.5×Right → right speaker (mono sum)
- ch3 (RR) = silence

Both speakers receive the same mono-summed signal. True stereo is not
possible through this path because the DAPM gate prevents independent
left/right routing, but mono from both speakers is a significant improvement
over left-only.

### Right speaker PA Volume balance

The right WSA884x amplifier defaults to PA Volume 12/31 (9 dB), while the
left is at 31/31 (37.5 dB). The `sp11-enable-wsa-routing.sh` script sets
`SpkrRight PA` to 31/31 at boot to match the left speaker's volume.

## Configuration

The fix is in `scripts/sp11-pipewire-speaker-sink.sh`, which generates
`~/.config/pipewire/pipewire.conf.d/50-sp11-speakers.conf`:

```
audio.position         = [ FL RL FR RR ]
channelmix.mix-matrix  = "[ 0.5 0.5, 0.0 0.0, 0.5 0.5, 0.0 0.0 ]"
```

The PA Volume boost is in `scripts/sp11-enable-wsa-routing.sh`:

```bash
amixer -c "$CARD" sset 'SpkrRight PA' 31
```

## Verification (2026-06-19)

| Check | Result |
|---|---|
| Left speaker | Audio from ch0 (FL) — working |
| Right speaker | Audio from ch2 (FR) — working |
| Volume balance | Both speakers at PA Volume 31/31 — balanced |
| Reboot reliability | Verified across multiple reboots |
| DMA RX bit 1 (right) | Still reads `off` — DAPM gate not fixed at kernel level |
| `speaker-test -c 4` | Both speakers produce audio |

## Limitations

- Both speakers receive the same mono-summed signal — true stereo is not
  possible through this path without a kernel fix to the DAPM gate
- The DAPM gate root cause in `lpass-wsa-macro.c` remains unresolved
- If a future kernel update changes the DAPM behavior, the `audio.position`
  reorder may need adjustment
- The right speaker's PA Volume is set to maximum (31/31) — if this causes
  distortion at high volumes, it should be reduced

## Consequences

### Positive

- Both speakers produce audio — no longer left-only
- No kernel patch required — purely userspace PipeWire configuration
- Volume is balanced between speakers
- Persists across reboots via the WSA routing service

### Negative

- Output is mono, not stereo — both speakers receive the same summed signal
- The kernel DAPM gate is not fixed, just bypassed
- The `audio.position` reorder is non-obvious and may confuse future
  debugging if someone expects standard channel ordering

## References

- [ADR-0034](adr-0034-wsa2-regcache-right-speaker.md) — original right speaker silence investigation
- [ADR-0035](adr-0035-audio-boot-race-alsactl.md) — audio boot race fix
- `scripts/sp11-pipewire-speaker-sink.sh` — PipeWire sink config with reordered positions
- `scripts/sp11-enable-wsa-routing.sh` — WSA routing + PA Volume boost
- `sound/soc/codecs/lpass-wsa-macro.c` — kernel DAPM gate (unresolved)
