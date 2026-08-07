---
id: sp11-camera-foundation-research
title: "Surface Pro 11 Camera Foundation Research"
# prettier-ignore
description: Pinned public evidence, unresolved wiring, and fail-closed implementation gates for the Surface Pro 11 OLED camera stack.
---

# Surface Pro 11 Camera Foundation Research

## Status

The P4A.1 firmware worksheet and P4A.3 source gap analysis were completed on
2026-08-07. P4A.2 has a non-privileged target baseline in the
[Wave 1 read-only evidence report](sp11-wave1-read-only-target-evidence-20260807.md),
but regulator consumers, clock state, GPIO ownership, IOMMU ownership, and
power sequencing remain unknown.

P4A.4 must not start with the unmodified generic CAMSS node. The pinned ACPI
SDEV table denies handoff of `SISP` to the non-secure OS, while the generic
node assigns the same MMIO and interrupts to `csid_lite1` and `vfe_lite1`.
Disabling every external CSIPHY does not remove those CAMSS resources. A
reviewed resource-partition design and target ownership proof are therefore
prerequisites even for a sensor-free TPG canary.

No camera device, clock, regulator, GPIO, CCI controller, CSIPHY, sensor, or
illuminator was enabled while preparing this record. No target bus was scanned
and no chip-ID transaction was attempted.

## Immutable evidence set and classification

