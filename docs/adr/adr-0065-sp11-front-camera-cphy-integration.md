---
id: adr-0065-sp11-front-camera-cphy-integration
title: "ADR0065: SP11 Front Camera C-PHY Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for integrating the Surface Pro 11 Sony IMX681 front camera using a hardware-validated standalone 3840x2640 sensor profile, the observed 2.406-Gsymbol/s X1E C-PHY lifecycle, reversible kernel packaging, and evidence-gated userspace enablement.
---

# ADR0065: SP11 Front Camera C-PHY Integration

## Status

Accepted for the `7.2.0-jg-0sp11v14` implementation milestone on 2026-08-28
and superseded on 2026-08-29 by the matched standalone-IMX681/turbine C-PHY
profile in kernel commit `6621d73e732c`. That package is now built, installed,
and booted: topology, stream negotiation, ten-frame packed-RAW10 capture, and
sampled-content gates pass at approximately 30 fps. A stable-light control
matrix then proved that gain affects real frames while the advertised exposure
control is photometrically inert. Kernel commit `b1754869f458` makes the next
bounded correction solely to the exposure address and width. Commit
`64999b9fc6e6` then removes the unvalidated C-PHY alternatives and tuning
interface while preserving the exact working trio-0 sequence.

The provenance-verified `64999b9fc6e6` package is now installed and booted.
The loaded sensor, CAMSS, and generic-PHY modules match the package; ten
independent raw start/stop cycles and a continuous 60-frame run pass with exact
12,672,000-byte buffers, gap-free approximately 30 fps cadence, and zero
reported CSID ECC/CRC or VFE violation/overflow status. Two fixed-gain endpoint
comparisons prove that the 24-bit exposure correction changes decoded raw
sample values, and a 1280x720 processed Firefox/Google Meet stream succeeds
through libcamera and PipeWire. Suspend/resume, automatic-exposure convergence,
the manual privacy-LED lifetime check, repeated post-resume application
sessions, covered-lens pedestal measurement, and final colour calibration
remain open.

Amended later on 2026-08-28 after the first v14-ABI runtime investigation
reached the sensor's final `MODE_SELECT` write but produced no completed
buffers.
The amendment records the compound-subdevice link-frequency fix, the fully
specified Linux clock tuple, and failure-path cleanup needed for the next
packaged experiment.

Amended again after booting the provenance-verified `0097c12b0fec` package.
The complete RAW10 graph and `VIDIOC_STREAMON` succeeded, but neither the
CSID0/VFE0 route nor the same-machine Windows-selected CSID1/VFE1 diagnostic
route completed a buffer. The next bounded package therefore matches the one
remaining CSID680 receiver-field delta from the same-machine Windows oracle
and exposes a packet-count diagnostic before userspace installation proceeds.

Amended once more after the native ARM64 local Docker package from
`ead11c748e4e` was installed and booted as
`7.2.0-jg-0sp11v14-qcom-x1e`. The loaded CAMSS, CCS, CCS PLL, and Qualcomm
MIPI CSI-2 PHY source versions match the verified package. Binding and graph
negotiation pass, but the canonical raw gate still completes zero buffers;
userspace installation therefore remains gated.

Commit `4d190bc96139bdf7ddb3cabd0551a86826600aae` adds a read-only
diagnostic boundary for the next package. It samples IMX681 stream/frame state
and powered CSID680/VFE680 status without changing stream configuration or
teardown semantics.

Amended on 2026-08-29 after installing and booting that package. The canonical
40-second capture armed VFE0 RDI0 and CSID0, but CSID reported zero packets,
zero receive/error IRQs, and zero ECC/CRC errors. The sensor accepted and
immediately read back `MODE_SELECT=1`; the later standby-path NACK occurred
after receiver teardown and does not establish when the sensor became
unreachable. Commit `347eb9702bf1` therefore restores the working reference's
sparse PLL overrides and adds a nonfatal sensor-state sample after 100 ms while
the downstream pipeline is still active.

The provenance-verified local package build from `347eb9702bf1` completed on
2026-08-29. It contains the intended sparse-PLL source and active-stream probe,
and was subsequently installed and runtime-tested. The sensor accepted
`MODE_SELECT=1`, then both `MODE_SELECT` and `FRAME_COUNT` returned `-ENXIO` at
the nonfatal 100 ms sample. The 40-second capture completed zero buffers while
CSID reported `TOTAL_PKTS=0`, no receive IRQs, and no ECC or CRC errors. This
rejects the sparse-PLL A/B and leaves the failure upstream of CSID packet
decode.

The decision was then amended around the hardware-validated camera bundle in
`turbineBMW/surface-pro-11-linux`. That reference captured three changing,
exact-size 3840x2640 packed-RAW10 frames at approximately 33.328 ms cadence
using a coherent pair: its standalone IMX681 global/mode transaction stream
and the observed X1E80100 C-PHY reset/configuration/IRQ/shutdown lifecycle at
2.406 Gsymbol/s. Kernel commit `6621d73e732c` ports that pair while retaining
this machine's repeatedly proven sensor address `0x10`; the reference unit's
`0x1a` address is a machine-specific difference, not part of the mode table.

This decision supersedes the earlier local draft that treated a statically
decoded 1.2 Gsymbol/s Windows sensor mode as a half-rate value and doubled it
to 2.4 Gsymbol/s at the receiver without a matched sensor transaction stream
or receiver oracle. That earlier interpretation was unproven and remains
rejected. The new 2.406-Gsymbol/s decision is independently justified by
turbine's complete standalone mode, exact observed PHY lifecycle, and changing
raw frames; it is not a resurrection of the old isolated-rate draft.

## Context

The Surface Pro 11 OLED unit exposes a Sony IMX681 front camera at CCI/I2C
`1-0010`. The v13 kernel creates the device and CAMSS media controller, but CCS
does not bind. The boot journal reports:

```text
value 327680000 overflows!
no valid link frequencies for 10 bpp
no supported mbus code found
```

