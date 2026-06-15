# Surface Pro 11 Right Speaker Diagnostic Test - 2026-06-15

## Context

After the audio topology was built and the card instantiated (ADR-0033 Track A),
`speaker-test` on the 4-channel PCM `hw:0,1` produced audio from the left
speaker but not the right. This test session diagnosed the silence and narrowed
the likely causes.

Before the test, the known state was:

| Check | Result |
| --- | --- |
| Kernel | `7.0.0-22-qcom-x1e` patched with audio DAI links |
| Sound card | Card0 `X1E80100Microso` present, model `X1E80100-Microsoft-Surface-Pro-11` |
| Topology | Built from CRD template, installed as `qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin` |
| PCM devices | 6 playback PCMs (pcm0p-pcm5p), 2 capture PCMs (pcm2c-pcm3c) |
| Left speaker | ch0 (Front Left) and ch1 (Front Right per ALSA labels) produce audio |
| Right speaker | ch2 (Rear Left) and ch3 (Rear Right) silent |
| PipeWire | `Dummy Output` only — UCM auto-profile=false |
| PipeWire manual sink | 4ch PCM wrapped, channelmix downmixes to left-mono |

## Architecture Verified During Test

| Component | DTS prefix | Bus | Kernel device | Status |
| --- | --- | --- | --- | --- |
| WSA macro 6b00000.codec | `WSA` | soundwire@6b10000 (`okay`) | Yes | Active, drives bus |
| WSA macro 6aa0000.codec | `WSA2` | soundwire@6ab0000 (`disabled`) | Yes (idle) | Bound, no SDW consumers |
| SoundWire master | — | sdw-master-1-0 | Yes | Active |
| Left WSA884x amp | `SpkrLeft` | sdw:1:0:0217:0204:00:0 | Yes | Attached |
| Right WSA884x amp | `SpkrRight` | sdw:1:0:0217:0204:00:1 | Yes | Attached |

Both WSA884x speaker amplifiers share the **same** SoundWire bus (`6b10000`),
driven by the **single** active WSA macro (`6b00000`, prefix `WSA`). The second
macro (`6aa0000`, prefix `WSA2`) is bound to the driver but `soundwire@6ab0000`
is `status = "disabled"` in DTS — it drives nothing.

### amixer controls snapshot

36 `WSA`-prefixed controls exist (from 6b00000). 16 `SpkrLeft`/`SpkrRight`
controls exist (from the WSA884x amps). No `WSA2`-prefixed controls exist,
consistent with `soundwire@6ab0000` being disabled.

Full control list and `amixer contents` were captured to local files
(`data/audio/2026-06-15-amixer-controls.txt` and
`data/audio/2026-06-15-amixer-contents.txt`). These captures are not included
in the repository.

### ALSA device list

```text
card 0: X1E80100Microso [X1E80100-Microsoft-Surface-Pro-], device 0: MultiMedia1 Playback (*) []
card 0: X1E80100Microso [X1E80100-Microsoft-Surface-Pro-], device 1: MultiMedia2 Playback (*) []
```

See local capture `data/audio/2026-06-15-aplay-l.txt` (not in repository).

## Preamble

PipeWire was stopped before every raw ALSA test:

```bash
systemctl --user stop pipewire.service pipewire.socket \
  pipewire-pulse.service pipewire-pulse.socket wireplumber.service
rm -f ~/.config/pipewire/pipewire.conf.d/50-sp11-speakers.conf
```

DMA routing was enabled before each speaker-test:

```bash
amixer -c0 cset numid=68 'on'   # WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2
```

Volume was kept at safe levels for left speaker (`SpkrLeft PA Volume` = 12).
Right speaker volume was boosted to 31 during isolation tests.

Raw kernel messages were captured with `dmesg` filtered for `wsa`, `soundwire`,
`asoc`, `dapm`, `component`, `widget`. See local capture
`data/audio/2026-06-15-dmesg-audio.txt` (not in repository).

## Test

### 1. Channel sweep via `speaker-test` (4ch, hw:0,1)

```bash
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -l 1
```

ALSA labels reported: `0 - Front Left` (ch0), `1 - Front Right` (ch1),
`2 - Rear Left` (ch2), `3 - Rear Right` (ch3).

**Result:** ch0 = heard from left. ch1 = heard from left. ch2 = silent. ch3 = silent.

Note: ALSA channel label `Front Right` for ch1 is misleading — the tone comes
from the left physical speaker. The labels come from the CRD topology, not from
verified speaker-to-channel mapping.

