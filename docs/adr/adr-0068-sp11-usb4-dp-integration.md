---
id: adr-0068-sp11-usb4-dp-integration
title: "ADR0068: SP11 USB4 and DisplayPort Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for starting the Surface Pro 11 USB4 integration at kernel milestone v20 with public Qualcomm USB43DP PHY support, a production-safe retimer fallback, proprietary-firmware boundaries, and evidence-gated USB4 DisplayPort tunnelling.
---

# ADR0068: SP11 USB4 and DisplayPort Integration

## Status

Accepted for the source/static portion and the controlled top-port retimer
qualification at the `7.2.0-jg-0sp11v20` implementation milestone on
2026-08-30. The clean same-version rebuild, packaged-image inspection, guarded
control attach, top-port experimental attach, and guarded rollback passed for
their intended scope. Full USB4 enablement is not accepted: the experimental
attach reached the top-port PS8830 USB4 configuration path, but no active
host-router PHY consumer or USB4 domain/router was present, and no dock
USB/Thunderbolt enumeration appeared. The production tree and normal rollback
image retain both PS8830 guards.

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
| Guarded-scope clarification; initial guarded USB4 head | [`e056649b9b56`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/e056649b9b56622fedd806134d4f79dcf251a2f0) |
| Pen/touch integration merge used by the guarded rebuild | [`672638f963d3`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/672638f963d37f55a93544568db41bfc4469df6d) |
| Retimer/QMP handoff diagnostics | [`75617434c1e6`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/75617434c1e686e807dd0742799cb29bf0201a90) |
| Top-port-only experimental DTB | [`a57d6d807dbc`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/a57d6d807dbce79f5877cf61e25febd5cef9bf1b) |
| Experimental-DTB changelog | [`5321047ea5e2`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/5321047ea5e2d23d44b0041b69db776c46eb015f) |
| Alternate Stubble-image isolation; current qualification source head | [`70ddec100fe9`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/70ddec100fe953712c309067fe2db4d8207facc6) |
| Upstream submission | [Qualcomm USB43DP PHY v4](https://patchew.org/linux/20260820-topic-usb4phy-v4-0-aec9d2cb31f6@oss.qualcomm.com/), mbox SHA-256 `cf05fc8da482ab8085cfe3eeb37798b62bc74c5b2a73f8e74a8cc9b0dc93d3e2` |

## Context

The Surface Pro 11 has two USB-C connectors. Direct USB-C DisplayPort Alt Mode
already works. DisplayPort carried through a USB4 dock is a different path: it
requires the USB4 host router, retimer sideband connection, link training, and
USB4 Connection Manager to create a DisplayPort tunnel before DRM can drive the
monitor.

A reviewed same-device Windows capture and its public
[redacted result](https://github.com/ooaklee/sp11-windows-capture/blob/85161cd5c84f2d7463f74d9ff2a81fcc175ff86c/analysis/usb4-first-attach-20260829/redacted-result.md)
establish a useful hardware oracle. The exact CalDigit TS4 and bundled passive
40 Gb/s cable formed a real USB4 connection through the physical top port,
with host/root/dock routers plus USB3, PCIe, and DisplayPort tunnels.

A separate review of the private device graph identifies the Qualcomm
host-router bus as `QCOM0C6D` / `_SB.UBF0`, its successful port as
`_SB.UBF0.PRT1`, and the tunneled USB controller as `QCOM0C8C` / `_SB.URS1`.
Those sanitized conclusions are not attributed to the linked public report.

That private review also shows why the bottom-port capture is not a valid
negative hardware comparison:
`QCOM0C8B` / `_SB.URS0` was reserved by KDNET with
`CM_PROB_USED_BY_DEBUGGER`. Its charge-only result must not be used to claim a
bad bottom port. The capture also contains no host-router MMIO map, interrupts,
clocks, resets, IOMMU stream IDs, firmware protocol, or decoded PS8830
sideband sequence. It guides top-port selection and the success oracle; it is
not source-code provenance or Linux runtime validation. Raw capture output
remains private and outside this repository.

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
available as historical pen and touch milestones. The branch now includes the
validated pen/touch integration merge at `672638f963d3`; the later USB4 commits
remain independently reviewable and revertible on top of that shared base.

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

The first such DTB is
`x1e80100-microsoft-denali-oled-usb4-top-experimental.dtb`. It inherits the
production OLED tree and deletes `parade,disable-usb4` only from the `i2c7`
PS8830 mapped to the physical top port. The `i2c3` bottom-port guard remains,
and the normal DTB retains both guards. The experimental target stays outside
`dtb-y` and the normal `dtbs-list`. Packaging filters it from the normal
Stubble auto-selection set, fails closed if that invariant changes, and embeds
it only in `/usr/lib/linux-image-<ABI>/sp11-usb4-top-experimental.efi`.

The normal `/boot/vmlinuz-*` therefore stays guarded. A tester must copy the
alternate EFI image to a distinct temporary `/boot` filename and transiently
edit only the GRUB `linux` path for one cold boot, leaving initrd unchanged.
Editing a loose GRUB `devicetree` line does not override the FDT embedded by
Stubble and is not part of this procedure.

This DTB can establish whether Enter_USB reaches and programs the PS8830. It
cannot create a USB4 domain: QMP deliberately ignores USB4/TBT mux requests
until a host-router consumer initializes the USB4 PHY, and no such consumer is
present. The diagnostic messages distinguish these two outcomes without
faking PHY ownership.

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

The original PHY source/static gates below were run against exact kernel-code
head
[`5b5f1d124b7a`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/5b5f1d124b7ad43b9aac076ad65aa27fa3689ce9),
with the initial guarded package completed at
[`e056649b9b56`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/e056649b9b56622fedd806134d4f79dcf251a2f0).
The separately reviewable retimer experiment and its alternate Stubble-image
isolation are validated statically at
[`70ddec100fe9`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/70ddec100fe953712c309067fe2db4d8207facc6).

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
| Experimental-diff `git diff --check` | Pass at `70ddec100fe9` |
| Strict `checkpatch.pl` on experimental changes | Pass: 0 errors, 0 warnings, 0 checks |
| Experimental `W=1` driver build | Pass: `ps883x.ko` and `phy-qcom-qmp-combo.o` with the ARM64 cross toolchain |
| Experimental DTB isolation | Pass: production OLED, explicitly targeted experimental OLED, and X1P Denali DTBs build; full ARM64 `dtbs` completes; the experimental filename is absent from the normal `dtbs-list` |
| Compiled guard isolation | Pass: production OLED DTB contains two `parade,disable-usb4` properties; experimental DTB contains only the `i2c3` bottom-port property |
| Experimental targeted schema validation | Not run locally: `dt-doc-validate` is unavailable. The wrapper adds no property and deletes one optional boolean already covered by the previously validated PS8830 binding |
| Alternate Stubble construction | Pass in the Ubuntu 26.04 qualification package: ARM64 PE image, exactly one `.dtbauto`, and extracted experimental model/guard count verified |
| Experimental full qcom-x1e package rebuild | Pass at exact source head `70ddec100fe9`: `binary-indep binary-qcom-x1e` completed with no local patches; four version-`7.2.0-jg-0sp11v20` packages exported and their six-file checksum manifest verified strictly |
| Packaged Stubble isolation | Pass: the normal ARM64 PE image contains 38 `.dtbauto` sections and no experimental marker; the alternate contains exactly one `.dtbauto`; no experimental path exists under `/boot` and no loose experimental DTB is packaged |
| Guarded v20 regressions | Partial pass: ordinary OLED model and two live guards; one-, two-, and three-finger touch, pen inking/pressure/barrel button, and a direct USB3 device passed. Direct USB-C DisplayPort Alt Mode was not run because no suitable test device or adapter was available |
| Guarded TS4 control attach | Pass for the production safety boundary: the top-port attach encountered the DT policy rejection; no dock USB/Thunderbolt device or USB4 domain appeared in this session |
| Top-port experimental boot | Pass: exact experimental model, alternate `BOOT_IMAGE`, and only the bottom-port guard remained |
| Top-port experimental TS4 attach | Pass for the retimer-only scope: the PS8830 driver completed its USB4 configuration writes without error, then QMP reported no active host-router PHY consumer; no dock USB/Thunderbolt device or USB4 domain appeared |
| Guarded rollback | Pass: a cold boot of the normal unedited v20 image restored the ordinary OLED model and both live guards |
| Linux USB4 domain/router runtime | Observed negative as designed: no domain or router appeared; QMP had no active host-router PHY consumer when the mux request arrived |
| USB3, PCIe, or DisplayPort tunnel runtime | Not established: no dock USB/Thunderbolt enumeration or USB4 domain appeared; direct USB3 success is not tunnel evidence |
| Direct DisplayPort regression and automatic runtime-PM qualification | Not run; suitable direct-DP test hardware was unavailable, and both gates remain required before any production guard or runtime-PM change |

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

A later same-version guarded rebuild at
[`672638f963d3`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/672638f963d37f55a93544568db41bfc4469df6d)
integrated the validated pen/touch branch while retaining both production USB4
guards. Its manifest SHA-256 is
`0c27041400692122ac76b26cfc291981525be5e95dea1d025d539b3cb7165b8f`;
its checksum-manifest SHA-256 is
`7884167a1b56482e36bbc6034908810c9391ccbe2ea637b2b450ed5e51a0e2e0`.
That guarded build is the installed pre-experiment baseline, not the new
top-port experiment. Because all three builds use the same Debian version, the
source manifest is mandatory evidence. For the clean `70ddec100fe9`
qualification rebuild, the operator intentionally cleared the prior local
build and untracked payload assets before building. The hashes above remain
provenance for the previously installed guarded v20, but no local
`artifacts-672638f-guarded/` archive is claimed for this run. Guarded v20
remains the installed pre-install baseline; v16 remains installed as the
independent fallback and becomes the only independent rollback after the
same-ABI v20 replacement.

The clean qualification rebuild completed from exact source head
[`70ddec100fe9`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/commit/70ddec100fe953712c309067fe2db4d8207facc6)
with `Local patches: none`, target `binary-indep binary-qcom-x1e`, and eight
jobs. Each package reports version `7.2.0-jg-0sp11v20`; the three
machine-specific packages report architecture `arm64`, and the common header
package reports architecture `all`.

| Clean qualification artifact | SHA-256 |
|---|---|
| `linux-headers-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `535cef2ee7043a7756c9b57fd225d8353eff03c6b6404c1aed6750d59cb3404e` |
| `linux-image-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `ea0354d32dd11ae0fa0cb3b2d443099e37def695a6c119239b852d095c6a6333` |
| `linux-modules-7.2.0-jg-0sp11v20-qcom-x1e_7.2.0-jg-0sp11v20_arm64.deb` | `64fbda78899a0a145fe826e33657c7a9b6cb359c34d4cfd98255ac5ab41d1ac1` |
| `linux-qcom-x1e-headers-7.2.0-jg-0sp11v20_7.2.0-jg-0sp11v20_all.deb` | `763579b1d489a834c59ceb8710204810bb593a8fca56561084b5c0b68ce5238b` |
| Generated source/build manifest | `4d1a7675fbbdfc11c8ca84bd040aa3446f1a0a702ebcc97e48501002ac252348` |
| Generated package-list manifest | `8fc74e8f48e3cef6a1cc487ff0c55e073f4244017607c7ae419ecfdd0adec358` |

The generated six-entry `SHA256SUMS` passed strict verification; its own
SHA-256 is
`980d4c3dca485b7f575c4f95c5ef8b0482a7ac6c5306c80aec21fd4904e13c88`.
The Docker export helper now generates that manifest atomically, validates the
declared package set against the exported set, and installs it read-only for
normal-user verification.

Package inspection confirms that the production DTB still contains two
`parade,disable-usb4` properties while the alternate DTB contains one. The
alternate's exact model is `Microsoft Surface Pro 11th Edition (OLED,
top-port USB4 retimer experiment)`. The normal and alternate `.linux` payloads
are identical at SHA-256
`032c34ba16cddee96d3dcbe8190dc7e5a8848928313f41ebdd10fc2892e92779`;
only their embedded DTB sets differ. The packaged production OLED DTB is
byte-identical to the installed guarded v20 DTB at SHA-256
`b65e0b97e3cd8ce2454000d9d14ff27bd8863c0730cde27a2b42b8fff4809efa`.

### Controlled top-port runtime evidence

The 2026-08-30 qualification first booted the normal v20 image with the
ordinary OLED model and both live PS8830 guards. One-, two-, and three-finger
touch, pen inking with pressure variation, the barrel button, and a direct
USB3 device passed. Direct USB-C DisplayPort Alt Mode was not run because no
suitable test device or adapter was available; the existing project support
claim was therefore not requalified by this run.

The guarded TS4 control attach produced the expected policy rejection and no
dock topology. After a cold power cycle, the alternate image booted with exact
model `Microsoft Surface Pro 11th Edition (OLED, top-port USB4 retimer
experiment)` and only the bottom-port guard. A single attach of the matched
CalDigit TS4 and bundled 40 Gb/s cable changed the labelled top Type-C port to
normal orientation, host data role, USB Power Delivery, and a PD-capable
partner. The two publishable driver lines were:

```text
ps883x_retimer 5-0008: USB4 mode accepted by retimer; host-router state not established
qcom-qmp-combo-phy fda000.phy: USB4/TBT mux request ignored: no active host-router PHY consumer
```

The first line is emitted only after the driver completes its USB4
configuration writes without error. It does not prove that the silicon formed
a USB4 link or trained at 40 Gb/s. The second establishes that a USB4 PHY
object existed but had no active host-router PHY consumer when the mux request
arrived; it does not establish why that initialization was absent or that one
consumer is the only remaining blocker.

There was no change in USB topology, PCI enumeration, DRM connectors,
Thunderbolt devices, or USB4 domains. The result validates removal of the
retimer-side policy rejection for this scoped top-port experiment. It does not
validate a USB4 link, a working dock, or any USB3, PCIe, or DisplayPort tunnel.

The ignored local baseline and attached snapshots started at
`2026-08-30T10:55:47Z` and `2026-08-30T10:57:08Z`. Each passed strict
verification; their checksum-manifest SHA-256 values are respectively
`d05b9aa87e0fab5db13fb2fe52a105111e5921bd208e43f51acbc89667fb0039`
and `a60b835f3c81010dd8909f68d66f7960f3368ca4c9b0930a2a9553093d7ca92f`.
The raw snapshots remain private because their full logs and inventories can
contain host identifiers. A subsequent cold boot of the normal unedited v20
image restored the ordinary OLED model and both live guards.

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

- The v20 line can compile and review the public QMP USB4 layer on the validated
  pen/touch base without activating an incomplete production path.
- The existing direct DisplayPort Alt Mode configuration remains unchanged
  while USB4-tunneled DisplayPort remains explicitly blocked.
- The branch records a precise boundary for further upstream work instead of
  claiming support from firmware boot or router registration alone.
- Full USB4 still depends on a published, usable in-tree host-router
  implementation or a carefully reviewed downstream equivalent, verified
  sideband activation, per-port DT integration, and target hardware
  qualification.
- Proprietary Windows artifacts remain outside git and release assets.