The `value 327680000 overflows!` warning still appears on the verified
`ead11c748e4e` boot, but no longer accompanies the fatal link-frequency or
media-bus errors. Raw `0x13880000` encodes IREAL 5000 MHz; converting that
value to Hz exceeds `u32` and saturates only the temporary dynamic-debug
formatting result in `ccs_read_all_limits()`. The raw limit stored in the
sensor state is unchanged. This warning is therefore not evidence that the
selected 969.6 MHz link overflows and is not the cause of the zero-frame
failure.

The integration branch already contains model-scoped IMX681 support, the
x1e80100 C-PHY receive path, CSID680/VFE680 fixes, the Denali device-tree
nodes, and in-code CCS limit overrides for both observed manufacturer IDs
(`0x4260` and `0x3b60`). A later change moved the endpoint to 1.2 GHz and made
CAMSS double it to 2.4 Gsymbol/s. That conflicts with the sensor mode table
and with the only complete hardware-proven Snapdragon implementation.

### Evidence and provenance

The decision deliberately separates five evidence classes.

1. **Direct evidence from this device's Windows capture**

   A same-device Windows capture directly establishes MCLK4 at 19.2 MHz,
   reset GPIO237, and the LDO7B 2.8 V and LDO3M 1.8 V resources. It also
   records a front-camera exposure capability of
   `5000..2000000` WinRT ticks in steps of 10 ticks, with automatic exposure
   available. WinRT ticks are 100 ns, so this is a 0.5 ms to 200 ms control
   range with a 1 microsecond step.

   The capture does **not** contain decoded CCI register transactions or
   active CAMSS/CSIPHY MMIO. It therefore does not directly prove the sensor
   PLL registers, C-PHY rate, CDR value, physical trio, exposure register, or
   gain register. Raw capture material remains private because it can contain
   device-specific data; this ADR records only the bounded, sanitized result.

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

   The repository's `experiment/e003-front-imx681-cphy` branch advanced to
   `4cf90db69f5c8f4ed58b657fea6acebd18c95935` with same-machine Windows
   CSID/VFE and RT-CDM1 lifecycle oracles. They establish the native front path
   as CSIPHY2 -> CSID1 -> VFE1 IPP/FULL and the ISP-internal start order as
   CDM -> IFE -> initial configuration packets -> CSID. The RT-CDM work is
   deliberately still an inert resource plus disabled IRQ/DMA scaffold: the
   branch does not authorize Linux RT-CDM MMIO, IRQ arming, or FIFO submission
   because two live register origins and stop-time power semantics remain
   unresolved. This is valuable for the later IPP/image-processing parity
   stage, but importing it cannot explain or repair the zero-buffer RDI capture
   result and would be premature before the bounded `4d190bc96139` diagnostic.

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
   clock. Its mode table does not program a complete clock tree: it preserves
   the CCS-calculated branch dividers and overrides only `0x0307=e1` and
   `0x030d..0x030f=03 01 2f`. The complete tuple later derived from those
   observations was not direct runtime evidence and produced zero decoded
   packets on this device, so it is rejected for the next bounded experiment.

4. **Intel IMX681 work**

   `linux-surface/linux-surface#2156` targets Intel IPU6 and a D-PHY receiver.
   It is useful for sensor-table provenance and corroborating the 969.6 MHz
   sensor configuration, but its receiver changes must not be cherry-picked
   into Qualcomm CAMSS. Its analogue-gain interpretation also conflicts with
   later Snapdragon measurements, where `0x0204` is ineffective and global
   U8.8 gain at `0x020e/0x020f` changes the image.

5. **Hardware-validated turbine standalone profile**

   `turbineBMW/surface-pro-11-linux` main commit
   `b1f5237957b9b7bf0ee36a5885fab494210d7fed` publishes a reconstructable
   camera bundle at `675d89b381d8b730a3f2eff1086875481ee5b515`. The relevant
   source commits are standalone IMX681 `00cece0b87c40c76c14b6c7ab68a6d3603554614`,
   Denali camera wiring `8915ca862de45dff36d04671c16346bc01042505`,
   X1E C-PHY/CSID plumbing `b1eae4e601697ffe783b47c052f1bc5d37cb9917`,
   and the observed receiver lifecycle
   `8c1731648d0461047cf8849eee0b1f854a87d4d7`.

   Its hardware record is narrower than complete desktop qualification but is
   decisive for transport: three exact 12,672,000-byte, mutually changing
   3840x2640 packed-RAW10 frames at approximately 30 fps. The sensor table
   programs PLL bytes `0301=06`, `0303=02`, `0305=02`, `0306=00`, `0307=e1`,
   `030d=03`, `030e=01`, `030f=77`; V4L2 reports half the actual C-PHY symbol
   rate as 1.203 GHz and the receiver consumes 2.406 Gsymbol/s. This profile is
   a coherent replacement for the failed 3844/969.6 experiment, not a source
   of isolated PLL or AFE values to mix into it.

   The reference hardware used sensor address `0x1a`; this machine repeatedly
   completed model, stream-state, and control transactions at `0x10`. Kernel
   commit `6621d73e732c` therefore keeps `0x10` while importing the address-
   independent transaction stream and receiver lifecycle.

### Boot and deployment behavior

The qcom-x1e package uses stubble/UKI construction with auto-selected embedded
DTBs. Although GRUB contains a `devicetree /sp11-denali.dtb` directive, the
live tree does not match that loose file:

| Source | Link frequency |
| --- | ---: |
| Historical v13 live `/proc/device-tree` | 1,000,000,000 |
| Historical loose `/boot/sp11-denali.dtb` | 1,200,000,000 |
| Verified `ead11c748e4e` live `/proc/device-tree` | 969,600,000 |
| Installed `347eb9702bf1` live `/proc/device-tree` | 969,600,000 |
| `6621d73e732c` replacement source/build DTB | 1,203,000,000 |

The installed kernel must therefore contain the corrected OLED DTB in its
embedded auto-DTB section. Copying only a loose DTB is not an acceptance test.
No deployment may copy another machine's full DTB or hard-code its Bluetooth
address. The current installed CCS kernel still exposes
`00 00 00 00 39 ca ec 00`; the replacement package must expose
`00 00 00 00 47 b4 52 c0` after boot.

## Decision

We will integrate the front camera as follows.

### Superseding standalone kernel data path

