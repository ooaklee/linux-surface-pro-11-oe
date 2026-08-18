---
id: adr-0055-audio-volume-taper-log-db
title: "ADR0055: Log-dB Speaker Volume Taper"
# prettier-ignore
description: Architecture Decision Record (ADR) for replacing the PulseAudio cubic volume taper with a log-dB curve on the Surface Pro 11 speaker sink.
---

# ADR0055: Log-dB Speaker Volume Taper

## Status

Accepted (2026-08-17).

## Context

The speaker volume slider felt wrong on both ends:

- At 15% the output sounded like roughly 3%.
- At 100% the output sounded like 75-80%.

Measurement showed the cause is the PulseAudio-compatible **cubic volume
taper**. Both KDE Plasma (`plasma-pa`) and `pactl` (via `libpulse`) convert a
slider percentage `p` to a linear gain using `gain = p^3`:

| Slider | Applied gain | dB     |
|--------|--------------|--------|
| 15%    | 0.0034       | -49.4  |
| 50%    | 0.125        | -18.1  |
| 75%    | 0.42         | -7.5   |
| 100%   | 1.0          | 0.0    |

Verified empirically on the SP11 concept build (PipeWire 1.6.2, pulse compat):

- `pactl set-sink-volume ... 15%` -> node `channelVolumes` = `0.003375`
  (= 0.15^3, -49.4 dB).
- KDE volume OSD at 50% -> node `channelVolumes` = `0.125` (= 0.5^3).

The pipewire-pulse server stores the client-supplied linear value verbatim as
the SPA `channelVolumes`; it applies no curve of its own. The taper is
therefore applied entirely client-side, in `libpulse`
(`pa_sw_volume_from_percent`) and in KDE's own volume math in `plasma-pa`.
This is stock PulseAudio behavior, not Surface-specific, but the low end is
too steep for this speaker setup and the top end is compressed (75% vs 100%
differs by only 7.5 dB), matching the user report.

## Decision

Replace the cubic taper with a **log-dB curve**: the slider position maps
linearly to dB, with a 40 dB usable range.

    dB(p) = -40 * (1 - p)     (p in 0..1)
    gain(p) = 10^(dB(p) / 20)

| Slider | Applied gain | dB     |
|--------|--------------|--------|
| 15%    | 0.020        | -34.0  |
| 50%    | 0.100        | -20.0  |
| 75%    | 0.316        | -10.0  |
| 100%   | 1.000        | 0.0    |

Implementation location: the curve lives in the clients, so it must be
changed in both

1. `libpulse` (`pa_sw_volume_from_percent` and its inverse/display helpers),
   fixing `pactl`, `paplay`, and other libpulse clients; and
2. `plasma-pa` (KDE OSD) percent<->volume conversions, keeping the OSD
   percent and the applied gain consistent.

Both packages are carried in the concept image build, so this is two small
user-space package patches. A single-point pipewire-pulse server patch was
considered but rejected: it would have to assume every client used the cubic
curve (`percent = cbrt(received)`) and would desync the applied gain from the
OSD/pactl display.

## Consequences

- The 15% step becomes clearly audible (-34 dB) instead of a -49 dB whisper.
- The 100% step remains full-scale (0 dB).
- `pactl`/KDE OSD percentages now match perceived loudness.
- Requires rebuilding the `pulseaudio` (libpulse) and `plasma-pa` packages
  for the image and installing on the device.
- Other PulseAudio clients that link `libpulse` inherit the new taper.
- Any client implementing its own volume curve independently of libpulse
  (none currently in use) would diverge.
- The hardware gain staging is untouched; no PA-fault risk is reintroduced.
