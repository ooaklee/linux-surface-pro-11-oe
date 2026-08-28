---
id: how-to-run-pen-via-iptsd-bridge
title: "Run the G6 Pen Through the IPTS DFT Bridge"
# prettier-ignore
description: How-to guide for running the Surface Pro 11 G6 pen through a transport bridge into alex-lentz/iptsd on Ubuntu.
---

# How To: Run the G6 Pen Through the IPTS DFT Bridge

Use this procedure when the Surface Pro 11 pen produces no input on the
patched qcom-x1e kernel and you want pen hover and click support through
the IPTS DFT pipeline instead of the retired `g6-pen` userspace approach
(ADR0059/ADR0060, superseded by this procedure).

## Purpose

The G6 panel never emits a native pen report (ADR0059). Windows synthesizes
pen input in software (`TouchPenProcessor0C83.dll`) from the proprietary
HEAT stream, and `g6-pen` reproduces that pipeline in a deliberately
fail-closed userspace daemon (ADR0059/ADR0060): hover and position are
validated, tap-to-click is deferred, and pressure, buttons, eraser, and
tilt stay gated.

This how-to documents a second path: a transport bridge into
[alex-lentz/iptsd](https://github.com/alex-lentz/iptsd) that maps the same
HEAT antenna data onto the IPTS DFT stylus model. The bridge reaches
0.21 to 0.48 mm median position error and contact F1 0.953 when scored
offline against the internal Windows processor capture evidence, with
no per-device calibration. It is experimental: the reported pressure
is a fixed click level and barrel, eraser, and tilt are not decoded.

The bridge works because the G6 HEAT antenna vectors share the 48-byte
layout of iptsd `dft::Row` (frequency, magnitude, 9 real + 9 imag
components, window tuple), and the HEAT stream carries IPTS-flavored
nested records (0x5F metadata, 0x5A selection, 0x5B magnitude, 0x5E
touched-antennas, 0x62 detection) around each 0x5C window. Region and
channel codes from payload bytes 5 and 9 match the Windows capture
taxonomy exactly.

## Prerequisites

- Touchscreen functional (ADR0041 patch set); `/dev/g6ts-heat` present.
- `g6-pen.service` stopped: the raw device permits a single reader.
- alex-lentz/iptsd at commit `3663e96` or later, with `meson`, `ninja`,
  and a native aarch64 toolchain.
- The P4, P5, and P8 HEAT corpora plus the Windows processor report
  export from the internal capture evidence kit, for offline validation
  (optional but recommended).

## Procedure

1. Build the bridge and tools.

```bash
git clone https://github.com/kyjus25/iptsd.git
cd iptsd
meson setup build -Dbuildtype=release -Ddebug_tools=calibrate,dump,perf
ninja -C build
```

2. Validate offline against the Windows reference before touching the
   device. Replay a corpus through the bridge and score the emitted
   stylus states against the Windows processor reports.

```bash
./build/src/iptsd-g6ts-replay P5-core.g6t > replay-P5.json
scripts/score-g6ts.py P5 replay-P5.json processor-pen-reports-P4-P8.csv
```

   Reference results from the P4/P5/P8 captures: contact F1 0.953 on the
   pressure scenario (196 TP, 12 FP, 17 FN), zero false contact on the
   hover-only corpora, contact-cycle position error median 0.21 mm, and
   hover position error median 0.38 to 0.48 mm.

3. Stop the single-reader `g6-pen` daemon, then run the bridge against
   the live digitizer.

```bash
sudo systemctl stop g6-pen.service
sudo ./build/src/iptsd-g6tsd
```

4. Confirm the virtual stylus exists and is classified as a tablet.

```bash
libinput list-devices | grep -A2 IPTSD
```

   Expected: an `IPTSD Virtual Stylus 045E:0C83` entry with
   `ID_INPUT_TABLET=1` and the 274 by 184 mm panel extents.

5. For daily use, install the binary and the packaged unit, then enable
   the service.

```bash
sudo cp build/src/iptsd-g6tsd /usr/local/bin/
sed 's|@bindir@|/usr/local/bin|' packaging/g6-pen.service.in \
  | sudo tee /etc/systemd/system/g6-pen.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now g6-pen.service
```

## Limitations

- The reported pressure is a fixed click level. The raw G6 pressure
  encoding is not decoded; antenna energy does not correlate with the
  Windows pressure value (r = 0.07 on the P5 corpus).
- Barrel button and eraser are not emitted. The P7 capture did not
  observe a barrel-button raw mapping and the 0x62 detection byte
  suggests the eraser path exists but is not decoded yet.
- The contact thresholds (on 3.2M, off 1.2M, two-cycle hysteresis) were
  calibrated on the P4/P5/P8 corpora. They are evidence-gated starting
  points in `src/core/generic/g6ts.hpp`, not tuned constants.
- The device permits one reader. The packaged
  `g6-pen.service` unit replaces the legacy `g6-pen` daemon unit of the
  same name and runs the bridge instead.

## References

- Issue [#35](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/35):
  validate alex-lentz/iptsd for the G6 digitizer, including the offline
  validation methodology and measured results.
- ADR0059 and ADR0060: the evidence-gated `g6-pen` design and the HEAT
  transport contract this bridge consumes.
- ADR0041: the touchscreen patch set that carries the HEAT stream.