- Bind `sony,imx681` at this machine's proven CCI1/master1 address `0x10` and
  retain MCLK4 at 19.2 MHz, reset GPIO237 active-low, LDO7B 2.8 V, and LDO3M
  1.8 V. Do not copy the reference unit's `0x1a` address.
- Program the standalone driver's complete global table followed by its single
  3840x2640 RAW10 mode. Keep its full PLL tuple, 6752-pixel line length,
  2708-line default frame, and reciprocal Sony analogue-gain code as one
  sensor profile.
- Advertise one C-PHY trio with a 1.203 GHz V4L2 link frequency and carry the
  corresponding 2.406-Gsymbol/s rate into the generic X1E PHY. Do not combine
  this receiver sequence with the rejected 969.6-Msymbol/s CCS mode.
- Replay the observed X1E80100 reset, trio toggle, common, analogue,
  configuration, IRQ-clear, and shutdown tables only for that exact X1E C-PHY
  rate. Request the generic-PHY IRQ disabled, enable it only during the powered
  interval, run the hardware reset before lane configuration, and shut lanes
  down before disabling IRQs, clocks, or supplies.
- Keep that trace-derived trio-0, 2.406-Gsymbol/s lifecycle as the only
  supported X1E80100 C-PHY profile. Pass the endpoint's physical trio through
  the generic-PHY submode and reject unsupported trio, count, or rate before
  receiver power or MMIO. Preserve the generic D-PHY path unchanged.
- Preserve 3840 pixels end to end with no CSID crop. Retain the existing
  3844-only crop helper solely for the superseded mode, while keeping
  `TOTAL_PKTS`, ECC/CRC, IRQ, RDI, and VFE stop diagnostics available for both
  3840 and 3844 IMX681 signatures.
- Keep CCI at the already reliable 400 kHz for the first bounded A/B; turbine's
  1 MHz bus rate is not necessary to test the matched sensor/PHY pair.

### Superseded CCS kernel data path

The following decisions describe the earlier zero-packet implementation and
remain only as historical evidence; kernel commit `6621d73e732c` replaces the
active sensor and C-PHY profile.

- Advertise `link-frequencies = /bits/ 64 <969600000>` on the IMX681 C-PHY
  endpoint.
- Pass that value directly as the C-PHY symbol rate in CAMSS.
- Selected the x1e80100 1.0 Gsymbol/s C-PHY AFE table with CDR `0x4a` on all
  three table lanes and treated runtime override value zero as "use the table
  default". Commit `64999b9fc6e6` removes that superseded table family and its
  trio, settle, and CDR override interface.
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
- Preserve the branch dividers selected by the CCS PLL calculator and apply
  only the working reference's sparse multiplier/pre-divider overrides:
  `0x0307=e1` and `0x030d..0x030f=03 01 2f`. Leave `PLL_MODE` at the sensor
  default. Keep 432 MHz as the measured VT timing metadata used for exposure
  conversion; the CCS-reported 387.84 MHz CSI pixel rate is not the VT clock.
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
- Sample CSID680 status from the normal powered STREAMOFF path, before pipeline
  PM disables its clocks and independently of the one-shot `need_vc_update`
  configuration guard. The `ead11c748e4e` diagnostic inside
  `configure_stream(false)` did not run because normal teardown deliberately
  does not repeat shared virtual-channel configuration.
- Restrict the snapshot to the X1E80100 3844x2640 RAW10 C-PHY route. Report
  `RX_CFG0`, `RX_CFG1`, `TOTAL_PKTS`, ECC/CRC counters, top/buffer/RX IRQ
  state, and each linked RDI's IRQ/configuration/crop state without writing any
  stream registers.
- For the matching 3840x2640 packed-RAW VFE680 route, report write-master
  address/increment/image/packer configuration plus IRQ, violation, overflow,
  and image-violation state before disabling the writer.
- Sample IMX681 `MODE_SELECT` and `FRAME_COUNT` before and after stream-on and
  before stream-off. For the sparse-PLL package, take one additional sample
  after 100 ms while CSIPHY, CSID, and VFE remain active. Diagnostic read
  failures remain nonfatal and must never replace the authoritative
  `MODE_SELECT` write result or alter best-effort teardown.

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
- `4d190bc96139bdf7ddb3cabd0551a86826600aae` — move the receiver snapshot
  onto powered STREAMOFF, add matching CSID680/VFE680 packet, error, IRQ, and
  write-master evidence, and sample nonfatal IMX681 `MODE_SELECT` and
  `FRAME_COUNT` state around stream transitions.
- `347eb9702bf18f2d81e4e29767a416172acbfe66` — reject the unproven complete
  divider tuple after its zero-packet result, restore the reference's sparse
  PLL ownership, and sample sensor state after 100 ms of active streaming.
- `6621d73e732c5dc24cdb6c28240e900bcb32c192` — supersede the failed CCS
  profile with the turbine standalone 3840x2640 sensor transaction stream and
  observed 2.406-Gsymbol/s X1E C-PHY lifecycle while retaining this machine's
  proven sensor address `0x10`.
- `b1754869f458ebc3b01cf449f8b1f6aa8edd13e0` — correct only the standalone
  exposure latch from inert 16-bit `0x0202` to 24-bit `0x0229`, after the
  stable-light control matrix separated exposure failure from working gain and
  transport. Frame timing and every other camera layer remain unchanged.
- `64999b9fc6e60ebccdc3755563cafcc63930cc90` — remove the unvalidated
  eight-rate C-PHY tables, nearest/default fallback, and global tuning
  parameters; advertise only trio 0 at 2.406 Gsymbol/s in X1E SoC data and fail
  unsupported C-PHY profiles before receiver power or MMIO.

