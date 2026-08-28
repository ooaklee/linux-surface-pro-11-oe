---
id: adr-0065-sp11-front-camera-cphy-integration
title: "ADR0065: SP11 Front Camera C-PHY Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for integrating the Surface Pro 11 Sony IMX681 front camera using the hardware-proven 969.6 Msymbol/s C-PHY path, a single truthful sensor mode, reversible kernel packaging, and evidence-gated userspace enablement.
---

# ADR0065: SP11 Front Camera C-PHY Integration

## Status

Accepted for the `7.2.0-jg-0sp11v14` implementation milestone on 2026-08-28.
Kernel package, reboot, raw-capture, and userspace validation remain required
before the front camera is described as working on this device.

Amended later on 2026-08-28 after the first v14-ABI runtime investigation
reached the sensor's final `MODE_SELECT` write but produced no CSI packets.
The amendment records the compound-subdevice link-frequency fix, the fully
specified Linux clock tuple, and failure-path cleanup needed for the next
packaged experiment.

Amended again after booting the provenance-verified `0097c12b0fec` package.
The complete RAW10 graph and `VIDIOC_STREAMON` succeeded, but neither the
CSID0/VFE0 route nor the same-machine Windows-selected CSID1/VFE1 diagnostic
route completed a buffer. The next bounded package therefore matches the one
remaining CSID680 receiver-field delta from the same-machine Windows oracle
and exposes a packet-count diagnostic before userspace installation proceeds.

This decision supersedes the earlier local draft that treated a statically
decoded 1.2 Gsymbol/s Windows sensor mode as a half-rate value and doubled it
to 2.4 Gsymbol/s at the receiver. The 1.2 Gsymbol/s sensor configuration is
real package evidence, but it is a distinct 3840x2640 mode and is not the
current 3844x2640 Linux recipe. The doubled receiver interpretation was never
hardware-proven or committed.

## Context

The Surface Pro 11 OLED unit exposes a Sony IMX681 front camera at CCI/I2C
`1-0010`. The v13 kernel creates the device and CAMSS media controller, but CCS
does not bind. The boot journal reports:

```text
value 327680000 overflows!
no valid link frequencies for 10 bpp
no supported mbus code found
```

The integration branch already contains model-scoped IMX681 support, the
x1e80100 C-PHY receive path, CSID680/VFE680 fixes, the Denali device-tree
nodes, and in-code CCS limit overrides for both observed manufacturer IDs
(`0x4260` and `0x3b60`). A later change moved the endpoint to 1.2 GHz and made
CAMSS double it to 2.4 Gsymbol/s. That conflicts with the sensor mode table
and with the only complete hardware-proven Snapdragon implementation.

### Evidence and provenance

The decision deliberately separates four evidence classes.

1. **Direct evidence from this device's Windows capture**

   The private capture repository at commit `f35cbc4` directly establishes
   MCLK4 at 19.2 MHz, reset GPIO237, and the LDO7B 2.8 V and LDO3M 1.8 V
   resources. It also records a front-camera exposure capability of
   `5000..2000000` WinRT ticks in steps of 10 ticks, with automatic exposure
   available. WinRT ticks are 100 ns, so this is a 0.5 ms to 200 ms control
   range with a 1 microsecond step.

   The capture does **not** contain decoded CCI register transactions or
   active CAMSS/CSIPHY MMIO. It therefore does not directly prove the sensor
   PLL registers, C-PHY rate, CDR value, physical trio, exposure register, or
   gain register. Relevant audit files are:

   - `analysis/camera-integration-20260827/privileged-camera-followup.md`
   - `analysis/camera-integration-20260827/windows-control-capabilities.json`
   - `analysis/camera-integration-20260827/source-audit.md`
   - `windbg/31-camera-cci-register-writes-pending.md`
   - `windbg/32-camera-camss-mmio-dump.txt`

