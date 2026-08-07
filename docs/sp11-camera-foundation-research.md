---
id: sp11-camera-foundation-research
title: "Surface Pro 11 Camera Foundation Research"
# prettier-ignore
description: Pinned public evidence, unresolved wiring, and fail-closed implementation gates for the Surface Pro 11 OLED camera stack.
---

# Surface Pro 11 Camera Foundation Research

## Status

Desk research complete on 2026-08-07. No camera device, clock, regulator,
GPIO, CCI controller, CSIPHY, or illuminator was enabled while preparing this
record. Hardware implementation remains blocked by the P0 recovery gate and
the privileged resource-ownership observations identified below.

The central correction is important: public evidence maps the front ACPI ID
`OVTI02C1` to OmniVision OV02C10. It does not support treating the device as a
Sony IMX681. The public demonstration remains useful as feasibility evidence,
but its sensor names, modes, and private implementation are not source
provenance.

## Immutable evidence set

- SP11 ACPI dump commit
  [`1d0a2ce742b450fe3f65287adbe174ddccabe228`](https://github.com/linux-surface/acpidumps/tree/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom).
  The repository does not declare a repository-wide licence, so the dump is
  evidence only.
- Johan G. kernel baseline commit
  [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/tree/8f953dd060bc6e8fb86ca2ea8a92f258141c0169).
- Mainline cross-check commit
  [`f9a2394a23482bfd330911e9c8295b71724feacd`](https://github.com/torvalds/linux/tree/f9a2394a23482bfd330911e9c8295b71724feacd).
- ST VD55G0 public datasheet
  [DS13170 Rev 10](https://www.st.com/resource/en/datasheet/vd55g0.pdf).

The exact ACPI camera namespace is in
[DSDT lines 51513-51962](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51513-L51962).
The dump sets `SDFE` to `0x9a`, so only the matching conditional resource
branches are relevant.

## Firmware observations and limits

| Node | Pinned observation | What remains unknown |
|---|---|---|
| `CAMP` | `QCOM0C32` / `MSHW0565`; MMIO includes `0xac15000` and `0xac16000`, with interrupts that correlate to CCI0 SPI 460 and CCI1 SPI 271; it also exposes an unclassified interrupt and GPIO 225 | Sensor-to-CCI master assignment, the remaining ranges and interrupt, GPIO purpose and polarity |
| `CAMS` | `OVTID858` / `MSHW0561`, UID `0x15`, present and dependent on `MPCS` | Address, CCI master, PHY, supplies, MCLK, reset, endpoint, orientation |
| `CAMF` | `OVTI02C1` / `MSHW0560`, UID `0x1a`, present and dependent on `MPCS` ([exact node](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51599-L51624)) | The HID is a strong OV02C10 hypothesis, but all board wiring and the actual chip response remain unknown |
| `CAMI` | `SMO55F1` / `MSHW0562`, UID `0x1c`, present and dependent on `MPCS` | Exact sensor model and every board resource; the ID differs from VD55G0's published `SMO55F0` PNP ID |
| `MPCS` | For firmware variant `0x9a`, resources correlate to CSIPHY0 at `0xace4000`, CSIPHY4 at `0xacec000`, and three TPG ranges | Sensor-to-PHY mapping, PHY type, lane map and polarity; no basis exists for enabling PHY1 or PHY2 |
| `FLSH` | `QCOM0C27`, dependent on `CAMP`, with an empty resource template | Controller, PMIC path, GPIO, active state, current, pulse limits, watchdog, thermal and eye-safety constraints |

None of the three sensor stubs has `_CRS`, `_DSD`, `_PLD`, a power resource,
or an endpoint graph. ACPI identity is therefore not a substitute for target
wiring evidence.

The `PMI_CAMF_1P8V` string in the MAX34417 power-monitor description is a
monitor-channel label. It is not a regulator provider, consumer link, or power
sequence.

## Kernel-platform evidence

The exact baseline contains disabled CCI0 and CCI1 nodes at the addresses and
interrupts observed in ACPI. Its disabled CAMSS node includes four CSIPHY
phandles, three TPGs, three full CSIDs plus two lite CSIDs, and two full IFEs
plus two lite IFEs. Source is authoritative where older commit prose describes
only two CSIDs.

The CAMSS driver skips unavailable PHY nodes and contains the existing
sensor-pad null-dereference workaround. This makes a sensor-free CAMSS/TPG
canary plausible, but not proven. The first camera patch must enable only the
CAMSS core; both CCI controllers, all PHYs, all sensors, and `FLSH` remain
disabled. Five one-shot boots, schema checks, media topology, and clock/rail/
IOMMU review are required before that foundation can merge.

Potential board resources are deliberately not treated as wiring facts:

- the Denali DTS defines otherwise-unconsumed 1.2 V and 0.8 V regulators whose
  labels resemble the combo-PHY binding example;
- generic TLMM camera MCLK functions exist on GPIOs 96-99;
- generic CCI functions exist on GPIOs 101-106 and 235-236; and
- GPIO 225 is labelled `cam_indicator_en` in the Denali source.

Each candidate needs read-only ownership/state evidence before a phandle or
active level is written.

## Sensor identity matrix

### Rear candidate

The exact baseline's OV13858 driver maps ACPI ID `OVTID858`, reads chip ID
`0x00d855` at register `0x300a`, and contains 4224x3136 RAW10 among its modes.
See the pinned
[driver identity table](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov13858.c#L1495-L1512).
This strongly supports an OV13858 hypothesis, but the driver currently assumes
ACPI-domain power management and has no OF match. Generic DT power support must
be reviewed separately from any Denali endpoint.

Acceptance begins with ten controlled `0x00d855` identity reads at one verified
address. It does not begin with an address scan.

### Front identity gate

The exact baseline maps `OVTI02C1` to `ov02c10` in its
[ACPI match table](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c#L1050-L1072).
That driver verifies chip ID `0x5602` at register `0x300a`, requires a 19.2 MHz
clock, and exposes 1928x1092 RAW10 over one or two D-PHY lanes. See its
[identity check](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c#L859-L875),
[mode data](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c#L342-L369),
and [lane validation](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c#L877-L920).
The binding identifies OV02C10 as a 2 MP device; its example address is not SP11
wiring evidence.

P4C is therefore an identification gate on branch
`lsp11-x-camera-front-id-7.2-rc5`. If ten controlled reads return `0x5602`, the
implementation branch may be named `lsp11-x-camera-ov02c10-7.2-rc5`. If the
result differs, stop. Do not write an IMX681 driver or copy the demonstration's
C-PHY and 3840x2640 values without an independently licensed public basis and
target proof.

### IR candidate

The official VD55G0 datasheet describes 644x604 including borders, global
shutter, RAW8/RAW10, one D-PHY lane, a 6-27 MHz input clock, three supplies, and
active-low shutdown. Those properties fit the public demonstration, but its
PNP ID is `SMO55F0`; the SP11 ACPI node is `SMO55F1`.

The baseline's VD55G1 driver is architectural reference only. Its model IDs,
dimensions, and compatible differ and it must not be relabelled as VD55G0.
ST publishes an [STSW-IMG505](https://www.st.com/en/embedded-software/stsw-img505.html)
package page, but download and licence review require a human. No code may be
copied until its exact terms and redistribution boundary are approved.

The IR sensor must be identified and stream ambient-light frames while the
illuminator remains absent or disabled. `FLSH`, VCSEL GPIOs, strobe controls,
and unrestricted userspace switches remain a hard no-go without a public,
human-reviewed electrical and eye-safety basis.

## Read-only target inventory gate

The schema-3 collector was run read-only on the target on 2026-08-07. It
confirmed that `I2C_QCOM_CCI`, `VIDEO_QCOM_CAMSS`, `VIDEO_OV02C10`, and
`VIDEO_OV13858` are modules in the running v3 configuration. No IMX681,
VD55G0, or VD55G1 configuration symbol was present. No related CCI, CAMSS, or
sensor module was loaded; no media, video, or V4L subdevice node existed; and
no matching enabled camera node appeared in the live device tree.

That closes the non-privileged inventory step and confirms a dormant camera
stack. It does not establish GPIO, regulator, clock, pinctrl, or IOMMU
ownership. Those selected, privileged read-only observations remain required
after the P0 recovery contract is proven.

Run the sanitized collector first:

```bash
./scripts/collect-sp11-feature-parity-inventory.sh --include-kernel-log
```

Review its output before publication. For the camera foundation, also record
only the selected live DT/platform nodes for `ac15000`, `ac16000`, `acb6000`,
`ace4000`, `ace6000`, `ace8000`, and `acec000`; media device topology; and the
camera IOMMU group. If debugfs is already mounted and readable, inspect only
the camera-related regulator, clock, GPIO, and pinctrl rows. Do not mount it as
part of this gate.

The inventory must answer:

1. whether `I2C_QCOM_CCI`, `VIDEO_QCOM_CAMSS`, `VIDEO_OV02C10`,
   `VIDEO_OV13858`, and the VD55 options are enabled;
2. whether any CCI, CAMSS, CSIPHY, sensor, media, or video driver is already
   bound;
3. whether candidate GPIO and regulator resources have another owner; and
4. whether enabling only CAMSS can leave all camera and illumination rails
   unchanged.

Do not use `i2cdetect`, `i2cget`, raw CCI transactions, dynamic-debug writes,
module binding, GPIO export, regulator enabling, or clock enabling for this
inventory. A bus scan is not observationally safe for arbitrary camera
devices.

## Branch and evidence sequence

1. `lsp11-x-camera-foundation-7.2-rc5`: evidence worksheet, sanitized
   inventory, then a CAMSS-only/TPG canary with every CCI, PHY, sensor, and
   illuminator disabled.
2. `lsp11-x-camera-ov13858-7.2-rc5`: generic OF/power support first, followed
   by one verified rear path and ten identity reads before streaming.
3. `lsp11-x-camera-front-id-7.2-rc5`: discriminate OV02C10 from IMX681 using
   one reviewed identity path; create an OV02C10 implementation branch only if
   `0x5602` is repeatable.
4. `lsp11-x-camera-vd55g0-id-7.2-rc5`: resolve `SMO55F1`, implementation
   licence, and actual chip identity with illumination disabled.
5. No illumination branch until the IR sensor is complete and a public
   electrical/eye-safety basis passes human review.

Only one sensor branch is integrated or booted at a time. Every first boot is
one-shot and retains the known-good v3 persistent fallback.

## Explicit no-go boundary

- No guessed CCI master, address, CSIPHY, bus type, lane map, polarity, MCLK,
  reset GPIO, regulator, power sequence, orientation, or rotation.
- No sensor address copied from a binding example or generic datasheet.
- No enabling PHY1 or PHY2 merely because the generic SoC provides them.
- No dummy or fixed always-on regulator added to force a probe.
- No ACPI HID treated as final silicon proof without a controlled identity
  result.
- No VD55G1 source relabelled as VD55G0.
- No raw camera frame, firmware dump, or full diagnostic log published without
  privacy and metadata review.
- No hardware experiment before P0 proves physical recovery and one-shot
  fallback.
- No illumination activation while any controller, limit, timeout, thermal,
  or eye-safety fact is unknown.

## Upstream destinations

Generic CAMSS, CCI, PHY, or sensor driver and binding changes go to their Linux
media, I2C, PHY, or arm64 DT maintainers as separate reviewable commits. Denali
board graph data remains separate from generic driver work. Build recipes,
one-shot packaging, sanitized evidence, and experimental release policy remain
in this support repository.
