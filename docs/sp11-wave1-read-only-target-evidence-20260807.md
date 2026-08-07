# Surface Pro 11 Wave 1 read-only target evidence — 2026-08-07

Status: Evidence review; no feature implementation or hardware mutation

## Scope and privacy boundary

This report records a bounded, read-only observation of the OLED Surface Pro
11 target for P0 recovery state and the P2, P4, P6, and P7 Wave 1 research
tracks. It is not a feature acceptance report.

The primary observation used
`scripts/collect-sp11-feature-parity-inventory.sh` schema 3. The collector
SHA-256 for this run was:

```text
dd70adc33b04079ab1a0d51f13d9f056877ed5ea7bf3dfb2a262fa86ee0dfe7c
```

The connection endpoint, account name, host name, serials, UUIDs, network
identifiers, and raw reports were not retained. The optional kernel-log slice
was bounded and manually reviewed. During review, the filter was strengthened
to redact one- and two-byte `bytes=` fields as well as longer byte arrays; no
controller byte values from that slice are reproduced here.

No command used `sudo`. No module was loaded or unloaded, no sysfs value was
written, no device node was opened for data capture, and no suspend, camera,
audio playback, boot, or GRUB operation was attempted.

## Common baseline

| Field | Observation | Meaning |
| --- | --- | --- |
| Model | Microsoft Surface Pro 11th Edition, OLED | This does not establish LCD equivalence |
| Distribution | Ubuntu 26.04, AArch64 | Observation environment only |
| Running ABI | `7.2-rc5-jg-0sp11v3-qcom-x1e` | Matches the configured recovery ABI |
| Live compatible | `microsoft,denali-oled`, `microsoft,denali`, `lenovo,thinkpad-t14s`, `qcom,x1e80100` | Runtime DT identity, not source provenance by itself |
| GRUB `saved_entry` | Still names `7.2-rc5-jg-0sp11v2-qcom-x1e` | P0.7 remains blocked; ADR0053 must reject apply |
| GRUB `next_entry` | Empty | No one-shot selection was queued |

The target also retains multiple older qcom-x1e kernels. Their presence is not
proof that each is bootable. The persistent saved fallback must be migrated to
the running v3 entry and physically boot-tested before P0.8.

## P2 — G6 transport and HID ownership

The source and lifecycle conclusions for this target baseline are recorded in
[G6 HIDRAW and IPTSD research](sp11-g6-hidraw-iptsd-research.md).

| Field | Observation | Classification |
| --- | --- | --- |
| SPI device | `spi0.0`, driver `mshw0485-touch` | Observed |
| Firmware identity | modalias `spi:mshw0485`, compatible `microsoft,mshw0485` | Observed |
| Current input node | `Microsoft Surface G6 Touch`, `BUS_SPI`, event and mouse handlers | Observed |
| Runtime profile | `profile=phase75`, `initialization_stage=set-feature56`, `mode_enabled=1` | Observed; distinct from the Phase 91 source pin |
| Recovery counters | one hardware recovery, one success, zero recorded reset/protocol/transport failures | Observed scalar snapshot; not a reliability result |
| IPTSD | executable absent; service/template inactive; no matching generic udev rule | Observed |
| G6 HID child | no HID child link beneath `spi0.0`; no descriptor-like sysfs file | Observed |
| Existing hidraw nodes | four Surface HID nodes with public IDs `045e:09ae`, `045e:0991`, `045e:09b0`, and `045e:09af` | Observed; none is the G6 SPI child |

The current G6 input capabilities expose touch-oriented event/absolute axes.
They do not establish a pen path. The existing hidraw nodes belong to other
Surface HID devices, so their presence must not be used as evidence that the
G6 transport already has hidraw support.

P2.1 is `evidence-review` for topology and runtime-profile facts. Descriptor
identity, IRQ-rate/DMA evidence, descriptor retention, the G6 HID child,
report-ID/size diagnostics, and synthetic lifecycle tests remain absent. No
report payload or pen sample was collected.

## P4 — Camera foundation

The pinned firmware and kernel resource analysis is recorded in
[camera foundation research](sp11-camera-foundation-research.md).

| Field | Observation | Classification |
| --- | --- | --- |
| Kernel configuration | `I2C_QCOM_CCI`, `VIDEO_QCOM_CAMSS`, `VIDEO_OV02C10`, and `VIDEO_OV13858` are modules | Observed |
| Loaded camera modules | none of those modules was loaded | Observed |
| Live camera DT nodes | no CAMSS, CCI, CSIPHY, ISP, or camera-named node was exposed in `/proc/device-tree` | Observed for the active DT |
| Media interfaces | no media, video, or V4L subdevice node | Observed |
| Camera rails | `vreg_l1c_1p2` and `vreg_l2c_0p8` exist | Observed names only; consumers and sequencing remain unknown |
| Reserved memory | the filtered boot log records a non-reusable camera reservation | Observed; not proof of a working camera graph |