The earlier `e0ce71102628` source passed local module/DTB builds, binding
validation, and strict checkpatch before packaging. Strict checkpatch also
passes the `0097c12b0fec`, `4d190bc96139`, and `347eb9702bf1` amendments.
The latter passes a targeted `W=1` CCS module build; `4d190bc96139`
additionally passed the targeted CAMSS and CCS PLL module builds.
Commit `6621d73e732c` passes strict checkpatch for both tracked diffs and all
three new source files, targeted and `W=1` ARM64 builds of the standalone
IMX681, Qualcomm MIPI CSI-2 PHY, and CAMSS modules, and the Denali OLED DTB
build. The copied standalone driver, mode table, and observed register table
are byte-identical to the reconstructed turbine bundle before the local PHY-
architecture adaptation.
Commit `b1754869f458` passes strict checkpatch and a targeted ten-job `W=1`
ARM64 `imx681.ko` build. Runtime validation remains tied to the package build
and post-boot fixed-light matrix recorded below.
Commit `64999b9fc6e6` passes strict checkpatch, a byte-for-byte comparison with
the previously proven observed table, dead-symbol searches, and ten-job `W=1`
ARM64 module builds for IMX681, the Qualcomm MIPI CSI-2 PHY, and CAMSS. The
sleepable lifecycle writer is no longer reachable from hard IRQ context.

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
The raw runtime logs remain private because they can contain device-specific
data; the bounded result above is the public evidence record.

The same-machine Windows analysis establishes `RX_CFG0=0x11300000`. Its exact
2.4-Gsymbol/s PHY table belongs to a distinct 3840x2640, PLL2 `3/375`,
1.2-GHz-link sensor mode. Do not mix that table with the then-current
3844x2640, PLL2 `3/303`, 969.6-Msymbol/s Linux mode; both isolated profiles are
superseded by the matched turbine stack. Its IPP/VFE PIX patches also remain
static and incomplete, so they are not part of this bounded RDI transport
experiment.

### `ead11c748e4e` local package build

The native ARM64 Docker build completed locally on 2026-08-28 in approximately
46 minutes using `binary-indep binary-qcom-x1e` with eight jobs. The manifest
records source HEAD `ead11c748e4e8fb984412093be73d2228bd68e89`, the requested
integration branch, no local patches, and the direct-root rules runner. Exactly
four packages were produced; each reports source `linux-qcom-x1e` and version
`7.2.0-jg-0sp11v14`, with the expected `arm64` or `all` architecture.

The modules package contains the expected CAMSS, CCS, CCS PLL, and Qualcomm
MIPI CSI-2 PHY modules. All report vermagic
`7.2.0-jg-0sp11v14-qcom-x1e`. Their packaged source versions are:

- `qcom-camss`: `26CF187C5D69D7818A1BDCB`
- `ccs`: `426DF2BB77E8D8D0F7BDAF8`
- `ccs-pll`: `F5D68994B5EB8E947AC4F6B`
- `phy-qcom-mipi-csi2`: `F578CE5728BAC71AB6C9374`

The packaged CAMSS module differs from the prior package source version
`2CE131610DCEBDD881BBC84` and contains the new stop-time diagnostic format:

```text
CSID%u C-PHY stop: RX_CFG0=%#010x TOTAL_PKTS=%u RDI%u_CFG0=%#010x RDI%u_HCROP=%#010x
```

The packaged CAMSS source version is authoritative; a different value observed
in a host incremental build did not share the final package build context.

The verified packages, manifest, package list, build arguments, and checksum
manifest are retained in the distinct read-only directory
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-ead11c748e4e/`. Its recorded
SHA-256 values are:

- image: `6122b59ec1b69c30f31c7bfc12f37349ce7f43b07a6adfcfa6d882b867286ae3`
- modules: `aa41fce90ae91bc2a7dd502bfe60e70873a13af37549bdc789d82c818610159e`
- flavour headers: `e0c6178d9e2dc081a04365f3ffc2bef3503b8a6e99234567c47ddc8aa64f4268`
- common headers: `f81ac09b161c126761f25d7e5c365ecb70f80d67eeca6d0d7d7c5f27b20f0189`
- build manifest: `551ab27db38d2f69e87c117b0516e8f3692fab6af13bf488e393ff8e95f5f3c0`
- package list: `08a5dc85c04b51875e7696cf9db220b22ded22b2274212393f197a5538ac8756`
- build arguments: `f1f24702771b87fb7afeb3f73274efcfdb87ca53436265f4dc4c4deb5e48c092`

At that stage no package was installed, no live module or camera device was
touched, and no reboot was performed as part of the build and provenance gate.

### `ead11c748e4e` boot and runtime result

The verified package was later installed and booted as
`7.2.0-jg-0sp11v14-qcom-x1e`. Loaded module source versions matched the
immutable artifact evidence:

- `qcom-camss`: `26CF187C5D69D7818A1BDCB`
- `ccs`: `426DF2BB77E8D8D0F7BDAF8`
- `ccs-pll`: `F5D68994B5EB8E947AC4F6B`
- `phy-qcom-mipi-csi2`: `F578CE5728BAC71AB6C9374`

The canonical validator again negotiated IMX681 3844x2640
`SRGGB10_1X10`, CSIPHY2, CSID0's 3840x2640 crop, VFE0 RDI0, packed `pRAA`,
4800-byte stride, and 12,672,000-byte buffers. `VIDIOC_REQBUFS`, queueing, and
`VIDIOC_STREAMON` succeeded. The PHY selected the 1.0-Gsymbol/s table for the
969.6-Msymbol/s stream, but no buffer completed in 40 seconds and
`capture.raw` remained zero bytes.

The intended `RX_CFG0`/`TOTAL_PKTS` stop line did not appear. Its placement
inside `configure_stream(false)` was suppressed by the normal one-shot
virtual-channel configuration guard, so this run does not establish the
packet count. Teardown again received `-ENXIO` while writing `MODE_SELECT=0`
and scheduled runtime power-down. Evidence is retained in
the contemporaneous local validation record; it is not a repository artifact.

### `4d190bc96139` local diagnostic package build

The native ARM64 Docker build completed locally on 2026-08-28 in approximately
54 minutes using `binary-indep binary-qcom-x1e` with eight jobs. The manifest
records exact source HEAD `4d190bc96139bdf7ddb3cabd0551a86826600aae`, the
requested integration branch, no local patches, and the direct-root rules
runner. Exactly four packages were produced; each reports source
`linux-qcom-x1e` and version `7.2.0-jg-0sp11v14`, with the expected `arm64` or
`all` architecture.

The modules package reports vermagic
`7.2.0-jg-0sp11v14-qcom-x1e` for the four inspected camera modules. Their
packaged source versions are:

- `qcom-camss`: `0486AE0FB983546F7875668`
- `ccs`: `51A4C4B08DF03EDE294DD26`
- `ccs-pll`: `F5D68994B5EB8E947AC4F6B`
- `phy-qcom-mipi-csi2`: `F578CE5728BAC71AB6C9374`

The packaged CAMSS module contains the new powered stop-path diagnostic
formats, including `TOTAL_PKTS`, ECC/CRC state, exact RDI configuration, and
the VFE write-master address/increment/image/packer snapshot. The packaged CCS
module contains the IMX681 pre/post-stream state format for `MODE_SELECT` and
`FRAME_COUNT`. This verifies that the intended read-only probes are present in
the packages; it does not claim that raw capture is repaired.

The verified packages, manifest, package list, build arguments, and checksum
manifest are retained separately in the read-only directory
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-4d190bc96139/`. Its recorded
SHA-256 values are:

