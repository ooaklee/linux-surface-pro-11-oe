# How to Bring Up Audio on Surface Pro 11

Last updated: 2026-07-18

## Prerequisites

- [x] SP11 kernel patched with DTB audio DAI links (`wsa-dai-link`, `va-dai-link`)
- [x] ADSP/CDSP firmware in place (`qcadsp8380.mbn`, `qccdsp8380.mbn`)
- [x] Audio firmware copied from Windows / linux-firmware
- [x] Audio boot race fix applied (see [ADR-0035](../adr/adr-0035-audio-boot-race-alsactl.md))

## Status (2026-07-18)

| Audio path | Status | Notes |
|---|---|---|
| Sound card (ALSA) | Working | `x1e80100` card instantiates with topology |
| Speaker (WSA884x) | Working (both speakers, mono) | 4-channel PCM via WSA_CODEC_DMA_RX_0. Both speakers produce audio via PipeWire sink with reordered `audio.position` labels `[ FL RL FR RR ]` to bypass the kernel DAPM gate. See [ADR-0036](../adr/adr-0036-right-speaker-audio-position-reorder.md). |
| Audio boot race | Fixed | `alsa-restore.service` was restoring WSA mixer state before the DSP graph loaded, causing APM CMD timeout and SoundWire bus clash. Fixed by masking alsa-restore and using `sp11-wsa-routing.service`. See [ADR-0035](../adr/adr-0035-audio-boot-race-alsactl.md). |
| PipeWire integration | Partial | Card detected but manual sink config needed |
| Headphone (WCD939x RX) | Untested | RX_CODEC not in current DTS DAI links |
| Internal microphones (VA DMIC) | Working, slightly tinny | Corrected UCM opens the `Mic` device and records two-channel 48 kHz `S16_LE` audio from `hw:0,3`. Surface-specific 0 dB decoder gain avoids the clipping seen with the shared +16 dB default. The validated 2.4 MHz DMIC clock eliminates the continuous static heard at 4.8 MHz; capture remains slightly tinny or thin. See [ADR-0044](../adr/adr-0044-sp11-ucm-single-wsa-macro-microphone.md) and [ADR-0046](../adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md). |
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

### 4. Apply the audio boot race fix

`alsa-restore.service` restores WSA mixer state at boot before the AudioReach
DSP finishes loading the audio graph, causing an APM CMD timeout, SoundWire
bus clash, and no audio (only pops). The fix masks `alsa-restore.service` and
installs `sp11-wsa-routing.service` to enable WSA routing after the DSP graph
loads. See [ADR-0035](../adr/adr-0035-audio-boot-race-alsactl.md).

```bash
sudo ./scripts/sp11-fix-audio-boot-race.sh install
sudo reboot
```

After reboot, verify the DSP graph loaded cleanly:

```bash
# Should show no APM CMD timeout
sudo journalctl -b -k | grep 'CMD timeout'

# Should show no Bus clash
sudo dmesg | grep 'Bus clash'

# The WSA routing service should be active
systemctl status sp11-wsa-routing.service
```

### 5. Test with ALSA directly

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

### 6. PipeWire workaround

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

The Surface-specific profile must reference only the single WSA macro exposed
by the card. Older copies also enabled `Wsa2Speaker*` sequences; UCM aborted on
the missing `WSA2` controls before it could expose either `Speaker` or `Mic`.
The corrected profile removes those invalid sequences and declares two capture
channels. See [ADR-0044](../adr/adr-0044-sp11-ucm-single-wsa-macro-microphone.md).

The manual speaker sink remains necessary for the verified channel-position
workaround. It bypasses ACP/UCM for playback and opens the speaker PCM directly.

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
on one or more reads. Both speakers work despite this warning. The right
speaker was previously silent due to a DAPM gate, now worked around via
`audio.position` reorder. See [ADR-0034](../adr/adr-0034-wsa2-regcache-right-speaker.md)
and [ADR-0036](../adr/adr-0036-right-speaker-audio-position-reorder.md).

### No sound from speakers

1. Verify `Speakers` app volume is not muted in GNOME Settings
2. Check mixer levels: `amixer -c0 contents | grep -A2 'PA Volume'`
3. The 4-channel PCM requires a 4-channel test signal; 2-channel playback
   will fail on `hw:0,1`

### UCM exposes no microphone source