2. **Static Windows driver-package oracle from this device**

   `geocausa/SP11X1ECamera` at
   `41003427f47edd27cd98f846b4282327824ee16f` mechanically decodes files whose
   front sensor-module, power-resource, and platform-configuration hashes
   match this device's installed Windows files. Its mode 0 is a real static
   configuration for 3840x2640 RAW10 with analogue crop origin `(104, 256)`,
   line length 6752, frame length 3554, declared 30 fps, and PLL2 divider/
   multiplier bytes `03 01 77`. Under the same PLL interpretation used below,
   that is a 1.2 Gsymbol/s sensor-side mode, not a 2.4 Gsymbol/s receiver rate.

   This is configuration-package evidence, not a runtime CCI or CAMSS trace.
   It does not prove that Windows selected mode 0 on a given stream, nor does
   it establish receiver AFE/CDR values. Its declared 548.57 MHz output pixel
   clock also does not equal `6752 * 3554 * 30`, so it must not be copied into
   `V4L2_CID_PIXEL_RATE` without register-level timing correlation.

   The decoded front descriptor corroborates CCI1/master1/CSIPHY2, and the
   power map corroborates GPIO237, MCLK4 at 19.2 MHz, LDO3M at 1.8 V, and LDO7B
   at 2.8 V. The platform parser was developed against a different
   `qccamplatform8380.sys` revision, so these routing fields remain strong
   same-schema corroboration rather than a runtime trace from this exact
   platform-driver binary.

3. **Hardware-proven Snapdragon Linux reference**

   `karsies-wq/sp11-imx681-linux` at
   `b08f76f40b8d7b715bd4da6aef484f86142cc147` reports a complete front-camera
   path on the same platform family: CSIPHY2/trio0, the 1.0 Gsymbol/s AFE row,
   a clean CDR window from `0x46` through `0x4e`, CDR `0x4a`, and a
   3844x2640 RAW10 sensor stream cropped by CSID to 3840x2640. Its decisive
   line-length change is 7552 to 8704 pixels, avoiding receiver FIFO overflow.
   It demonstrates repeated raw capture and a libcamera/PipeWire/browser path.

   The mode table programs PLL2 with 19.2 MHz / 3 multiplied by 303, producing
   a 1.9392 GHz OP clock. The CCS link-frequency convention is half that clock:
   969.6 MHz. The generic x1e80100 PHY consumes the C-PHY symbol rate directly,
   so CAMSS must pass 969.6 MHz without another factor of two.

   The reference's reported approximately 17.5 microsecond line at LLP 7552,
   followed by about 13 percent headroom at LLP 8704, implies a 432 MHz VT
   clock. Its static-data notes also identify an OP pixel divider of zero as a
   broken fallback state and use divider 4 for the C-PHY calculation. Together
   these establish the derived complete Linux tuple below; the reference mode
   table itself only overwrites selected multiplier and pre-divider bytes, so
   the complete tuple must not be described as a byte-for-byte runtime trace.

4. **Intel IMX681 work**

   `linux-surface/linux-surface#2156` targets Intel IPU6 and a D-PHY receiver.
   It is useful for sensor-table provenance and corroborating the 969.6 MHz
   sensor configuration, but its receiver changes must not be cherry-picked
   into Qualcomm CAMSS. Its analogue-gain interpretation also conflicts with
   later Snapdragon measurements, where `0x0204` is ineffective and global
   U8.8 gain at `0x020e/0x020f` changes the image.

### Boot and deployment behavior

The qcom-x1e package uses stubble/UKI construction with auto-selected embedded
DTBs. Although GRUB contains a `devicetree /sp11-denali.dtb` directive, the
live tree does not match that loose file:

| Source | Link frequency |
| --- | ---: |
| Live `/proc/device-tree` | 1,000,000,000 |
| Loose `/boot/sp11-denali.dtb` | 1,200,000,000 |
| Corrected source/build DTB | 969,600,000 |