This establishes the starting condition for P4A.2: the active image has no
usable camera media graph and no bound CAMSS/CCI driver. It does not identify
any sensor, CCI address, PHY, lane map, clock, GPIO, regulator consumer, or
power sequence. The front-camera `OVTI02C1` identity question therefore
remains a hard gate; no bus scan or chip-ID read was performed.

Privileged regulator-consumer, clock, GPIO-owner, and IOMMU evidence is still
required, but it is no longer the only blocker to a sensor-free canary. Pinned
ACPI assigns secure, non-handoff `SISP` the same MMIO and interrupts that the
generic JG CAMSS node assigns to `csid_lite1` and `vfe_lite1`. P4A.4 therefore
requires a reviewed non-secure resource partition and live ownership proof;
the unmodified CAMSS node must not probe. VCSEL work remains prohibited.

## P6 — Passive suspend and CPU-idle baseline

The pinned source correlation and bounded no-write follow-up procedure are
recorded in [power and SAM research](sp11-power-sam-research.md).

| Field | Observation | Classification |
| --- | --- | --- |
| `mem_sleep` | `s2idle [deep]` | `deep` was selected at observation time; no suspend was initiated |
| PSCI | firmware reported PSCI 1.1, OSI support, and an initialized CPU PM domain topology | Observed filtered boot log |
| cpuidle driver/governor | `psci_idle` / `menu` | Observed |
| State 0 | `WFI`, latency 1, residency 1, enabled | Observed |
| State 1 | `cpu-sleep-0`, description `ret`, latency 500, residency 600, enabled | Observed |
| Suspend statistics | zero successes and zero failures since the exposed counters were initialized | Observed; no functional conclusion |

The state called `cpu-sleep-0` must not be equated with the demonstration's
“Denali” label without source and runtime evidence. Usage and residency
counters prove only that cpuidle states have been entered; they are not a
suspend/resume acceptance test.

The pinned baseline already detaches Hamoa `cl5` from the selectable cluster
power domains. That source history is not target causality, and the observed
`cpu-sleep-0` state must be correlated with the active DT before proposing a
candidate ABI. P6.1 is `evidence-review`, while P6.2 remains blocked by P0. No
suspend cycle, trace enable, wake-source experiment, or idle-state write was
performed.

## P7 — Surface Aggregator and platform profiles

| Field | Observation | Classification |
| --- | --- | --- |
| Surface Aggregator core | loaded with battery, charger, HID, hub, registry, and tablet-mode clients | Observed |
| Thermal-sensor client | live device `01:03:01:00:02`, modalias `ssam:d01c03t01i00f02`, unbound | Observed; the pinned registry names `f02` as the sensor client |
| Installed profile module | `surface_platform_profile.ko.zst`, GPL, alias `ssam:d01c03t01i00f01`; module not loaded | Observed |
| Alias match | installed module alias does not match the live `f02` device | Observed identity mismatch; no alias expansion or protocol probe is permitted |
| Platform-profile sysfs | absent | Observed |
| CPU frequency | three SCMI policies; `scmi` driver, `performance` governor, 710400–3417600 kHz range | Observed snapshot |

The `f01`/`f02` mismatch is an identity and protocol gate, not permission to add
an alias. The pinned SP11 registry deliberately instantiates sensor `f02` and
not profile `f01`; the generic profile driver matches only `f01`. P7.1 is
`evidence-review` for live topology and source identity. The public typed
protocol basis defines an active `f01` GET and a no-response SET, but no
SP11-specific capability query was found. An exact SP11 `f01` basis, strict
response validation, target-derived choices, SET readback, and rollback must
precede any active query or write. The demonstration's frequency ceiling is
not imported as a policy constant.

## Reproduction boundary

The public collector can be streamed without installing it on the target:

```sh
ssh sp11-lab-host 'bash -s --' \
  < scripts/collect-sp11-feature-parity-inventory.sh
```

The optional log section is local-sensitive even after filtering:

```sh
ssh sp11-lab-host 'bash -s -- --include-kernel-log' \
  < scripts/collect-sp11-feature-parity-inventory.sh
```

Review that output manually. Do not commit raw inventories or access details.

## Resulting task state

- P0.6 remains complete; the new run agrees with the recorded recovery and
  privacy boundary.
- P0.10 is complete; public issues
  [#22](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/22) through
  [#31](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/31) record the
  required tracking and rollback metadata without changing any feature gate.
- P2.1, P4A.2, P6.1, and P7.1 advance to `evidence-review`, not `complete`.
  The associated desk/source gates P2.2, P4A.1, and P4A.3 are complete.
- P4A.4 is explicitly blocked on secure SISP resource partitioning as well as
  the remaining privileged ownership evidence.
- P0.7-P0.9 remain blocked on privileged migration and physical recovery.
- The programme invariant still prohibits feature mutations before P0 exits.
