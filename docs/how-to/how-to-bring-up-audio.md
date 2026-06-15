# How to Bring Up Audio on Surface Pro 11

Last updated: 2026-06-15

## Prerequisites

- [x] SP11 kernel patched with DTB audio DAI links (`wsa-dai-link`, `va-dai-link`)
- [x] ADSP/CDSP firmware in place (`qcadsp8380.mbn`, `qccdsp8380.mbn`)
- [x] Audio firmware copied from Windows / linux-firmware

## Status (2026-06-15)

| Audio path | Status | Notes |
|---|---|---|
| Sound card (ALSA) | Working | `x1e80100` card instantiates with topology |
| Speaker (WSA884x) | Working (left only) | 4-channel PCM via WSA_CODEC_DMA_RX_0. Left woofer+tweeter (ch0+ch1) work. Right speaker (ch2+ch3) silent — suspected topology/SoundWire port mapping or regmap issue. See [ADR-0034](../adr/adr-0034-wsa2-regcache-right-speaker.md). |
| PipeWire integration | Partial | Card detected but manual sink config needed |
| Headphone (WCD939x RX) | Untested | RX_CODEC not in current DTS DAI links |
| Microphone (WCD939x TX) | Untested | TX_CODEC not in current DTS DAI links |
| HDMI/DisplayPort audio | Untested | DP DAI links not in current DTS |
| Bluetooth audio | Working | Independent of card topology |

## Quick Start: Build and Install Topology

### 1. Build the topology

```bash
./scripts/sp11-audio-topology.sh
```

### 2. Install (needs sudo)

```bash
sudo ./scripts/sp11-audio-topology.sh --install
```

### 3. Reboot

The topology is loaded by the AudioReach DSP at card probe time (boot). Reboot
is required after first install.

### 4. Test with ALSA directly

```bash
# Check card appeared
cat /proc/asound/cards
aplay -l

# Enable WSA DSP route
amixer -c0 cset numid=68 'on'

# Low-volume sine test (4 channels = 2x stereo WSA)
speaker-test -D hw:0,1 -c 4 -t sine -f 440 -l 3
```

**SAFETY**: Keep volume low (`SpkrLeft PA Volume`, `SpkrRight PA Volume`). The
machine driver limits these to 6/31 (1.4 dB gain at index 6), but verify with:

```bash
amixer -c0 cget numid=1   # SpkrLeft PA Volume
amixer -c0 cget numid=9   # SpkrRight PA Volume
```

### 5. PipeWire workaround

If PipeWire shows only `Dummy Output` after reboot, install the user-level
manual speaker sink:

```bash
./scripts/sp11-pipewire-speaker-sink.sh --install --enable-route
wpctl status
./scripts/troubleshoot-sp11-audio.sh > sp11-audio-after-manual-sink.txt
```

This writes
`~/.config/pipewire/pipewire.conf.d/50-sp11-speakers.conf`, wraps the verified
ALSA speaker PCM (`hw:X1E80100Microso,1`), applies a channelmix matrix that
sums stereo to mono on the audible left channels (ch0+ch1), and restarts the
user PipeWire services. The right speaker (ch2+ch3) is silent at the kernel
level. The matrix ensures no stereo content is lost. It is a stop-gap, not the
final UCM fix. Remove it with:

```bash
./scripts/sp11-pipewire-speaker-sink.sh --remove
```

## How It Works

### The Missing File

The X1E80100 AudioReach DSP requires a *topology graph* (`.tplg.bin`) that
describes the audio routing between frontend PCMs (MultiMedia1-6) and backend
DAIs (WSA_CODEC_DMA_RX_0, VA_CODEC_DMA_TX_0, etc.).

The file name is constructed as:

```
qcom/{driver_name}/{card_name}-tplg.bin
```

For Surface Pro 11:
- `driver_name` = `x1e80100` (from machine driver)
- `card_name` = `X1E80100-Microsoft-Surface-Pro-11` (from DTS `model` property)

Result: `qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin`

### Topology Generation

The topology is built from the `X1E80100-CRD.m4` template in
[linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology):

1. `m4` macro processor expands the `.m4` template → `.conf` text description
2. `alsatplg` (from alsa-utils) compiles `.conf` → `.tplg.bin` binary topology

The CRD template is the same source used for 10+ other X1E80100 devices
including Romulus (Surface Laptop 7). It provides:
- WSA_CODEC_DMA_RX_0 (4-channel: woofer + tweeter per channel)
- VA_CODEC_DMA_TX_0 (voice-activation microphone array)
- TX_CODEC_DMA_TX_3 (WCD939x headset mic — unused by current DTS)
- RX_CODEC_DMA_RX_0 (WCD939x headphone — unused by current DTS)
- DISPLAY_PORT_RX_0-7 (HDMI/DP audio — unused by current DTS)

### ALSA UCM Integration

The UCM profile (`/usr/share/alsa/ucm2/`) is configured via DMI-based regex
matching in `conf.d/x1e80100/x1e80100.conf`. The Surface Pro 11 DMI string
(`Microsoft Corporation-Surface-Microsoft Surface Pro, 11th Edition`) is matched
and loads the Surface-specific UCM config.

Currently the UCM profile is loaded but PipeWire's ACP module does not
auto-select it. This is a known issue with PipeWire 1.6.2 / WirePlumber 0.5.13
on AudioReach cards. The manual speaker sink bypasses ACP/UCM profile selection
and opens the verified ALSA PCM directly while the UCM auto-profile issue is
investigated.

## Troubleshooting

### Card not appearing in /proc/asound/cards

```bash
dmesg | grep -i 'tplg\|snd-x1e'
# Expected: no topology load error
# If error: verify topology file exists at /lib/firmware/qcom/x1e80100/
```

### speaker-test fails with "Invalid argument"

```bash
# Check if DSP mixer route is enabled
amixer -c0 cget numid=68
# If "values=off", enable it:
amixer -c0 cset numid=68 'on'
```

### WSA warning in dmesg

```
wsa_macro 6b00000.codec: using zero-initialized flat cache
```

This warning is on the active WSA macro (6b00000, prefix `WSA`) that drives
the SoundWire bus. It indicates the regmap cache started with all-zero values
on one or more reads. The left speaker (ch0+ch1) works despite this warning.
The right speaker (ch2+ch3) remains silent — the warning is one of several
hypotheses for why. See [ADR-0034](../adr/adr-0034-wsa2-regcache-right-speaker.md).

### No sound from speakers

1. Verify `Speakers` app volume is not muted in GNOME Settings
2. Check mixer levels: `amixer -c0 contents | grep -A2 'PA Volume'`
3. The 4-channel PCM requires a 4-channel test signal; 2-channel playback
   will fail on `hw:0,1`

## References

- ADR: [adr-0033-audio-topology-gap.md](../adr/adr-0033-audio-topology-gap.md)
- Script: [sp11-audio-topology.sh](../../scripts/sp11-audio-topology.sh)
- Source: [linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology)
- UCM configs: `/usr/share/alsa/ucm2/Qualcomm/x1e80100/`
- PipeWire UCM issue: see ADR-0033 for tracking and workarounds