Check whether the `HiFi` verb opens and lists both devices:

```bash
alsaucm -c hw:0 set _verb HiFi list _devices
```

If this fails on a control beginning with `WSA2`, reinstall the repository's
Surface UCM profile. The Surface card exposes one WSA macro with two WSA8845
amplifiers; a second WSA macro sequence prevents the whole verb from loading.

After installation, verify direct capture before debugging PipeWire:

```bash
arecord -D hw:0,3 -f S16_LE -r 48000 -c 2 -d 5 sp11-mic-test.wav
```

If the card retained its old `off` profile from an earlier failed UCM load,
activate `HiFi` once and select the internal microphone source:

```bash
pactl set-card-profile alsa_card.platform-sound HiFi
wpctl status
wpctl set-default <internal-microphone-source-id>
```

### Microphone works but has constant static

This is the current known limitation. The standard PipeWire source and direct
ALSA capture both carry a persistent broadband static or scratching sound, and
volume controls show input activity in a quiet room.

Tests completed on the target device found:

- reducing `VA_DEC0 Volume` and `VA_DEC1 Volume` from +16 dB to 0 dB removed
  full-scale clipping and made speech clearer, but did not remove the static;
- DMIC0 was cleaner than DMIC1, while DMIC2 produced anomalous full-scale data
  and DMIC3 was silent;
- an 80 Hz high-pass plus 8 kHz low-pass filter improved measured noise and
  voice clarity, but the static remained clearly audible; and
- WebRTC noise suppression reduced the idle level but degraded speech quality
  substantially, so it is not enabled by default.

Do not interpret activity in a quiet room as proof that Firefox, PipeWire, or
the desktop portal is creating the noise. The same behavior is present in raw
ALSA capture.

The 2.4 MHz DMIC clock is now the validated Surface Pro 11 default. The
co-installable `7.1.3-jg-1dmic2p4-qcom-x1e` diagnostic kernel eliminated the continuous
feedback/static heard with 4.8 MHz, made recorded speech dramatically clearer,
and caused no audible degradation during music playback. Capture remains
slightly tinny or thin. The kernel uses a Stubble-provided device tree embedded
in the packaged image, so changing a loose DTB under `/boot` or the EFI System
Partition does not change the live tree. See
[ADR-0045](../adr/adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md) for the test
build and [ADR-0046](../adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for the
default-setting decision and device-side evidence.

For normal installation, use the
[`7.1.3-jg-1sp11v2` kernel release](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-1-v2)
with the
[`sp11-audio-topology-v2` assets](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-audio-topology-v2).
The v2 topology binary is unchanged from v1; v2 updates the UCM capture path to
match the single WSA macro, use two microphone channels, and apply unity
decoder gain. The kernel remains necessary because UCM changes alone do not
alter the Denali DMIC clock.

## References

- ADR: [adr-0033-audio-topology-gap.md](../adr/adr-0033-audio-topology-gap.md)
- ADR: [adr-0034-wsa2-regcache-right-speaker.md](../adr/adr-0034-wsa2-regcache-right-speaker.md)
- ADR: [adr-0035-audio-boot-race-alsactl.md](../adr/adr-0035-audio-boot-race-alsactl.md)
- ADR: [adr-0036-right-speaker-audio-position-reorder.md](../adr/adr-0036-right-speaker-audio-position-reorder.md)
- ADR: [adr-0044-sp11-ucm-single-wsa-macro-microphone.md](../adr/adr-0044-sp11-ucm-single-wsa-macro-microphone.md)
- ADR: [adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md](../adr/adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
- ADR: [adr-0046-sp11-default-2p4mhz-dmic-clock.md](../adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md)
- Script: [sp11-audio-topology.sh](../../scripts/sp11-audio-topology.sh)
- Script: [sp11-pipewire-speaker-sink.sh](../../scripts/sp11-pipewire-speaker-sink.sh)
- Script: [sp11-enable-wsa-routing.sh](../../scripts/sp11-enable-wsa-routing.sh)
- Script: [sp11-fix-audio-boot-race.sh](../../scripts/sp11-fix-audio-boot-race.sh)
- Source: [linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology)
- UCM configs: `/usr/share/alsa/ucm2/Qualcomm/x1e80100/`
- PipeWire UCM issue: see ADR-0033 for tracking and workarounds