### 2. Per-channel isolation

```bash
for ch in 0 1 2 3; do
  echo "=== CH $ch ==="
  speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 440 -s $ch -l 1
done
```

| Channel | ALSA label | Heard from |
| --- | --- | --- |
| ch0 | Front Left | Left speaker |
| ch1 | Front Right | Left speaker |
| ch2 | Rear Left | Silent |
| ch3 | Rear Right | Silent |

### 3. Two-channel PCM test (hw:0,0, MultiMedia1)

```bash
amixer -c0 cset numid=69 'on'   # WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1
speaker-test -D hw:X1E80100Microso,0 -c 2 -t sine -f 800 -l 2
```

`0 - Front Left` = heard from left. `1 - Front Right` = silent.

### 4. DMA routing control investigation

The `WSA_CODEC_DMA_RX_0` mixer has `values=2` (two enable bits):

| numid | Name | Path gated |
| --- | --- | --- |
| 68 | MultiMedia2 (4ch PCM) | Bit 0=left, Bit 1=right |
| 69 | MultiMedia1 (2ch PCM) | Bit 0=left, Bit 1=right |

Both controls show `on,off` — left path on, right path off.

Attempting to force both on fails silently:

```bash
amixer -c0 cset numid=68 'on,on'
# Still shows: values=on,off
amixer -c0 cset numid=68 1,1
# Still shows: values=on,off
```

The second bit is gated by DAPM and never transitions to powered state.

### 5. Amplifier control parity check

All `SpkrRight` controls can be set and mirror `SpkrLeft` values:

```bash
amixer -c0 cset name='SpkrRight PBR Switch' on
amixer -c0 cset name='SpkrRight PA Volume' 12
amixer -c0 cset name='SpkrRight DAC Switch' on
amixer -c0 cset name='SpkrRight BOOST Switch' on
amixer -c0 cset name='SpkrRight COMP Switch' on
```

Confirmed: `SpkrRight` controls are writable and report back the set values.
See local capture `data/audio/2026-06-15-spkrright-amixer-state.txt` (not in
repository).

### 6. Isolation: right speaker at max, left muted

```bash
amixer -c0 cset name='SpkrLeft PA Volume' 0
amixer -c0 cset name='SpkrRight PA Volume' 31
amixer -c0 cset name='SpkrRight PBR Switch' on
speaker-test -D hw:X1E80100Microso,1 -c 4 -t sine -f 1000 -s 2 -l 3
```

**Result:** Silent. The right WSA884x amplifier appears enabled and unmuted but
the observation is consistent with no digital audio stream reaching it. Not
proven without `dp*_sink`, topology decompile, or register evidence.

### 7. WSA macro and SoundWire topology verification

```bash
# DTS prefix
cat /sys/firmware/devicetree/base/soc@0/codec@6aa0000/sound-name-prefix  # "WSA2"
cat /sys/firmware/devicetree/base/soc@0/codec@6b00000/sound-name-prefix  # "WSA"

# SoundWire bus status
cat /sys/firmware/devicetree/base/soc@0/soundwire@6ab0000/status  # "disabled"
cat /sys/firmware/devicetree/base/soc@0/soundwire@6b10000/status  # "okay"

# Kernel devices
ls /sys/devices/platform/soc@0/ | grep '6b[01]'
# 6b00000.codec  ← WSA macro
# 6b10000.soundwire  ← active bus
# (no 6ab0000.soundwire)

# SoundWire slaves
ls /sys/bus/soundwire/devices/
# sdw-master-1-0  sdw:1:0:0217:0204:00:0  sdw:1:0:0217:0204:00:1

# SoundWire consumer links
readlink /sys/devices/platform/soc@0/6b00000.codec/consumer:*
# → platform:6b10000.soundwire  (6b00000 drives bus 1)

ls /sys/devices/platform/soc@0/6aa0000.codec/ | grep consumer
# (none — 6aa0000 drives nothing)
```

See local capture `data/audio/2026-06-15-soundwire-topology.txt` (not in
repository).

### 8. Kernel warning on every boot

```text
wsa_macro 6b00000.codec: using zero-initialized flat cache,
                          this may cause unexpected behavior
snd-x1e80100 sound: ASoC: Parent card not yet available,
                    widget card binding deferred
```

The warning is on 6b00000 — the active macro that drives the SoundWire bus and
whose ch0+ch1 work. The ASoC deferred binding message is not separately
attributed; it is part of the normal card assembly sequence.

