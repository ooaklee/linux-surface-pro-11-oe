---
id: sp11-feature-parity-source-ledger
title: "Surface Pro 11 Feature-Parity Source Ledger"
# prettier-ignore
description: Public evidence and provenance boundaries for the Surface Pro 11 OLED feature-parity programme.
---

# Surface Pro 11 Feature-Parity Source Ledger

This ledger distinguishes reproducible public inputs from observations,
inferences, and unavailable implementations. Add an entry before using a new
source to design or justify a public kernel, driver, userspace, or release
change.

## Rules

- A demonstration proves feasibility only; it is not an implementation source.
- Record immutable commits for source used in a build or release.
- Keep Windows binaries, firmware, private traces, credentials, machine
  identifiers, and remote-access details out of git and release assets.
- Do not copy code or constants from a source whose redistribution terms are
  absent or incompatible.
- Label a conclusion as an inference until it is reproduced on the target
  Surface Pro 11.
- Preserve copyright and SPDX information from every upstream source.
- A human reviews every AI-assisted change and is the only party that may add a
  `Signed-off-by` certification.

## Current sources

| Source | Immutable identity | Permitted use | Boundary |
|---|---|---|---|
| [Johan G. kernel integration tree](https://github.com/jglathe/linux_ms_dev_kit) | Tag `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`, commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Kernel baseline and attribution-preserving patch development | The moving `jg/ubuntu-qcom-x1e-7.2rc` branch is not release provenance |
| [SP11 thin kernel fork](https://github.com/ooaklee/linux_ms_dev_kit-sp11) | `sp11/base-jg-7.2-rc5-jg-0` and `sp11/integration-7.2-rc5` initially resolve to `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Temporary integration, CI, hardware-test branches, and upstream patch preparation | Do not make the fork a permanent source of generic subsystem code |
| [linux-surface ACPI dumps](https://github.com/linux-surface/acpidumps/tree/master/surface_pro_11_qcom) | Commit `1d0a2ce742b450fe3f65287adbe174ddccabe228` | Public ACPI namespace and resource evidence; no repository licence is declared | ACPI names do not prove Linux device-tree wiring, sensor modes, register sequences, or firmware commands |
| [Linux X1E80100 CAMSS binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/media/qcom%2Cx1e80100-camss.yaml) | Use the copy in the kernel baseline or feature branch and record that full kernel commit | CAMSS resource and media-graph contract | Does not identify the SP11 sensor wiring |
| [Linux OV13858 driver](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/ov13858.c) | Use the copy in the recorded kernel feature-branch commit | Upstream sensor-driver starting point | Existing modes and power assumptions must be validated on SP11 |
| [linux-surface IPTSD](https://github.com/linux-surface/iptsd) | Candidate research pin `a83bc1232f7096f8b33b50fdbda249cd640de670`; choose and record a reviewed release or commit before packaging | Userspace touch/pen processing research and integration | Public IPTSD targets Intel Precise Touch; G6 compatibility is not assumed |
| [Surface Aggregator Module](https://github.com/linux-surface/surface-aggregator-module) | Candidate research pin `de6d403852f33f5445c25971a3f25e6ebafbf824`; choose and record the exact code reused by a platform-profile branch | Existing SSAM protocol and driver architecture | No SP11 firmware command is assumed from another Surface model |
| [SP11 G6 touchscreen source](https://github.com/geocausa/SP11X1e-touchscreen) | Commit `6bbcf7a4759a73014047a57e819219dd7f34951a` for the released Phase 91 modules | Existing validated touchscreen transport only, subject to its recorded provenance and licence | Pen is explicitly outside the released module scope; no private or locally supplied analysis input is redistributed |
| [Public feature demonstration](https://www.youtube.com/watch?v=WJqRIeTjUbI) | Video and description as observed during planning | Feasibility evidence and acceptance-test targets | The implementation is unavailable and must not be reconstructed by copying private work |
| Target SP11 OLED observations | Report produced by `scripts/collect-sp11-feature-parity-inventory.sh` | Reproducible, sanitized hardware facts | Reports exclude identifiers and are not automatically committed; manually review before publication |

## Established target facts

The read-only schema-2 inventory run on 2026-08-07 established the following
on the target OLED X1E80100 machine. Its output was reviewed in-session rather
than added to git:

- Ubuntu 26.04 runs `7.2-rc5-jg-0sp11v3-qcom-x1e`.
- the device tree identifies `microsoft,denali-oled` and `qcom,x1e80100`;
- G6 touch works through the QSPI/GPI exact-ABI module set;
- WSA8845, SoundWire, LPASS playback, and LPASS capture components bind;
- no media or video device node is present;
- the kernel enables CAMSS and OV13858 as modules but does not expose IMX681 or
  VD55G0 configuration symbols in the running configuration;
- no IPTSD service or pen input device is present;
- no platform-profile interface is exposed;
- the current `gpio-keys` input exposes a switch, not volume keys; and
- the kernel offers s2idle and deep sleep with WFI and `cpu-sleep-0` enabled,
  while resume remains unqualified; and
- the running v3 ABI differs from the persistent GRUB saved entry, which still
  points to v2, so experimental one-shot boot remains blocked until the chosen
  known-good persistent fallback is made explicit.

These observations establish work boundaries, not feature completion.

## Open evidence questions

1. Does the G6 HID descriptor expose `045e:0c83` as a HID identity over SPI?
2. Which CAMSS CCI buses, CSIPHY instances, clocks, regulators, and reset GPIOs
   connect the three camera sensors on this exact firmware revision?
3. Are the public ACPI identities `OVTID858`, `OVTI02C1`, and `SMO55F1`
   sufficient to confirm the claimed OV13858, IMX681, and VD55G0 sensors?
4. Does a controlled 3.2 MHz DMIC build outperform the currently validated
   2.4 MHz build without speaker or suspend regression?
5. Which Denali PSCI idle state causes the resume failure, if cpuidle rather
   than a dependent device is responsible?
6. Which SSAM commands represent the SP11 firmware performance modes, and is
   the reported 2.515 GHz power-saver ceiling firmware-owned or a separate
   Linux policy?

## AI assistance

Planning has been reviewed with Codex and OpenCode using a GLM-5.2 route. For
changes intended for upstream Linux, follow the current
[kernel coding-assistant policy](https://github.com/torvalds/linux/blob/master/Documentation/process/coding-assistants.rst),
including human review, human-only DCO certification, and the requested
assistance attribution.
