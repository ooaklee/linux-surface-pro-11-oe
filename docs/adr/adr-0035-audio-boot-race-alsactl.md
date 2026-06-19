---
id: adr-0035-audio-boot-race-alsactl
title: "ADR0035: Audio Boot Race — alsactl Restore vs AudioReach DSP Graph Load"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 audio boot race where alsactl restores WSA mixer state before the DSP finishes loading the audio graph, causing an APM CMD timeout, SoundWire bus clash, and no audio (only pops).
---

# ADR0035: Audio Boot Race — alsactl Restore vs AudioReach DSP Graph Load

## Status

Accepted — Fix verified working (2026-06-19). Left speaker audio restored
after masking `alsa-restore.service` and clearing WSA controls from
`asound.state`. A systemd service now enables WSA routing after the DSP
graph loads at boot.

## Problem

After the audio topology was installed and the left speaker was confirmed
working (2026-06-15, ADR-0033/ADR-0034), a regression occurred: the Surface
Pro 11 produced no audio except pops at boot. The symptoms were:

| Check | Result |
|---|---|
| APM CMD timeout | `qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode` at boot |
| SoundWire bus | `Bus clash detected` / `Reached MAX_RETRY on alert read` on both WSA884x amps |
| ALSA card | Instantiated with all WSA mixer controls present (36 WSA controls) |
| `speaker-test` | Ran without error on `hw:0,1` but produced no sound |
| PipeWire | Opened MultiMedia2 PCM, hit `snd_pcm_avail after recover: Broken pipe` continuously |

The `CMD timeout for [1001021]` is `APM_CMD_GRAPH_OPEN` — the AudioReach DSP
did not acknowledge the topology graph-open command. Without the graph, the
SoundWire bus comes up unconfigured, causing the bus clash. The pops are the
WSA884x PA (power amplifier) toggling on a dead bus.

## Root Cause

`alsa-restore.service` runs at boot and restores all ALSA mixer controls from
`/var/lib/alsa/asound.state`. The saved state contained:

```
WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2 = on    (DMA route enabled)
SpkrLeft DAC Switch = true                          (amplifier DAC on)
SpkrRight DAC Switch = true                         (amplifier DAC on)
SpkrLeft BOOST Switch = true                        (amplifier boost on)
SpkrRight BOOST Switch = true                       (amplifier boost on)
WSA WSA RX0 MUX = AIF1_PB                           (routing active)
WSA WSA RX1 MUX = AIF1_PB                           (routing active)
```

These values were saved during the 2026-06-15 testing session when the WSA
routing was manually enabled via `amixer`. At the next boot,
`alsa-restore.service` writes these values to the WSA macro registers
**at the same time** the AudioReach DSP is loading the audio graph:

```
23:54:16  qcom-apm: CMD timeout for [1001021] opcode    ← DSP graph-open FAILED
23:54:16  alsa-restore.service: Started + Finished       ← alsactl restore ran
23:54:16  wsa_macro: zero-initialized flat cache
23:54:36  wsa884x: Slave UNATTACHED                      ← SoundWire enumeration
23:54:36  SWR bus clsh detected                           ← Bus clash begins
```

The register writes from `alsactl` interfere with the DSP's graph
construction, causing the `APM_CMD_GRAPH_OPEN` to time out. The DSP never
sets up the SoundWire port configuration, so the bus comes up in a corrupted
state.

### Why the working state (2026-06-15) did not have this problem

During the 2026-06-15 testing session, the WSA routing was manually enabled
with `amixer -c0 cset numid=68 'on'` after the system had fully booted and
the DSP graph was already loaded. The `asound.state` at that time had WSA
controls in their default (disabled) state. After the manual enable, the
state was saved (by alsactl store or shutdown), and the "on" values
persisted into subsequent boots — triggering the race.

## Fix

### 1. Clear WSA controls from asound.state

Strip all WSA/Spkr control blocks from `/var/lib/alsa/asound.state` so they
default to their kernel-initialized state at boot. Non-WSA controls (VA mic,
etc.) are preserved.

### 2. Mask alsa-restore.service

Mask `alsa-restore.service` and `alsa-state.service` to prevent them from
racing the DSP at boot. The WSA routing is enabled separately after the DSP
graph loads (see step 3).

### 3. Enable WSA routing after DSP graph loads

Install `sp11-wsa-routing.service`, a systemd oneshot that:
1. Waits for the ALSA card to appear (up to 30s)
2. Waits for the WSA mixer controls to be available (up to 30s) — this only
   happens after the DSP graph has loaded
3. Enables the WSA DMA route and macro routing
4. Sets a safe default speaker volume

This runs `After=sound.target` and internally polls for the WSA controls,
ensuring it never races the DSP.

## Verification (2026-06-19)

| Check | Before fix | After fix |
|---|---|---|
| APM CMD timeout at boot | Present | **Gone** |
| SoundWire Bus clash | Continuous spam | **Gone** |
| Left speaker audio | No sound (pops only) | **Working** |
| `speaker-test hw:0,1` | No error, no sound | Works (when PCM not busy) |
| PipeWire | `Broken pipe` spam | Working with manual sink |

## Files

- `scripts/sp11-fix-audio-boot-race.sh` — diagnostic and fix script
- `scripts/sp11-enable-wsa-routing.sh` — WSA routing enable script (run by systemd)
- `scripts/systemd/sp11-wsa-routing.service` — systemd oneshot service
- `scripts/sp11-pipewire-speaker-sink.sh` — updated with boot race notes

## Consequences

### Positive

- Audio works reliably across reboots — no manual `amixer` commands needed
- The DSP graph loads cleanly without register-write interference
- The systemd service is self-healing: if the DSP takes longer to load, the
  script waits up to 30s for the WSA controls to appear

### Negative

- `alsa-restore.service` is masked system-wide — other audio controls (VA mic
  gain, etc.) are not restored at boot. This is acceptable because:
  - The VA mic controls default to safe values
  - The WSA routing is handled by `sp11-wsa-routing.service`
  - PipeWire/WirePlumber manages runtime volume state independently
- If the DSP graph fails to load for other reasons, the systemd service will
  time out after 30s and exit — the user must check dmesg for DSP errors

### Neutral

- The fix does not address the right speaker silence (ADR-0034) — that remains
  an unresolved kernel-level issue
- The PipeWire manual sink (`50-sp11-speakers.conf`) is still needed for
  desktop audio until the UCM auto-profile issue is resolved

## References

- [ADR-0033](adr-0033-audio-topology-gap.md) — topology gap (resolved)
- [ADR-0034](adr-0034-wsa2-regcache-right-speaker.md) — right speaker silence
- `scripts/sp11-fix-audio-boot-race.sh` — fix script
- `scripts/sp11-enable-wsa-routing.sh` — WSA routing enable script
- `scripts/systemd/sp11-wsa-routing.service` — systemd service