- image: `705e444e84b8fa99db21d4863370bc529559fac372f2599f3878a6696c2134c9`
- modules: `d99e7dfd757a52d8470c94c2f9a1a073b0f08dc21373c06044cae059f20efaca`
- flavour headers: `1d4a9e051616ccd66c59e0f98c760ba2f7ccd62bde290b6110c3ee343ee17d88`
- common headers: `87e416890efeaeda7e56c738b7ac4d53c957d2f85d9ca4920a8858049a2fc043`
- build manifest: `aa5d7ef62792828b15feb030e3429c3275efe4422608829a6dee026a2f5217a9`
- package list: `08a5dc85c04b51875e7696cf9db220b22ded22b2274212393f197a5538ac8756`
- build arguments: `f1f24702771b87fb7afeb3f73274efcfdb87ca53436265f4dc4c4deb5e48c092`

No package from this diagnostic build was installed, no live module or camera
device was touched, and no reboot was performed as part of this build and
provenance gate.

### `4d190bc96139` boot and runtime result

The provenance-verified package was subsequently installed and booted as
`7.2.0-jg-0sp11v14-qcom-x1e`. Loaded source versions matched its artifacts for
CAMSS (`0486AE0FB983546F7875668`), CCS (`51A4C4B08DF03EDE294DD26`), CCS PLL
(`F5D68994B5EB8E947AC4F6B`), and Qualcomm MIPI CSI-2 PHY
(`F578CE5728BAC71AB6C9374`). The live endpoint remained 969.6 MHz and the CCS
sensor bound normally.

The canonical validator negotiated the expected 3844x2640 RAW10 sensor stream,
CSIPHY2/trio0, CSID0's 3840x2640 crop, and VFE0 RDI0 packed RAW output with a
4800-byte stride and 12,672,000-byte buffers. Buffer allocation, queueing, and
`VIDIOC_STREAMON` succeeded, but no buffer completed in 40 seconds and the raw
file remained empty. The powered stop snapshot reported:

```text
VFE0 RDI0 WM24: CFG=0x00010001 ADDR=0xfe000000 INCR=0x00c15c00
CSID0: RX_CFG0=0x11300000 RX_CFG1=0x00000001 TOTAL_PKTS=0 ECC=0 CRC=0
CSID0 IRQ: TOP=0 BUF_DONE=0 RX=0
CSID0 RDI0: CFG0=0x802b2000 CTRL=1 CFG1=0x00008095 HCROP=0x0eff0000
```

VFE IRQ, violation, overflow, and image-violation state were also all zero.
This proves that userspace, VFE, and CSID were armed, while no packet reached
CSID decode and no protocol error was observed. The failure boundary is
therefore upstream of CSID packet decode.

Immediately around STREAMON, the sensor remained readable and changed
`MODE_SELECT` from `0x00` to `0x01`; `FRAME_COUNT` read `0xff` both times. At
STREAMOFF both reads returned `-ENXIO`, but the sensor callback runs after VFE,
CSID, and CSIPHY teardown, so that NACK may be induced by the earlier receiver
shutdown. A separate approximately 350 ms attempt reproduced the same order:
successful stream-on readback, receiver stop, then sensor NACK. It does not
prove that the sensor lost power or stopped responding during active capture.

The next source milestone, `347eb9702bf1`, is a bounded sensor-side A/B. It
leaves geometry, endpoint rate, C-PHY table/CDR, CSID, and VFE unchanged;
restores only the sparse PLL register ownership used by the working Snapdragon
reference; and samples sensor state at 100 ms before downstream teardown.

### `347eb9702bf1` local diagnostic package build

The native ARM64 Docker build completed locally on 2026-08-29 in approximately
44 minutes using `binary-indep binary-qcom-x1e` with eight jobs. Its manifest
records exact source HEAD `347eb9702bf18f2d81e4e29767a416172acbfe66`, the
requested integration branch, no local patches, and the direct-root rules
runner. Exactly four selected packages were exported; each reports source
`linux-qcom-x1e` and version `7.2.0-jg-0sp11v14`, with the expected `arm64` or
`all` architecture.

The modules package reports full vermagic
`7.2.0-jg-0sp11v14-qcom-x1e SMP preempt mod_unload modversions aarch64` for
the four inspected camera modules. Their packaged source versions are:

- `qcom-camss`: `0486AE0FB983546F7875668`
- `ccs`: `3D5D2364F6C1C7A42CDB0FD`
- `ccs-pll`: `F5D68994B5EB8E947AC4F6B`
- `phy-qcom-mipi-csi2`: `F578CE5728BAC71AB6C9374`

The CCS source version changes from the installed `4d190bc96139` package,
while the three intentionally unchanged camera modules retain their prior
source versions. The packaged CCS module contains both the IMX681 stream-state
format and the `active-100ms` label. The packaged CAMSS module retains the
powered CSID/VFE packet, IRQ, error, and write-master diagnostic formats. The
manifest's exact source HEAD is the authority for the sparse four-register PLL
override.