- SP11 ACPI dump commit
  [`1d0a2ce742b450fe3f65287adbe174ddccabe228`](https://github.com/linux-surface/acpidumps/tree/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom).
  The repository does not declare a repository-wide licence, so the dump is
  evidence only.
- Johan G. kernel baseline commit
  [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/tree/8f953dd060bc6e8fb86ca2ea8a92f258141c0169).
- Mainline comparison commit
  [`f9a2394a23482bfd330911e9c8295b71724feacd`](https://github.com/torvalds/linux/tree/f9a2394a23482bfd330911e9c8295b71724feacd).
- ST VD55G0 public datasheet
  [DS13170 Rev 10](https://www.st.com/resource/en/datasheet/vd55g0.pdf).

`Observed` below means directly present in a pinned public source or the
sanitized target report. `Inferred` means a correlation between two observed
facts. `Unknown` means no phandle, electrical value, active level, ownership,
or sequence may be written from the available evidence.

The target firmware selector is
[`SDFE = 0x9a`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L286-L290),
so only the matching conditional resource buffers apply.

## P4A.1 firmware resource worksheet

| Firmware object | Observed | Inferred | Unknown / implementation gate |
|---|---|---|---|
| `CAMP` | [`QCOM0C32`, UID `0x1b`, `MSHW0565`, dependencies, four MMIO ranges, three GSIs, and GIO0 pin 225](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51513-L51570) | `0xac15000` plus GSI `0x1ec` correlate to CCI0/SPI460; `0xac16000` plus GSI `0x12f` correlate to CCI1/SPI271 | Purpose of `0xac13000`, `0xac19000`, GSI `0x1eb`/SPI459, and GPIO225; GPIO polarity and ownership; which controller/master serves each sensor |
| `CAMS` | [`OVTID858`, UID `0x15`, `MSHW0561`, depends on `MPCS`, present](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51572-L51597) | The HID and public driver make OV13858 a strong identity hypothesis | Address, CCI controller/master, MCLK, supplies, reset/power-down, PHY, bus type, lane map/polarity, endpoint, orientation, and silicon response |
| `CAMF` | [`OVTI02C1`, UID `0x1a`, `MSHW0560`, depends on `MPCS`, present](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51599-L51624) | The upstream ACPI match makes OV02C10 a strong hypothesis | Actual silicon; every board resource; reconciliation with the public demonstration's IMX681, 3840x2640, single-C-PHY claim |
| `CAMI` | [`SMO55F1`, UID `0x1c`, `MSHW0562`, depends on `MPCS`, present](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51626-L51651) | Global-shutter family resemblance is possible | Exact model and register contract; the HID differs from VD55G0's published `SMO55F0`; all wiring and power resources |
| `FLSH` | [`QCOM0C27`, UID `0x19`, depends on `CAMP`, end-tag-only `_CRS`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51653-L51675) | None | Controller, PMIC path, GPIO, active state, current, pulse and duty limits, watchdog, thermal limits, and eye-safety constraints; keep absent/disabled |
| `MPCS` | The target `PBUF` exposes [PHY0 `0xace4000`/SPI477, PHY4 `0xacec000`/SPI122, and three TPG ranges](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51733-L51763) | These ranges correlate with generic CSIPHY0, CSIPHY4, and TPG0-2 | Sensor-to-PHY mapping, D-PHY versus C-PHY, lane count/order/polarity, and supplies; target evidence does not expose PHY1 or PHY2 |
| `JPGE` | [Depends on `CAMP` and `MMU0` and has JPEG MMIO/interrupt resources](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51789-L51822) | IORT output SID `0x18e0` correlates with one generic CAMSS tuple | Whether Linux DT may reassign that SID to CAMSS and whether JPEG must remain a separate owner |
| `VFE0` | The target `PBUF` provides [GSIs `0x1e8`, `0x1ef`, `0x1f1`, `0x1f5`, `0x1f0`, `0x1f4`, `0x31c`, and `0x31d`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51890-L51947) | SPI465/VFE0, SPI469/VFE-lite0, SPI464/CSID0, and SPI468/CSID-lite0 correlate directly | Purpose of SPI456, SPI463, SPI764, and SPI765; no target-branch evidence for CSID1/SPI466, CSID2/SPI431, VFE1/SPI467, or the secure SISP IRQs |
| `AONC` | [`QCOM0D06`, depends on `CAMF`, `_STA` returns zero](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51950-L51962) | It may be associated with the front-camera path | Function and ownership; it must remain disabled |
| `SISP` | [`QCOM0CCC` owns `0xacca000` length `0x4000` and GSIs `0x188`/`0x187`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L51965-L51997); [SDEV denies non-secure handoff](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/sdev.dsl#L24-L49) | The resources exactly overlap generic CAMSS `csid_lite1` and `vfe_lite1` | Whether a non-secure subset is supported at all and how firmware, secure software, and Linux must partition the block; this is a hard gate, not a value to guess |
| IORT | [`JPGE` maps SID `0x18e0`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/iort.dsl#L677-L686); [`GPU0.AVS0` maps `0x800`, `0x860`, `0x1800`, `0x1860`, `0x1900`, `0x1980`, and `0x19a0`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/iort.dsl#L1636-L1721) | Those eight SIDs equal the generic CAMSS IOMMU tuples | Exact DT ownership/handoff, domain attachment, SID flags, and coexistence with ACPI-named consumers must be proven live; correspondence is not permission |

None of the three sensor stubs supplies `_CID`, `_CRS`, `_DSD`, `_PLD`, a
power resource, or an endpoint graph. ACPI identity is therefore not board
wiring evidence.

The [`PMI_CAMF_1P8V` string](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/ssdt.dsl#L1780-L1794)
is a MAX34417 monitor-channel label. It is not a regulator provider, consumer
link, or power sequence.

## P4A.3 exact kernel gap analysis

### Generic X1E80100 topology

The pinned JG DTS defines disabled
[CCI0 and CCI1](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5558-L5634),
a disabled [CAMSS node](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5636-L5792),
four disabled [external CSIPHY nodes](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5794-L5880),
and [CAMCC](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5882-L5896).

| Component | Observed source capability | Gap and fail-closed result |
|---|---|---|
| CAMSS binding/topology | The JG split-PHY binding requires [13 regions, 21 clocks, 9 interrupts, up to 4 PHYs, 4 interconnect paths, up to 8 IOMMU tuples, 3 power domains, and ports](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/media/qcom,x1e80100-camss.yaml#L19-L168) | The schema has no representation for omitting secure `csid_lite1`/`vfe_lite1`. A subset needs a reviewed generic driver/binding design; deleting array entries locally is not acceptable |
| CSID/VFE/TPG capacity | Source defines [3 TPGs, 3 full plus 2 lite CSIDs, 2 full plus 2 lite IFEs, and four lines per IFE](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/platform/qcom/camss/camss.c#L4225-L4474). Source wins over older commit prose that says two CSIDs | Target ACPI proves only a subset of the generic interrupt topology. Capacity is not proof that all instances are available to the non-secure OS |
| Secure ownership | Generic DTS assigns [`0xacca000` to `csid_lite1`, `0xaccb000` to `vfe_lite1`](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5639-L5664) and [SPI359/SPI360 to their interrupts](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5709-L5726) | These exactly overlap secure `SISP`. The CAMSS driver still [initializes every VFE and CSID](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/platform/qcom/camss/camss.c#L4854-L4885), so disabled PHYs do not make an unmodified probe safe |
| TPG canary | Three four-lane TPG resource descriptions exist in source | TPG use still occurs inside the full CAMSS probe and cannot bypass the overlapping CSID/VFE resources. No CAMSS/TPG canary is authorized yet |
| CCI | The binding supports X1E80100 as a three-clock CCI-v2 fallback; the DTS addresses and interrupts correlate to `CAMP` | The driver matches the `qcom,msm8996-cci` fallback and, on probe, [enables clocks, resets the block, and registers child buses](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/i2c/busses/i2c-qcom-cci.c#L574-L629). Probe is an active transition. Keep both CCI nodes disabled until one verified controller/master, pin group, and sensor address are known |
| CSIPHY | The split binding describes a combo C-PHY/D-PHY and requires [0.8 V, 1.2 V, and `phy-type`](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/phy/qcom,x1e80100-mipi-csi2-combo-phy.yaml#L12-L62) | Generic DTS omits those board properties. The driver accepts only [MIPI D-PHY options, forces combo mode off, and fixes lane order/polarities](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/phy/qualcomm/phy-qcom-mipi-csi2-core.c#L94-L131); it also [enables clocks during probe](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/phy/qualcomm/phy-qcom-mipi-csi2-core.c#L187-L265). It cannot substantiate the demonstration's front C-PHY claim and must remain disabled |
| Clocks and GDSCs | CAMCC implements the referenced [CCI, CPAS, CSID, CSIPHY, IFE, and timer clock IDs](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/clk/qcom/camcc-x1e80100.c#L2360-L2422) and [IFE0, IFE1, and Titan Top GDSCs](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/clk/qcom/camcc-x1e80100.c#L2472-L2479) | Provider implementation does not establish current owner, permitted rates, or sensor MCLK routing. Selected live state/consumer evidence is still required |
| Interconnect | X1E80100 provider source contains [`SLAVE_CAMERA_CFG`](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/interconnect/qcom/x1e80100.c#L1525-L1537) and [CAMNOC HF/ICP/SF masters](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/interconnect/qcom/x1e80100.c#L1706-L1724); CAMSS applies [static runtime votes](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/platform/qcom/camss/camss.c#L4476-L4497) | Static generic votes are not target bandwidth validation. Safe subset behavior, vote ownership, suspend rollback, and measured mode-specific requirements remain unknown |
| IOMMU | Generic DTS lists [`0x800`, `0x860`, `0x1800`, `0x1860`, `0x18e0`, `0x1900`, `0x1980`, and `0x19a0`](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/hamoa.dtsi#L5741-L5748), matching the pinned IORT values | ACPI attributes seven mappings to `GPU0.AVS0` and one to `JPGE`. Exact live group/domain ownership and a documented DT handoff are required before attachment |
| Endpoint and power data | CAMSS source can skip unavailable external PHY nodes and includes a sensor-pad null guard | No source provides Denali sensor endpoints, addresses, PHY selection, lanes, supplies, reset lines, MCLKs, or sequencing. The two observed regulator names are not consumer proof |

### JG integration versus pinned mainline

The JG baseline contains a public camera series integrated from multiple
authors; it should not be attributed wholesale to the repository owner. The
important exact commits are:

- CAMSS core support
  [`1830cf0f56c3ced98bab3aea7ca2a0fa76e3a49b`](https://github.com/jglathe/linux_ms_dev_kit/commit/1830cf0f56c3ced98bab3aea7ca2a0fa76e3a49b),
  CCI DTS
  [`ab9dbadcc7866daee435f5b85f83f6b2e2037ef8`](https://github.com/jglathe/linux_ms_dev_kit/commit/ab9dbadcc7866daee435f5b85f83f6b2e2037ef8),
  CAMSS DTS
  [`5480338186f508a41bdb0216fcf569a803398526`](https://github.com/jglathe/linux_ms_dev_kit/commit/5480338186f508a41bdb0216fcf569a803398526),
  and CAMCC DTS
  [`d1bd8345c139cf00fe97b3112be7bc6af2505ad2`](https://github.com/jglathe/linux_ms_dev_kit/commit/d1bd8345c139cf00fe97b3112be7bc6af2505ad2).
- Split-PHY schema
  [`568e82fda67ea4ad527998eda2b2c8b9c4bf3c8d`](https://github.com/jglathe/linux_ms_dev_kit/commit/568e82fda67ea4ad527998eda2b2c8b9c4bf3c8d),
  CAMSS conversion to PHY handles
  [`92f99fe947466753117266837fec8c0aa55fd69b`](https://github.com/jglathe/linux_ms_dev_kit/commit/92f99fe947466753117266837fec8c0aa55fd69b),
  PHY API support
  [`780e8cf4663c12aacb8a8137c6e7e7265354fdb8`](https://github.com/jglathe/linux_ms_dev_kit/commit/780e8cf4663c12aacb8a8137c6e7e7265354fdb8),
  X1 legacy-PHY removal
  [`1b6e63739f48b4e7af0f698fd8117515c4af3bcb`](https://github.com/jglathe/linux_ms_dev_kit/commit/1b6e63739f48b4e7af0f698fd8117515c4af3bcb),
  PHY driver
  [`d2cd40a55f2390887c62b5b69bce9214c38ed8e9`](https://github.com/jglathe/linux_ms_dev_kit/commit/d2cd40a55f2390887c62b5b69bce9214c38ed8e9),
  and PHY DTS nodes
  [`7386f296e7baa0f12f034610526b00cb31f7a580`](https://github.com/jglathe/linux_ms_dev_kit/commit/7386f296e7baa0f12f034610526b00cb31f7a580).
- Local sensor-pad workaround
  [`7079159e337788f10ccc831b7d204e940f9d0ee7`](https://github.com/jglathe/linux_ms_dev_kit/commit/7079159e337788f10ccc831b7d204e940f9d0ee7).

At pinned mainline, the
[CAMSS binding](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/Documentation/devicetree/bindings/media/qcom,x1e80100-camss.yaml#L15-L176)
still describes inline PHY resources: 17 regions, 29 clocks, 13 interrupts,
and CAMSS-level PHY supplies. The JG baseline instead has 13/21/9 CAMSS
resources plus four external PHY handles. Patches for Denali must be based on
one coherent model and must not combine properties from the two schemas.

## P4B-P4D sensor identity gates

### P4B rear OV13858 candidate

Pinned mainline maps
[`OVTID858` to OV13858](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov13858.c#L1756-L1769),
reads a 24-bit [`0x00d855` ID at `0x300a`](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov13858.c#L1495-L1512),
and implements [4224x3136 over four D-PHY lanes](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov13858.c#L940-L995).
This strongly supports the candidate, not its board wiring.

The driver requires 19.2 MHz, has no OF match or generic regulator/reset
sequence, and explicitly [assumes ACPI-domain power](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov13858.c#L1658-L1723).
Before an identity read, prove one CCI controller/master, one address, MCLK,
rails, reset/power-down, and safe off-state. Ten controlled reads of
`0x00d855` unlock implementation; no address scan is permitted.

### P4C front OV02C10 versus IMX681 gate

Pinned mainline maps
[`OVTI02C1` to OV02C10](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov02c10.c#L984-L1005).
Its contract is [`0x5602` at register `0x300a`](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov02c10.c#L793-L809),
with [1928x1092, three supplies](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov02c10.c#L345-L368),
19.2 MHz, and [one or two D-PHY lanes](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/ov02c10.c#L811-L859).

The public demonstration instead claims Sony IMX681, 3840x2640 RAW10, and one
C-PHY trio. No licensed public source currently reconciles that claim with
the ACPI ID, upstream driver, or JG D-PHY-only split-PHY implementation. Both
models remain hypotheses. Only after the exact power and bus path is proved
may the reviewed OV02C10 driver read exactly `0x300a` at one documented
address. Ten `0x5602` results unlock the OV02C10 branch; any mismatch stops
implementation. Do not invent or import an IMX681 register table.

### P4D IR `SMO55F1` versus VD55G0 gate

The official VD55G0 datasheet describes 644x604 including borders, global
shutter, RAW8/RAW10, one D-PHY lane, a 6-27 MHz input clock, three supplies,
active-low shutdown, and published PNP ID `SMO55F0`. The target ACPI HID is
`SMO55F1`.

Pinned mainline's VD55G1 driver is a different-family reference: it recognizes
[`0x53354731`/`0x53354733` at register `0x0000`](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/vd55g1.c#L30-L36),
uses an [804x704 array](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/vd55g1.c#L115-L139),
and matches only
[`st,vd55g1`/`st,vd65g4`](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/drivers/media/i2c/vd55g1.c#L2035-L2040).
Its binding fixes address `0x10` and exposes
[four illumination-strobe GPIOs](https://github.com/torvalds/linux/blob/f9a2394a23482bfd330911e9c8295b71724feacd/Documentation/devicetree/bindings/media/i2c/st,vd55g1.yaml#L14-L63).
It must not be relabelled, instantiated, or used as the chip-ID contract for
the unknown target device.

ST publishes an [STSW-IMG505](https://www.st.com/en/embedded-software/stsw-img505.html)
package page, but download and licence review require a human. P4D remains
blocked until a licensed VD55G0 implementation basis and a safe, model-specific
identity contract exist. Ambient-light identification and streaming must keep
`FLSH`, VCSEL, LEDs, and every strobe control absent or disabled.

## Read-only target inventory and remaining discriminators

The [central sanitized report](sp11-wave1-read-only-target-evidence-20260807.md#p4--camera-foundation)
records that `I2C_QCOM_CCI`, `VIDEO_QCOM_CAMSS`, `VIDEO_OV02C10`, and
`VIDEO_OV13858` are modules in the v3 configuration, but none was loaded. It
found no named live CAMSS/CCI/CSIPHY DT directory, no bound CAMSS/CCI driver,
and no media, video, or V4L subdevice node. A camera reserved-memory boot
record exists. Regulators named `vreg_l1c_1p2` and `vreg_l2c_0p8` exist by
name only; their consumers and sequencing remain unknown.

The only safe next live discriminator set is bounded and read-only:

1. Re-run the sanitized collector and compare scalar/config/topology sections;
   do not retain raw access details or full logs.
2. Read existing live DT `compatible`, `reg`, `interrupts`, `iommus`,
   `power-domains`, `clocks`, `status`, and graph properties only for nodes
   whose ranges match CCI `0xac15000`/`0xac16000`; IFE `0xac62000`/
   `0xac71000`; CSID/IFE-lite `0xacb6000`, `0xacb7000`, `0xacb9000`,
   `0xacbb000`, `0xacc6000`, `0xacc7000`, `0xacca000`, or `0xaccb000`;
   TPG `0xacf6000`-`0xacf8fff`; or CSIPHY `0xace4000`, `0xace6000`,
   `0xace8000`, and `0xacec000`.
3. Read `/proc/iomem` ownership for those exact ranges and selected
   `/proc/interrupts` entries for SPI122, 271, 359, 360, 431, 459-469,
   477-479, 764, and 765. Record absence as absence, not proof of availability.
4. Read existing platform-driver bindings, module state, media topology, and
   IOMMU-group symlinks. Do not bind, unbind, load, or unload anything.
5. If debugfs is already mounted and readable, copy only selected camera clock,
   regulator, GPIO-owner, and pinctrl rows for the candidate ranges and pins.
   Do not mount debugfs or write a control to collect this evidence.
6. Reconcile every observation against `CAMP`, `MPCS`, `VFE0`, `SISP`, IORT,
   and the exact JG node before proposing a DT property. Unknown consumers or
   sequencing remain blockers.

This set explicitly excludes `i2cdetect`, `i2cget`, raw CCI transactions,
`devmem`, GPIO export, dynamic-debug writes, module binding, regulator or
clock writes, and any sensor/VCSEL activation. Future single-address chip-ID
reads are controlled experiments after P0 and the board-resource gates; they
are not part of this read-only set.

## Programme consequences and branch sequence

1. Keep `lsp11-x-camera-foundation-7.2-rc5` at desk/source and read-only
   evidence. Before P4A.4, record the SISP conflict in the source ledger and
   replace the unmodified full-CAMSS canary with a reviewed non-secure resource
   partition plus ownership proof. If no upstreamable partition exists, P4A
   remains blocked.
2. Keep `lsp11-x-camera-ov13858-7.2-rc5` blocked until the exact rear power,
   CCI, address, PHY, and off-state path is proven. Add generic OF/power support
   separately from Denali data, then perform ten controlled ID reads.
3. Keep `lsp11-x-camera-front-id-7.2-rc5` as an identity gate. Create
   `lsp11-x-camera-ov02c10-7.2-rc5` only after ten `0x5602` results.
4. Keep `lsp11-x-camera-vd55g0-id-7.2-rc5` blocked on `SMO55F1`, licence,
   model-specific identity, and verified resources. Do not use VD55G1 as a
   substitute.
5. Do not create an illumination branch until the IR sensor is complete and a
   public electrical and eye-safety basis passes human review.

Only one sensor branch may be integrated or booted at a time. Every first boot
is one-shot and retains the known-good v3 persistent fallback.

## Explicit no-go boundary

- No generic CAMSS probe while it claims secure SISP MMIO or interrupts.
- No guessed CCI master, address, CSIPHY, bus type, lane map, polarity, MCLK,
  reset GPIO, regulator, power sequence, orientation, or rotation.
- No sensor address copied from a binding example or generic datasheet.
- No enabling PHY1 or PHY2 merely because generic SoC source provides them.
- No dummy or fixed always-on regulator added to force a probe.
- No ACPI HID treated as final silicon proof without a controlled identity
  result.
- No VD55G1 source, compatible, address, or ID contract relabelled as VD55G0.
- No raw frame, firmware dump, or full diagnostic log published without
  privacy and metadata review.
- No hardware experiment before P0 proves physical recovery and one-shot
  fallback.
- No illumination activation while any controller, limit, timeout, thermal,
  or eye-safety fact is unknown.

## Upstream destinations

Generic secure-resource partitioning, CAMSS, CCI, PHY, or sensor changes go to
their Linux media, I2C, PHY, arm64 Qualcomm, and DT maintainers as separate
reviewable commits. Denali board graph data remains separate from generic
driver work. Build recipes, one-shot packaging, sanitized evidence, and
experimental-release policy remain in this support repository.