The installed kernel must therefore contain the corrected OLED DTB in its
embedded auto-DTB section. Copying only a loose DTB is not an acceptance test.
No deployment may copy another machine's full DTB or hard-code its Bluetooth
address.

## Decision

We will integrate the front camera as follows.

### Kernel data path

- Advertise `link-frequencies = /bits/ 64 <969600000>` on the IMX681 C-PHY
  endpoint.
- Pass that value directly as the C-PHY symbol rate in CAMSS.
- Select the x1e80100 1.0 Gsymbol/s C-PHY AFE table with CDR `0x4a` on all
  three table lanes. Runtime override value zero continues to mean "use the
  table default".
- Use CSIPHY2 with one C-PHY trio. Preserve D-PHY behavior for other cameras.
- Program CSID680's frame, pixel, and line drop engines to the same explicit
  keep-all state used by the generic CSID implementation: period 1, pattern 0.
- Decode the 3844-pixel RAW10 input, crop horizontally to 3840 pixels, and feed
  VFE680 RDI in MIPI_RAW mode. The resulting 4800-byte packed RAW10 line is
  naturally 16-byte aligned.

### Sensor and controls

- Expose only the hardware-proven 3844x2640 sensor mode. Remove the runtime
  `imx681_windows` switch and its incompatible 1.2 GHz table until genuine
  per-state mode selection also updates link frequency and control ranges.
- Keep the statically decoded Windows 3840x2640/1.2 Gsymbol/s mode as future
  work, not a replacement for the v14 acceptance candidate. If implemented,
  make it a distinct V4L2 mode with direct 1.2 Gsymbol/s PHY input, 3840-pixel
  sensor geometry (and therefore no 3844-to-3840 CSID crop), correlated pixel
  rate and control bounds, plus its own FIFO and repeated-stream validation.
- Keep the mode's line length at 8704 and frame length at 3177.
- Program all effective VT and OP branch dividers deterministically. Use VT
  pixel/system/pre/multiplier `5/1/2/225`, yielding 432 MHz, and OP
  pixel/system/pre/multiplier `4/1/3/303`, corresponding to the advertised
  969.6 Msymbol/s link. Leave `PLL_MODE` at the sensor default. Record
  432 MHz in the mode timing metadata used for exposure conversion.
- Expose one standard `V4L2_CID_ANALOGUE_GAIN` control with range `0..960`,
  step 1, and default 192. For this IMX681 only, map it to global U8.8 gain at
  `0x020e/0x020f` using `0x0100 + value * 4`; do not expose a duplicate digital
  gain control. This is the standard control driven by libcamera's simple IPA.
- Treat `0x0229..0x022b` as the measured 24-bit line-count exposure register.
  Convert the Windows control-domain bounds to sensor lines and start at the
  proven 3100-line integration value.
- Keep the in-code, model-scoped limits and vendor/mode tables. A missing
  `ccs-sensor-3b60-0681-0010.fw` warning is not a reason to rename or install
  the reference unit's `0x4260` static firmware blob.

### Compound graph and failed-stream lifecycle

- Resolve link frequency by walking upstream from the CAMSS video path and
  accepting the first transmitter source pad that exposes
  `V4L2_CID_LINK_FREQ`. The IMX681 CCS graph owns that control on its scaler,
  not on the entity classified as the pixel-array camera sensor.
- Apply IMX681 runtime-PM stream hooks only to the CCS source subdevice. The
  binner, scaler, and pixel-array callbacks describe one physical sensor and
  must not independently acquire or release its PM reference.
- If the sensor NACKs the standby write, record the error but still schedule
  runtime power-down and report the logical stop complete. This keeps the V4L2
  enabled-stream bitmap, driver stream mask, and PM state consistent.
- If an upstream subdevice fails to start, stop only the downstream CAMSS
  subdevices that started successfully before ending and flushing the media
  pipeline. Repeated failed opens must not leave receiver blocks active.