### 9. Unbind/rebind attempt (failed)

```bash
echo -n 6b00000.codec | sudo tee /sys/bus/platform/drivers/wsa_macro/unbind
# Card 0 disappears

echo -n 6b00000.codec | sudo tee /sys/bus/platform/drivers/wsa_macro/bind
# File exists (os error 17)

dmesg:
wsa_macro 6b00000.codec: Unbalanced pm_runtime_enable!
wsa_macro 6b00000.codec: error -EEXIST: failed to register clk 'mclk'
wsa_macro 6b00000.codec: probe with driver wsa_macro failed with error -17
```

The clock provider is not unregistered on driver unbind, causing the second
probe to fail. Card was restored by reboot.

### 10. Temperature sensors absent

```bash
cat /sys/class/hwmon/hwmon*/temp1_input
# (empty — neither WSA884x amp reports temperature)
```

This suggests the WSA884x amps may not be fully initialized at the hardware
level, even though they are `Attached` on the SoundWire bus.

## Result

The **right speaker produces no audio**, which correlates with the second DMA RX
bit (path to ch2+ch3) staying off — DAPM never transitions it to powered state.
The right WSA884x amplifier is on the SoundWire bus and its controls respond,
but the observation is consistent with no digital audio stream reaching it.
Neither conclusion is proven without `dp*_sink`, topology decompile, DAPM
debugfs, or register evidence.

The left speaker works (ch0+ch1 produce audio from the left physical speaker).

## Limitations of this test

The following data sources were not available and would strengthen the diagnosis:

| Missing data | Why it matters |
| --- | --- |
| `/sys/kernel/debug/asoc/*` | Empty — no `components`, `codecs`, `dapm` entries. Cannot verify which DAPM widgets are in the card graph. |
| `/sys/kernel/debug/regmap/*` | Not checked. Would show cached vs hardware register values to confirm/refute the regcache hypothesis. |
| Topology decompile (`alsatplg -d`) | Not performed. Would show whether the CRD topology defines endpoints for both WSA speakers. |
| SoundWire `dp*_sink` values | Not captured. Would show which data port each WSA884x amp listens on. |
| WSA884x register dump | Not captured. Would show whether the right amp received bootstrap writes. |

## Workaround applied

The `sp11-pipewire-speaker-sink.sh` script was updated to:

- Use the 4-channel PCM `hw:X1E80100Microso,1` (MultiMedia2)
- Apply channelmix matrix `[ 0.5 0.5, 0.5 0.5, 0.0 0.0, 0.0 0.0 ]` — sums
  stereo L+R to left-mono on ch0+ch1, zeroes ch2+ch3
- Pre-set all WSA and right speaker amplifier controls (no-op on current kernel,
  ready for when the kernel fix lands)

The sink appears as "Surface Pro 11 Speakers" and produces audio from the
left speaker. Full stereo content is preserved in mono.

## Interpretation

The right speaker silence is a kernel-level issue. Hypotheses, in rough order
of likelihood:

1. **Topology or SoundWire port mapping** — the CRD-derived topology may not
   define the correct port mapping from DMA channels to SoundWire data ports for
   the second speaker. The wsa-dai-link codec phandles reference both amplifiers
   (`speaker@0,0` and `speaker@0,1`), but the internal routing may be incomplete.

2. **Regmap cache corruption** — the flat cache warning is on the active macro.
   It may corrupt registers controlling the right-channel DAPM path or the
   second DMA RX enable bit, while leaving the left channel functional.

3. **Bootstrap sequence** — the WSA884x driver may not fully initialize the
   second amplifier (no temperature sensor readings observed for either amp).

See [ADR-0034](../adr/adr-0034-wsa2-regcache-right-speaker.md) for the full
hypothesis breakdown with investigation steps.

## Next Steps

1. Decompile the topology binary (`alsatplg -d`) and inspect WSA speaker
   endpoint definitions.
2. Compare SoundWire `dp*_sink` entries between the two WSA884x devices.
3. Read WSA macro registers via `/sys/kernel/debug/regmap` to check cached vs
   hardware values for the DMA RX enable and SoundWire port control registers.
4. Test with `REGCACHE_NONE` kernel patch to isolate regmap from hypothesis.
5. If topology or port mapping is the cause, generate a corrected `.tplg.bin`.
6. Once right speaker works, change PipeWire matrix to route stereo to both sides.