The packages, manifest, package list, build arguments, and checksum manifest
are retained in the distinct read-only directory
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-347eb9702bf1/`. Its recorded
SHA-256 values are:

- image: `ba7060ef0276817f8cf33078b69d3dddf0b2cc7b25b405884b7e6ff78c58f7a4`
- modules: `bce41fa965810309c89671ffbd7815e2c21b5680cd86527f0fe783c2a3100b77`
- flavour headers: `38d13a8b54b63a0515d4ca6b3a5690ba48b526763812d7eb330e61fa83499f2d`
- common headers: `d57cc4181e15cf4146f1697df74ef2ffc8c63b2fd3c7ca936943289e2cb14e04`
- build manifest: `d1f1eb90d6d883b0b404f266c228037b4d801a986e1f026ba21992ec3213bd94`
- package list: `08a5dc85c04b51875e7696cf9db220b22ded22b2274212393f197a5538ac8756`
- build arguments: `f1f24702771b87fb7afeb3f73274efcfdb87ca53436265f4dc4c4deb5e48c092`

No package was installed, no live module or camera device was touched, and no
reboot was performed as part of the build itself. The package was later
installed and booted. Loaded source versions matched the artifacts, the media
graph again negotiated, and `VIDIOC_STREAMON` succeeded. The nonfatal 100 ms
sample then reported `-ENXIO` for both sensor registers and the 40-second
capture ended with an empty file, `TOTAL_PKTS=0`, no receive IRQs, and no
ECC/CRC errors. The `347eb9702bf1` A/B therefore failed its runtime gate.

### `6621d73e732c` standalone turbine-profile source milestone

The replacement is not an isolated rate or PLL experiment. It imports the
complete standalone IMX681 global/mode tables, exact 3840x2640 geometry and
timing, and the exact observed X1E receiver configuration as a matched pair.
The generic-PHY adaptation also closes prerequisite lifecycle gaps that the
legacy turbine CAMSS path handled elsewhere: IRQ ownership, powered reset,
lane-start failure unwind, and shutdown before clocks and supplies. It leaves
the current CSID/VFE RDI data path in place so the first runtime comparison is
bounded at the sensor/receiver boundary.

The source is pushed on
`sp11/integration-7.2.x-ooaklee-karsies-wq-cams`. The package build below
establishes source and packaging provenance, but does not by itself establish
that this machine accepts the reference transaction stream or emits packets.

### `6621d73e732c` local matched-stack package build

The canonical native ARM64 Docker build completed locally on 2026-08-29 in
approximately 48 minutes using `binary-indep binary-qcom-x1e` with ten jobs.
Its manifest records exact source HEAD
`6621d73e732c5dc24cdb6c28240e900bcb32c192`, the requested integration branch,
no local patches, and the direct-root rules runner. Exactly four selected
packages were exported; each reports source `linux-qcom-x1e` and version
`7.2.0-jg-0sp11v14`, with the expected `arm64` or `all` architecture.

The standalone sensor, CAMSS, and generic C-PHY modules are present in the
modules package and report full vermagic
`7.2.0-jg-0sp11v14-qcom-x1e SMP preempt mod_unload modversions aarch64`.
Their packaged source versions are:

- `imx681`: `3537F7270BB6A2B0D1FAE0C`
- `qcom-camss`: `DBD35CBCA4AC946BFB30854`
- `phy-qcom-mipi-csi2`: `F72877655458B25D6F0FBB5`

Both packaged Denali OLED DTBs decompile with `sony,imx681` at this machine's
proven I2C address `0x10`, C-PHY bus type, data lane 0, and link frequency
1,203,000,000 Hz. The module compression streams, Debian package structure,
package control fields, and DTBs all passed inspection.

The packages, manifest, package list, ten-job build arguments, and checksum
manifest are retained in the distinct read-only directory
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-6621d73e732c/`. Its strict
`SHA256SUMS` verification passes with these recorded values:

- image: `e98ba12d9582764251b8d2c90c4741890c874ffa2a5fa49e7d9827515dc5b9ab`
- modules: `c61948691bc9b60b2d48f289dc1c4f52ee38f47820d256e2c6b5039eb640d744`
- flavour headers: `60356abe076bfc45f2aac9dca78cb107450ac3c2bd280f7968da25a029c67356`
- common headers: `8981be08cb2270aa11fa5eb168d8388cdae2967c3f55fb8f75dc4d207338d518`
- build manifest: `a2b549fc03e094c0dd48b85df73ce3194f7bc09efecb242243413c1d59d17593`
- package list: `08a5dc85c04b51875e7696cf9db220b22ded22b2274212393f197a5538ac8756`
- build arguments: `13cf9b25abf149feb8fb8f726bb84e32cc4ae989b2521da95eb25efb8fc2b39a`

No package was installed, no live module or camera device was touched, and no
reboot was performed as part of this build and artifact verification. Runtime
gates remain pending until the package is deliberately installed and booted.

### `6621d73e732c` boot, raw, and stable-light control result

The provenance-verified package was installed and booted as
`7.2.0-jg-0sp11v14-qcom-x1e`. The loaded `imx681` reports source version
`3537F7270BB6A2B0D1FAE0C` and the expected v14 ARM64 vermagic. With the room
lighting held stable, PipeWire and WirePlumber clients stopped, and a two-second
settle between cases, four raw captures varied one control at a time:

| Case | Exposure | Gain | Sample mean | Stddev | Entropy |
|---|---:|---:|---:|---:|---:|
| A | 128 | 0 | 65.634 | 19.485 | 2.458 |
| B | 2400 | 0 | 65.621 | 19.225 | 2.455 |
| C | 128 | 768 | 69.382 | 26.877 | 4.116 |
| D | 2400 | 768 | 69.371 | 26.920 | 4.117 |

Every case completed ten exact 12,672,000-byte frames, with 33.29--33.40 ms
cadence, changing-frame/content checks passing, and no emitted CSID ECC/CRC or
VFE camera-path error. Raising gain changed the sampled distribution; changing
exposure from 128 to 2400 changed mean luminance by less than 0.02 percent at
either fixed gain. The test was captured on 2026-08-29 at approximately 05:26
BST. The original controls and user camera services were restored after the
matrix.

This result isolates a kernel control defect. The standalone driver inherited
`CCI_REG16(0x0202)`, while its own imported mode table seeds coarse exposure as
the 24-bit bytes `0x0229..0x022b = 00 0d da`. The prior model-scoped Karsies
implementation and the public IMX681 reference driver use that same 24-bit
field. The same-machine Windows/QTI package provides independent static
byte-level corroboration; it is not a live Windows CCI transaction trace.
Commit `b1754869f458` therefore changes only exposure to
`CCI_REG24(0x0229)`. It deliberately leaves frame-length programming, timing
metadata, exposure bounds, gain, mode tables, DT, CAMSS, and C-PHY unchanged so
the post-boot 128-versus-2400 comparison tests exactly one live variable.