- On X1E80100 real-sensor C-PHY routes, retain `TPG_NUM_SEL=1` while leaving
  the TPG mux disabled. Together with C-PHY selection and CSIPHY2 selection,
  this changes CSID680 `RX_CFG0` from Linux's `0x01300000` to the repeated
  same-machine Windows value `0x11300000`. Keep D-PHY and active-TPG paths
  byte-identical.
- Report `RX_CFG0` and `TOTAL_PKTS` when the experimental C-PHY stream stops.
  A zero count localizes the failure to sensor/PHY/receiver ingress; a nonzero
  count with no completed V4L2 buffer moves the investigation downstream to
  CSID RDI/VFE completion.

### Privacy indicator

- Keep the GPIO225 indicator default-off and connect it to the sensor through
  `leds` / `led-names = "privacy"`. V4L2 core owns stream-time toggling.
- Extend the MIPI CCS binding to admit the common privacy LED and orientation
  properties. Remove the undeclared `clock-names` and deprecated duplicate
  `clock-frequency` properties; the assigned MCLK4 rate remains 19.2 MHz and
  CCS reads that rate from the clock provider.
- GPIO225 active-high is supported by the separate hardware-proven reference,
  but not by this device's Windows trace. Its on/off behavior remains a
  post-install hardware validation gate.

### Build and release

- Record all camera milestone changes in the existing
  `7.2.0-jg-0sp11v14` changelog entry.
- Build from the exact pushed integration-branch commit with the repository's
  qcom-x1e Docker build script, producing `binary-indep binary-qcom-x1e`.
- On a reused Docker source volume, refresh the requested branch or tag through
  an explicit destination ref and require the updated tracking ref to match
  `FETCH_HEAD`; an ambiguous fetch can otherwise leave a stale shallow ref.
- Install only artifacts whose package version and recorded source commit match
  the milestone. Do not use a wildcard copied from an earlier v13 build.
- Treat `sp11-kernel-build-manifest.txt` and its `Source HEAD` field as the
  package provenance authority. The persistent build volume contains an older
  v14 build with the same Debian version, so filenames alone cannot distinguish
  the corrected package.
- Prefer the coherent v14 package over overwriting v13 packaged modules. If a
  diagnostic v13 hotfix is needed, all CCS, CAMSS, and generic PHY modules must
  have an exact v13 vermagic and be installed reversibly under an `updates/`
  directory with a backed-up embedded DTB.

### Recorded source milestone

The reviewed source milestone consists of these signed commits on
`sp11/integration-7.2.x-ooaklee-karsies-wq-cams`:

- `4b47a0c09c8d9efb9872abe1cb10a03d28accbcc` — admit the inherited privacy
  LED and orientation properties in the MIPI CCS binding.
- `1592ec3774189f107d9267ffd65a71e841bccf1e` — restore the coherent IMX681
  sensor, CAMSS, C-PHY, device-tree, control, and v14 changelog path.
- `e0ce71102628902fa5281a2adcadc19b2d88d4f0` — preserve the reported Bayer
  layout across fixed-table programming and propagate the final sensor
  `MODE_SELECT` failure instead of reporting a false streaming success.
- `0097c12b0fec69b2d1aef031d4cd63fd78fd7a48` — resolve the compound CCS
  transmitter rate, program the complete derived Linux clock tuple, group the
  first-frame controls, and make failed stream attempts unwind cleanly.
- `ead11c748e4e8fb984412093be73d2228bd68e89` — match the X1E CSID680 C-PHY
  receiver field to same-machine Windows and expose stop-time receiver and
  packet-count evidence for the next raw gate.

The earlier `e0ce71102628` source passed local module/DTB builds, binding
validation, and strict checkpatch before packaging. Strict checkpatch also
passes the `0097c12b0fec` amendment.

