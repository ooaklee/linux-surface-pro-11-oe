---
id: adr-0068-sp11-usb4-dp-integration
title: "ADR0068: SP11 USB4 and DisplayPort Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for starting the Surface Pro 11 USB4 integration at kernel milestone v20 with public Qualcomm USB43DP PHY support, a production-safe retimer fallback, proprietary-firmware boundaries, and evidence-gated USB4 DisplayPort tunnelling.
---

# ADR0068: SP11 USB4 and DisplayPort Integration

## Status

Accepted for the source and static-build portion of the
`7.2.0-jg-0sp11v20` implementation milestone on 2026-08-30. Runtime USB4
enablement is not accepted: the production Denali device tree still disables
USB4 at the PS8830 retimers, and this branch enables no host-router consumer.

### Kernel integration record

The implementation is reviewed in
[linux_ms_dev_kit-sp11 PR 24](https://github.com/ooaklee/linux_ms_dev_kit-sp11/pull/24)
on `sp11/integration-7.2.x-usb4-support`. This immutable record distinguishes
the five public backports, the separate downstream lifecycle fix, and the
packaging-only commits:

| Role | Exact source |
|---|---|
| Linux 7.2 integration base | [`d915d679423e`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/d915d679423e002b27f60e6b27116a03e18a96d0) |
| Public USB43DP binding | [`076072b40299`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/076072b402996a09319cf5985fad10e668a1d12e) |
| Public TBT PHY mode | [`b343d089a705`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/b343d089a705665764648092624bd3afc05feb78) |
| Public preliminary USB4 PHY lifecycle | [`d2ddf9dce2ef`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/d2ddf9dce2ef132b551f86ca32a57b473f66c0f3) |
| Public Hamoa USB4/TBT3 configuration | [`c6d1b64af29f`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/c6d1b64af29f2f2a3b716d89e5f3194fcc2f1ca6) |
| Public Hamoa PHY-to-router clocks | [`8564ca38642c`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/8564ca38642cade24dd02fc2ceb8fc3a22f8a275) |
| Downstream ownership and rollback hardening; exact validated code head | [`5b5f1d124b7a`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/5b5f1d124b7ad43b9aac076ad65aa27fa3689ce9) |
| `sp11v20` package boundary | [`bb0e70e6684a`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/bb0e70e6684ac1c41c59eeb6a7b3b5e2539b5d0f) |
| Guarded-scope clarification; final kernel PR head | [`e056649b9b56`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/e056649b9b56622fedd806134d4f79dcf251a2f0) |
| Upstream submission | [Qualcomm USB43DP PHY v4](https://patchew.org/linux/20260820-topic-usb4phy-v4-0-aec9d2cb31f6@oss.qualcomm.com/), mbox SHA-256 `cf05fc8da482ab8085cfe3eeb37798b62bc74c5b2a73f8e74a8cc9b0dc93d3e2` |

## Context

The Surface Pro 11 has two USB-C connectors. Direct USB-C DisplayPort Alt Mode
already works. DisplayPort carried through a USB4 dock is a different path: it
requires the USB4 host router, retimer sideband connection, link training, and
USB4 Connection Manager to create a DisplayPort tunnel before DRM can drive the
monitor.

A private, reviewed same-device Windows capture reports a matched top-port
attach with USB4, PCIe, and DisplayPort tunnels, but it does not disclose the
retimer-to-controller sideband sequence needed by Linux. A publishable
redacted derivative remains pending. This private report informs the later
test matrix only; it is not committed, linked as public evidence, treated as
source-code provenance, or counted as Linux runtime validation.

The Linux 7.2 integration base already contains:

- the non-PCI Thunderbolt NHI preparation series;
- X1E80100 USB4 GCC clock and power-domain definitions;
- both Denali Type-C connector graphs and PS8830 retimers;
- USB4, Type-C Thunderbolt Alt Mode, PS8830, and QMP kernel configuration; and
- `parade,disable-usb4`, which rejects USB4 negotiation and preserves working
  direct DisplayPort Alt Mode while the router path is incomplete.

Qualcomm's public
[USB43DP PHY v4 series](https://patchew.org/linux/20260820-topic-usb4phy-v4-0-aec9d2cb31f6@oss.qualcomm.com/)
adds the next independently useful layer. Its five patches define the USB4
PHY specifier and TBT PHY mode, add USB4 lifecycle support to the QMP combo
driver, provide X1E80100 electrical tables, and describe Hamoa's P2RR2P
PHY-to-router clocks. The series was based on `next-20260820`; it is not yet in
Linus's tree. Its cover letter explicitly says that a separate router driver
will follow; no published, usable in-tree router implementation is part of the
PHY series or this integration.

[Issue 52](https://github.com/ooaklee/linux-surface-pro-11-oe/issues/52)
bounds the current hardware failure. Experimental code can load controller
firmware, initialize rings and DROM, register a USB4 domain and host router,
enter the TBT QMP mode, and tell the PS8830 that TBT is connected. Link training
does not start: the controller waits for its sideband receive connection and
reports failure to read the sideband link configuration.

The X1P-64-100 investigation in issue 52 also reports hard locks after raw
reads of controller windows, attempted interrupt-sequence replay, and repeated
USB4 power-domain activation. Those addresses are not a verified X1E80100
register map and are deliberately not repeated here. Raw access and replay are
prohibited on both variants. Until X1E recovery behavior is qualified, use the
X1P result as a conservative rule: run at most one active USB4 experiment per
cold power cycle and retain a known-good kernel recovery path.

The old experimental host-router branches are evidence, not merge sources.
They combine useful observations with proprietary firmware dependencies,
unsafe register probes, generated binaries, logs, local artifacts, and
retracted experiments. Merging one wholesale would make the integration less
reviewable and could hard-lock the device.

## Decision

### Version and branch boundary

USB4 work starts at `7.2.0-jg-0sp11v20` on
`sp11/integration-7.2.x-usb4-support`. Versions v15 through v19 remain
available to the independent pen and touch work. USB4 commits must remain
independently reviewable and revertible; this branch does not absorb the open
pen integration branches.

### First v20 kernel increment

Carry Qualcomm's five public USB43DP PHY v4 patches as provenance-preserving
commits on top of the current `sp11/integration-7.2.x` branch. Patches 1, 2,
and 5 retain stable public-series patch IDs; patches 3 and 4 contain only the
contextual conflict resolution required by the 7.2 QMP refactor.

Add one integration-specific commit after that series to track common-block,
regulator, runtime-suspend, and physical USB ownership; make mode and
orientation changes transactional; restore the former PHY state on failure;
and reject unsafe DP-only or active-DisplayPort transitions. This hardening
improves lifecycle correctness but is not runtime USB4 evidence.

The v20 changelog must describe this as preliminary PHY groundwork. The PHY
series alone does not establish full USB4 support, a USB4 domain, tunneled
DisplayPort, tunneled PCIe, or dock parity.

No kernel configuration change is needed for this increment. The qcom-x1e
package policy already enables `CONFIG_PHY_QCOM_QMP_COMBO=y`, `CONFIG_USB4=m`,
`CONFIG_USB4_CONFIGFS=m`, `CONFIG_USB4_NET=m`, the PS8830 mux, Qualcomm PMIC
Type-C support, and the DisplayPort and Thunderbolt Alt Mode modules.

### Production safety boundary

Keep `parade,disable-usb4` on both production Denali PS8830 nodes. Do not add a
production host-router node and do not make the USB4 sub-PHY a production
consumer until the router, sideband, power, and recovery gates below pass.

The QMP provider keeps runtime PM forbidden by default. Manually changing its
runtime power policy to `auto` is outside the v20 production contract and must
not be used until consumer teardown, direct DisplayPort, orientation changes,
and router ownership have been qualified together.

The first active USB4 experiment must use an explicitly named experimental DTB
that is not selected by the normal boot entry. Its patch must contain no raw
MMIO diagnostic interface, arbitrary register write, firmware-memory dump,
debugfs write path, or user-triggered GDSC toggle.

### Host-router integration boundary

The next kernel series is gated on a reviewable Qualcomm host-router driver or
a minimal downstream implementation derived from public interfaces. It must
separate the following concerns into bisectable commits:

1. a documented device-tree binding for clocks, resets, interconnects, IOMMU,
   firmware, interrupts, NHI, and one router port;
2. non-PCI NHI operations that avoid Intel-only capability, reset, and mailbox
   registers;
3. controller firmware loading and ring startup with bounded cleanup and
   runtime power management;
4. Type-C and retimer notification flow from PMIC GLINK through QMP, PS8830,
   and the router;
5. bounded Qualcomm revision-3 DROM trailing-entry tolerance;
6. verified Denali per-port resources without guessing the physical
   top/bottom-to-controller mapping; and
7. a separate experimental DTB that enables one port at a time.

The unresolved PS8830-to-UC sideband receive connection is a blocker, not an
invitation to replay unverified Windows writes. If public documentation or a
trace with matching symbols does not establish the sequence, the branch stays
disabled.

### Firmware and evidence policy

The controller payload extracted from a Windows driver is proprietary. Follow
[ADR0004](adr-0004-firmware-extraction-policy.md): do not commit, attach, or
publish the payload, its containing Windows driver, raw ETL traces, or firmware
memory dumps. A future extractor may copy an exact, user-owned payload into
the documented `/lib/firmware/qcom/x1e80100/microsoft/Denali/` location, but it
must be opt-in, deterministic, hash-verified, and tested only with synthetic
fixtures in this repository.

Any prebuilt v20 package follows
[ADR0026](adr-0026-prebuilt-kernel-release-artifacts.md). It remains an
experimental prerelease and includes exact source provenance and checksums,
but no proprietary payload or private diagnostic archive.

### Verification gates

The PHY increment requires:

- `git diff --check` and `scripts/checkpatch.pl` review;
- QMP binding validation;
- a warning-enabled ARM64 build of `phy-qcom-qmp-combo.o`;
- builds of the X1E and X1P Denali DTBs; and
- confirmation that both production retimer nodes retain
  `parade,disable-usb4`.

The source/static gates below were run against exact kernel-code head
[`5b5f1d124b7a`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/5b5f1d124b7ad43b9aac076ad65aa27fa3689ce9).
The final kernel PR head is its changelog-only descendant
[`e056649b9b56`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/e056649b9b56622fedd806134d4f79dcf251a2f0).

| Gate | Result |
|---|---|
| Public-series provenance | Pass: patches 1, 2, and 5 retain stable public-series patch IDs; patches 3 and 4 were compared hunk by hunk after 7.2 conflict resolution |
| `git diff --check` | Pass |
| Strict `checkpatch.pl` on downstream QMP hardening | Pass: 0 errors, 0 warnings, 0 checks; 652 lines checked |
| `make ARCH=arm64 ubuntu_x1e_defconfig` | Pass |
| `W=1` QMP combo-PHY object | Pass from a clean output tree |
| `W=1` PS8830 mux and Thunderbolt core objects | Pass |
| Targeted USB43DP binding validation | Pass with dtschema 2026.6 |
| X1E OLED and X1P Denali DTBs | Pass |
| Required kernel configuration | Pass; existing QMP, USB4, Type-C, PS8830, TBT Alt Mode, and direct-DP options remain enabled |
| Production fallback | Pass; both Denali PS8830 nodes retain `parade,disable-usb4`, and no production router consumer is added |
| Full qcom-x1e Debian package build | Pass: `binary-indep binary-qcom-x1e` completed from exact final kernel PR head `e056649b9b56`; all four packages report version `7.2.0-jg-0sp11v20` |
| Linux USB4 domain/router runtime | Not run — production USB4 is disabled |
| USB3, PCIe, or DisplayPort tunnel runtime | Not run — production USB4 is disabled |
| Direct DisplayPort regression and automatic runtime-PM qualification | Not run; required before either production guard or runtime-PM policy changes |

### Reproducible package evidence

On 2026-08-30, the documented Ubuntu 26.04 container build completed with
target `binary-indep binary-qcom-x1e`. Its generated provenance manifest
records source head
[`e056649b9b56`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/e056649b9b56622fedd806134d4f79dcf251a2f0),
with no local patches. Package metadata was inspected after export: each
package reports version `7.2.0-jg-0sp11v20`, the three machine-specific
packages report architecture `arm64`, and the common header package reports
architecture `all`.

| Artifact | SHA-256 |
|---|---|
| `linux-headers-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `6ec9b5872ff2a3ce22a21030f399517c433236867ed1f90df88cfef434b8daba` |
| `linux-image-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `90e36276604a38ada5466015f851f466b62194d50317076f8608157e42d51153` |
| `linux-modules-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `46a545cb44419916a794c575d08c221bb2a8bccba5ce867efe34fe813019ac35` |
| `linux-qcom-x1e-headers-7.2.0-jg-0sp11v20_7.2.0-jg-0sp11v20_all.deb` | `f949f5649271e18f48b9164d6442cf4b5ec0d1b832f055f285819a52a7177cad` |
| Generated source/build manifest | `26f5bce2bb66a4c093b47ed9339c5312efa489788b819b7f0aa3c6cc1a6c64ba` |
| Generated package-list manifest | `8fc74e8f48e3cef6a1cc487ff0c55e073f4244017607c7ae419ecfdd0adec358` |

The checksum manifest was verified after artifact export; its own SHA-256 is
`6953bfcaa9522f00ac193fb00701982910922b22d71a1dec0077b3e9aa498db4`.
These files remain local build evidence, not published release assets. This
package result demonstrates pinned-source compilation and packaging only; it
adds no runtime USB4, tunneled DisplayPort, or monitor-audio claim.

Before removing the fallback from any production DTB, hardware evidence must
show all of the following:

- a stable USB4 domain and host router after a cold boot;
- successful link training and a downstream dock router;
- USB 3, PCIe, and DisplayPort tunnels without IOMMU or security regressions;
- direct DisplayPort Alt Mode still working on both connectors and both cable
  orientations;
- USB4-tunneled display on both connectors with hotplug and unplug recovery;
- at least 20 suspend/resume cycles and repeated cold boots without a hard
  lock, stale domain, or lost direct-DP fallback; and
- a tested fallback kernel and recovery procedure.

DisplayPort audio is a separate gate. The current Denali sound graph has no
DisplayPort DAI link, so a working video tunnel must not be described as full
monitor audio parity.

## Consequences

- The v20 line can compile and review the public QMP USB4 layer without risking
  the ongoing pen milestones or activating an incomplete production path.
- The existing direct DisplayPort Alt Mode configuration remains unchanged
  while USB4-tunneled DisplayPort remains explicitly blocked.
- The branch records a precise boundary for further upstream work instead of
  claiming support from firmware boot or router registration alone.
- Full USB4 still depends on a published, usable in-tree host-router
  implementation or a carefully reviewed downstream equivalent, verified
  sideband activation, per-port DT integration, and target hardware
  qualification.
- Proprietary Windows artifacts remain outside git and release assets.