### `b1754869f458` provenance-verified package build

The local ARM64 Docker build completed successfully on 2026-08-29 from git
source HEAD `b1754869f458ebc3b01cf449f8b1f6aa8edd13e0`, with no local patches,
the `binary-indep binary-qcom-x1e` target, and ten jobs. All four packages
report version `7.2.0-jg-0sp11v14`; the image, modules, and flavour headers are
`arm64`, and the common headers package is `all`.

The packaged modules report full vermagic
`7.2.0-jg-0sp11v14-qcom-x1e SMP preempt mod_unload modversions aarch64` and
these source versions:

- `imx681`: `F301258D0B6B33933A0A086`
- `qcom-camss`: `DBD35CBCA4AC946BFB30854`
- `phy-qcom-mipi-csi2`: `F72877655458B25D6F0FBB5`

Both packaged Denali OLED DTBs retain `sony,imx681` at `0x10`, C-PHY bus type,
physical trio 0, and the 1,203,000,000 Hz V4L2 link frequency. The packages,
manifest, package list, build arguments, and checksum manifest are retained in
`build/docker-sp11-qcom-x1e-kernel/artifacts-v14-b1754869f458/`. Strict
`SHA256SUMS` verification passes with these values:

- image: `d6246abdb1c6e47dc43a2f9d313f79bb7d835c901bff4fc0c395e7ab044924ac`
- modules: `f6205aea9dc70836c471741df35494e1e7871335cffda17e253e01f53fd5ae18`
- flavour headers: `6102278fc032f92cb91097ff87bfd99c0e5bc255d36362beffa560a69f95f57b`
- common headers: `b809d66dc5247c537bcb97592808342d44955a92d39dfb912bc44be498e1749a`
- build manifest: `0733db7a3b0ec07002475c68b74919411159081c0a0099ca69b8636699cfb02c`
- package list: `08a5dc85c04b51875e7696cf9db220b22ded22b2274212393f197a5538ac8756`
- build arguments: `13cf9b25abf149feb8fb8f726bb84e32cc4ae989b2521da95eb25efb8fc2b39a`

This verification did not install a package, load a module, access camera
hardware, or reboot the device. The fixed-light exposure-response gate remains
pending.

### Exact-profile C-PHY consolidation

Kernel commit `64999b9fc6e60ebccdc3755563cafcc63930cc90` removes the
second, unvalidated X1E C-PHY implementation: eight generated tables spanning
1.0--2.5 Gsymbol/s, nearest/default rate selection, the generic fallback
writer, and global trio, settle, and CDR module parameters. The sole canonical
X1E table now contains the previously working observed sequence byte for byte.

CAMSS passes the endpoint's physical C-PHY trio through the generic-PHY
submode instead of imposing an X1 policy in the global endpoint parser. X1E SoC
data advertises only `BIT(0)` and 2,406,000,000 symbols/s. The provider rejects
an unsupported trio during mode selection and rejects an unsupported count or
rate during configuration, all before receiver power or MMIO; the enable path
independently checks the complete SoC, mode, trio, count, and rate contract.
The D-PHY configuration and programming path is unchanged.

The observed IRQ-clear table now has a dedicated hard-IRQ writer containing
only ordered register writes and its bounded 1 us busy waits. The general
lifecycle writer is explicitly sleepable and is used only from process-context
enable and disable paths. The package and post-boot result below establish that
this consolidation retains the raw and browser acceptance results.

### `64999b9fc6e6` package and post-boot regression result

The local ARM64 Docker build completed from exact source HEAD
`64999b9fc6e60ebccdc3755563cafcc63930cc90`, with no local patches, the
`binary-indep binary-qcom-x1e` target, and ten jobs. All four installed
packages report version `7.2.0-jg-0sp11v14`. The running release is
`7.2.0-jg-0sp11v14-qcom-x1e`, and the loaded modules have the expected v14
ARM64 vermagic and these source versions:

- `imx681`: `F301258D0B6B33933A0A086`
- `qcom-camss`: `102974D58A8CD704DFE72C1`
- `phy-qcom-mipi-csi2`: `C9D02214FEAB2652B78C385`

Extracting those three packaged `.ko.zst` members and comparing them with the
installed compressed module files produced byte-for-byte matches. The sensor
detected model `0x0681`; the media graph negotiated
`SRGGB10_1X10/3840x2640` through CSIPHY2, CSID0, VFE0 RDI0, and packed-RAW10
`/dev/video0`. The consolidated provider selected its sole X1E profile at
2,406,000,000 symbols/s.

Ten independent ten-frame start/stop captures passed the exact-size and
sampled-content gates. A separate continuous 60-frame run dequeued sequences
0 through 59 without a gap; every buffer was exactly 12,672,000 bytes and the
inter-frame delta was 33.153--33.468 ms, with a 33.327 ms mean. Across the ten
cycles, the continuous run, and four control captures, all 15 stop records
reported zero CSID ECC/CRC errors and zero VFE violation, overflow, and
image-violation status. An earlier completed Firefox stream reported 1,111,105
received packets with the same zero-error result.

With the scene unchanged, controls allowed two fixed-gain exposure comparisons:

| Case | Exposure | Gain | Sample mean | Stddev | Entropy | Result |
|---|---:|---:|---:|---:|---:|---|
| A | 128 | 0 | 64.225 | 0.751 | 1.582 | Exact transport; deliberately near-black content floor |
| B | 2400 | 0 | 67.888 | 6.646 | 3.522 | Pass |
| C | 128 | 768 | 64.797 | 2.086 | 2.929 | Pass |
| D | 2400 | 768 | 81.697 | 28.744 | 5.560 | Pass |