The canonical remote package build completed successfully on 2026-08-28 in
33 minutes using `binary-indep binary-qcom-x1e` with ten jobs. Its manifest
reports source HEAD `0097c12b0fec69b2d1aef031d4cd63fd78fd7a48`, the requested
integration branch, and no local patches. The four copied packages all report
version `7.2.0-jg-0sp11v14` and the expected `arm64` or `all` architecture.
The modules package contains `ccs.ko.zst` and `qcom-camss.ko.zst`; both report
vermagic `7.2.0-jg-0sp11v14-qcom-x1e`, with source versions
`426DF2BB77E8D8D0F7BDAF8` and `2CE131610DCEBDD881BBC84` respectively.

Remote and local SHA-256 values matched after copying the build into the
ignored, source-qualified directory
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-0097c12b0fec/`:

- image: `cb6eeebe50cdbebdd532f007166e0f916a404cc634fae6fa23b96fd1d3ea2947`
- modules: `be840903aaa30871e9114c4b792bf89be26264fca0e902299e6c104e555d8e4e`
- flavour headers: `76481f3974f3b08351c35a8a89af8b957d4a12174d94bc52c1e9bad3d2c0f88b`
- common headers: `8db4fedfab45d4d96db344deb660cad29c8f0f923e5b519e46a4e041170497de`
- build manifest: `bad0d666d386e81613fd04c98c75c82350b72bec40e5f75dccbeda1e05915353`

No package was installed, no module was loaded, and no reboot was performed as
part of this build gate. The reused volume and unchanged Debian v14 version
still make filenames alone insufficient provenance; retain the manifest and
hashes with the packages.

### `0097c12b0fec` runtime result

The verified package booted as `7.2.0-jg-0sp11v14-qcom-x1e`; loaded CCS and
CAMSS source versions matched its manifest. The bounded raw validator then:

- negotiated `SRGGB10_1X10` at 3844x2640 from IMX681 through CSIPHY2 and the
  CSID sink;
- negotiated the 3840x2640 CSID crop, packed `pRAA`, 4800-byte stride, and
  12,672,000-byte V4L2 buffers through CSID0/VFE0 RDI0;
- completed buffer allocation, queueing, and `VIDIOC_STREAMON` successfully;
- completed zero buffers in 40 seconds and produced a zero-byte raw file;
- logged the 969.6 MHz C-PHY selection and no visible FIFO, violation, or
  truncation error, followed by the known best-effort standby NACK.

A separate 12-second diagnostic moved the same negotiated stream to the
same-machine Windows-selected CSID1/VFE1 RDI0 instances. It also completed
zero buffers. Both tests restored the CSID0/VFE0 links and PipeWire services.
The evidence is retained in the private runtime directories
`sp11-imx681-raw.83cIgrOU` and `sp11-imx681-csid1.5qyXQfiF` under the Codex
desktop temporary-state tree.

The same-machine Windows branch at `68b1b3124a799060316d58131fe3f1511bdfd335`
establishes `RX_CFG0=0x11300000`. Its exact 2.4-Gsymbol/s PHY table belongs to
a distinct 3840x2640, PLL2 `3/375`, 1.2-GHz-link sensor mode. Do not mix that
table with the current 3844x2640, PLL2 `3/303`, 969.6-Msymbol/s Linux mode.
Its IPP/VFE PIX patches also remain static and incomplete, so they are not part
of this bounded RDI transport experiment.

## Consequences

- The sensor, CAMSS, and generic PHY now use one consistent rate contract.
  The old 1.2 GHz doubled path, which selected the 2.35 Gsymbol/s table while
  the sensor emitted about 969.6 Msymbol/s, is removed.
- A genuine static Windows 1.2 Gsymbol/s mode is recorded separately. It does
  not rehabilitate the removed doubled-rate implementation or change the v14
  raw-capture gate.
- Userspace sees only a mode the driver will actually program. Adding further
  modes later requires proper V4L2 state, control-range, and link-frequency
  selection rather than another global module parameter.
- Auto-exposure can drive the standard gain and exposure controls used by the
  simple IPA, but convergence and image quality remain runtime gates. The
  fixed 3177-line frame limits the initial control range to about 64 ms even
  though Windows advertises up to 200 ms; longer exposure requires deliberate
  frame-length control rather than writing past the current frame.
- The privacy LED is managed by the media stack instead of a polling service.
  Incorrect polarity must be fixed in DT after hardware testing, not hidden by
  a permanently running GPIO script.
- The six explicit CSID drop-register writes are based on generic CSID behavior
  and the completed hardware reference. Windows traces do not independently
  establish them. Other CSID680 routes must be regression-tested.
- The v14 CSID680 path only unmasks register-update completion, while VFE680 RDI
  disables its interrupt masks. The raw validator can reject emitted camera
  errors and truncated buffers, but a quiet kernel log does not prove that
  hidden FIFO or image-violation status never occurred. Exact frame sizes,
  repeated streaming, and raw-image inspection remain separate evidence gates;
  add targeted IRQ instrumentation only if runtime symptoms justify it.
- `scripts/render-sp11-imx681-raw.py` renders the validator output according to
  the negotiated Bayer code instead of assuming RGGB. Its half-resolution,
  auto-stretched PNG is an inspection aid, not colour calibration or proof that
  the reported CFA order is physically correct; use its linear mode for
  low/high exposure and gain comparisons.
- The kernel milestone is not the whole webcam integration. Raw capture must
  pass before the libcamera soft-IPA patch and sensor tuning are installed or
  PipeWire/browser changes are considered.

## Acceptance gates

1. Package build completes from the recorded source commit and produces v14
   artifacts with no DT binding or module build errors.
2. The installed v14 kernel boots, and the live endpoint bytes are
   `00 00 00 00 39 ca ec 00`.
3. CCS binds at `1-0010`; the old overflow and link-frequency probe errors are
   absent.
4. The media graph negotiates 3844x2640 RAW10 through the sensor/PHY/CSID sink
   and 3840x2640 packed RAW10 through the CSID source/VFE/video node.
5. At least ten exact-size frames capture without truncated buffers or emitted
   camera-path errors; sampled range, entropy, and temporal-difference checks
   pass, and decoded raw inspection shows stable, non-corrupt image data.
6. Repeated start/stop and suspend/resume pass. Exposure and gain visibly affect
   real frames, simple-IPA AE converges, and the privacy LED is on only while
   streaming.
7. The camera enumerates through PipeWire and completes repeated browser/WebRTC
   sessions without stale nodes or buffer-allocation failures.

Do not read camera MMIO while the stream is inactive. The reference platform
can hang the bus when camera registers are read with the power/clock domain off.

## References

- [jglathe/linux_ms_dev_kit issue #74 resolution](https://github.com/jglathe/linux_ms_dev_kit/issues/74#issuecomment-5302651457)
- [Hardware-proven Snapdragon reference](https://github.com/karsies-wq/sp11-imx681-linux/tree/b08f76f40b8d7b715bd4da6aef484f86142cc147)
- [Static Windows package oracle](https://github.com/geocausa/SP11X1ECamera/tree/41003427f47edd27cd98f846b4282327824ee16f)
- [Same-machine Windows C-PHY receiver oracle](https://github.com/geocausa/SP11X1ECamera/tree/68b1b3124a799060316d58131fe3f1511bdfd335)
- [linux-surface PR #2156](https://github.com/linux-surface/linux-surface/pull/2156)
- [SP11 front-camera tracking issue #43](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/43)
- [ADR0066: SP11 IMX681 libcamera Simple IPA Integration](adr-0066-sp11-imx681-libcamera-simple-ipa.md)
- ADR-0002 (boot shim image strategy)
- ADR-0003 (Denali DTB and GRUB injection)
- ADR-0020 through ADR-0023 (Docker kernel build workflow)
- ADR-0052 (SP11 integration-fork kernel build)