At gain 0, exposure 128 intentionally starved the image enough to fall below
the validator's one-code standard-deviation content threshold, while still
delivering ten exact, changing buffers and clean transport. Increasing exposure
to 2400 raised the decoded RAW10 sample mean by 5.7 percent at gain 0. At gain
768, the same change raised it by 26.1 percent and visibly revealed the scene
in linearly mapped previews. These endpoint comparisons directly resolve the
earlier less-than-0.02-percent inert-exposure result and behaviorally validate
`CCI_REG24(0x0229)` on this hardware; they do not establish monotonicity across
the complete control range.

The unchanged IMX681-aware libcamera package selected
`simple/imx681.yaml`, exported `Built-in Front Camera`, and supplied an active
1280x720 RGBA stream to Firefox/Google Meet without a PipeWire graph error.
The original exposure/gain values and all previously active PipeWire,
PipeWire-Pulse, and WirePlumber units were restored after raw testing; the
processed source re-enumerated. Two subsequent 960x540 and 1280x720 processed
starts also completed in the same boot; their receiver stops reported 959,851
and 1,282,340 packets respectively, again with zero CSID ECC/CRC and VFE error
status. The user-visible Meet result and those restarts qualify repeated
current-boot browser streaming, not the still-pending suspend/resume, manual
privacy-LED, or post-resume application gates.

## Consequences

- The sensor, CAMSS, and generic PHY now use one hardware-validated matched
  rate contract: V4L2 1.203 GHz represents the standalone mode's observed
  2.406-Gsymbol/s C-PHY rate on physical trio 0. Other X1 C-PHY rates, counts,
  and trios fail before receiver power or MMIO; the failed CCS
  969.6-Msymbol/s profile remains only as recorded history.
- The static Windows package and turbine table independently converge on the
  `03 01 77` PLL2 suffix, but the replacement is justified by turbine's actual
  changing-frame capture and complete transaction/lifecycle pair, not by
  treating either static number as sufficient on its own.
- Userspace sees only a mode the driver will actually program. Adding further
  modes later requires proper V4L2 state, control-range, and link-frequency
  selection rather than another global module parameter.
- The simple IPA can drive both standard controls, reciprocal gain changes real
  frames, and the `64999b9fc6e6` runtime matrix proves that the isolated
  `CCI_REG24(0x0229)` correction restores exposure response. The default
  2708-line control model and longer-exposure policy remain separate timing
  work; userspace colour, pedestal, and AE-target calibration are not kernel
  transport requirements.
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
- The kernel milestone is not the whole webcam integration. Raw capture now
  passes, while the libcamera soft-IPA package, sensor tuning, and browser
  integration retain their own provenance and calibration gates.

## Acceptance gates

For `4d190bc96139` and `347eb9702bf1`, gates 1–4 passed and gate 5 failed with
zero completed buffers and zero CSID packets. For `6621d73e732c`, gates 1–5
pass, but its exposure-response half of gate 6 fails. On the packaged and booted
`64999b9fc6e6` head, gates 1–5 pass again, ten raw start/stop cycles pass, and
both gain and exposure affect real frames. This declares the exact-profile
C-PHY consolidation runtime-equivalent for the tested raw path and resolves the
exposure-control regression. Gate 6 still requires suspend/resume, simple-IPA
automatic-exposure convergence, and manual privacy-LED lifetime observations.
Gate 7 passes discovery and one Firefox/Google Meet session plus two subsequent
processed starts in the same boot; application sessions across suspend/resume
remain unqualified.

1. Package build completes from the recorded source commit and produces v14
   artifacts with no DT binding or module build errors.
2. The installed v14 kernel boots, and the live endpoint bytes are
   `00 00 00 00 47 b4 52 c0`.
3. Standalone `imx681` binds at `1-0010`, detects model `0x0681`, and the old
   CCS limit/link-frequency warnings are absent. A probe at the turbine unit's
   `0x1a` address is not expected on this machine.
4. The media graph negotiates 3840x2640 RAW10 end to end through IMX681,
   CSIPHY2, CSID0, VFE0 RDI0, and the packed-RAW video node with no CSID crop.
5. At least ten exact-size frames capture without truncated buffers or emitted
   camera-path errors; sampled range, entropy, and temporal-difference checks
   pass, and decoded raw inspection shows stable, non-corrupt image data.
6. Repeated start/stop and suspend/resume pass. Exposure and gain visibly affect
   real frames, simple-IPA AE converges, and the privacy LED is on only while
   streaming.
7. The camera enumerates through PipeWire and completes repeated browser/WebRTC
   sessions without stale nodes or buffer-allocation failures.

Do not read camera MMIO after pipeline PM has disabled the camera clocks. The
`4d190bc96139` snapshots are confined to the powered STREAMOFF path before
CSID/VFE shutdown. The reference platform can hang the bus when camera
registers are read with the power/clock domain off.

## References

- [jglathe/linux_ms_dev_kit issue #74 resolution](https://github.com/jglathe/linux_ms_dev_kit/issues/74#issuecomment-5302651457)
- [Hardware-proven Snapdragon reference](https://github.com/karsies-wq/sp11-imx681-linux/tree/b08f76f40b8d7b715bd4da6aef484f86142cc147)
- [Hardware-validated turbine kernel bundle](https://github.com/turbineBMW/surface-pro-11-linux/tree/main/kernel)
- [Turbine libcamera source bundle](https://github.com/turbineBMW/surface-pro-11-linux/tree/main/userspace/libcamera)
- [Static Windows package oracle](https://github.com/geocausa/SP11X1ECamera/tree/41003427f47edd27cd98f846b4282327824ee16f)
- [Same-machine Windows C-PHY receiver oracle](https://github.com/geocausa/SP11X1ECamera/tree/68b1b3124a799060316d58131fe3f1511bdfd335)
- [Zero-packet handoff](https://github.com/geocausa/SP11X1ECamera/tree/collab/oaklee-zero-packet-handoff)
- [linux-surface PR #2156](https://github.com/linux-surface/linux-surface/pull/2156)
- [SP11 front-camera tracking issue #43](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/43)
- [ADR0066: SP11 IMX681 libcamera Simple IPA Integration](adr-0066-sp11-imx681-libcamera-simple-ipa.md)
- ADR-0002 (boot shim image strategy)
- ADR-0003 (Denali DTB and GRUB injection)
- ADR-0020 through ADR-0023 (Docker kernel build workflow)
- ADR-0052 (SP11 integration-fork kernel build)
