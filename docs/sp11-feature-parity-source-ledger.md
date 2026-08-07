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
- Record immutable commits for git inputs and SHA-256 identities for archived
  non-git inputs used in a build or release.
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
| [Johan G. kernel integration tree](https://github.com/jglathe/linux_ms_dev_kit) | Tag `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`, commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Kernel baseline and attribution-preserving patch development | The tree is mixed-license; preserve and review each changed file's SPDX expression. The moving `jg/ubuntu-qcom-x1e-7.2rc` branch is not release provenance |
| [SP11 thin kernel fork](https://github.com/ooaklee/linux_ms_dev_kit-sp11) | Immutable base `8f953dd060bc6e8fb86ca2ea8a92f258141c0169`; current integration `971b5af85ed0c7283ffb33430badeac9b5575057` | Temporary integration, CI, hardware-test branches, and upstream patch preparation | The tree is mixed-license and per-file SPDX controls. Do not make the fork a permanent source of generic subsystem code |
| [linux-surface ACPI dumps](https://github.com/linux-surface/acpidumps/tree/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom) | Commit `1d0a2ce742b450fe3f65287adbe174ddccabe228` | Public ACPI namespace, resource, and secure SISP ownership evidence; no repository licence is declared | ACPI names do not prove Linux device-tree wiring, sensor modes, register sequences, SSAM functions, or firmware commands. The `SISP` SDEV denial is a hard non-secure CAMSS resource gate |
| [JG X1E80100 CAMSS binding and integration](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/Documentation/devicetree/bindings/media/qcom%2Cx1e80100-camss.yaml) | Exact JG baseline `8f953dd060bc6e8fb86ca2ea8a92f258141c0169`; exact series ancestry is recorded in the [camera research note](sp11-camera-foundation-research.md) | Split-PHY CAMSS resource and media-graph contract | The unmodified generic node claims secure SISP MMIO and interrupts; it must not probe on SP11 without a reviewed non-secure partition and target ownership proof |
| [Pinned mainline camera comparison](https://github.com/torvalds/linux/tree/f9a2394a23482bfd330911e9c8295b71724feacd) | Commit `f9a2394a23482bfd330911e9c8295b71724feacd` | Immutable inline-PHY CAMSS binding plus public OV13858, OV02C10, and VD55G1 driver contracts; preserve each file's SPDX | This is a comparison source, not a compatible schema to mix with the JG split-PHY series or proof of Denali wiring |
| [Linux OV13858 driver](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov13858.c) | Exact JG baseline commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Public rear-sensor identity and driver contract | Existing modes and ACPI-only power assumptions must be validated before a Denali DT node |
| [Linux OV02C10 driver](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c) | Exact JG baseline commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Public front-sensor identity hypothesis for ACPI ID `OVTI02C1` | The HID-to-driver match does not prove the target chip, address, CCI path, endpoint, or board wiring |
| [linux-surface IPTSD](https://github.com/linux-surface/iptsd/tree/a83bc1232f7096f8b33b50fdbda249cd640de670) | Evidence-only research pin `a83bc1232f7096f8b33b50fdbda249cd640de670` (`v3.1.0`, `GPL-2.0-or-later`) | Descriptor and parser research only until the live descriptor, report schema, and physical geometry are known | Stock discovery and the runner open HIDRAW read/write, may request metadata, change device mode, have no `045e:0c83` preset, and must not be pointed at the G6 device |
| [Hamoa cluster-idle change](https://github.com/jglathe/linux_ms_dev_kit/commit/fb2108597f0055790ced9d6921af50e529f5b35b) | Commit `fb2108597f0055790ced9d6921af50e529f5b35b`, already in the JG baseline; `hamoa.dtsi` is `BSD-3-Clause` | P6 source-history rationale and proof that the baseline already detaches `cl5` | The broad X1 reset rationale is not an SP11 failure reproduction or permission to remove another state |
| [Initial Surface platform-profile driver](https://github.com/torvalds/linux/commit/b78b4982d7637ededbc40b5f4aa59394acee8a60) | Commit `b78b4982d7637ededbc40b5f4aa59394acee8a60`; relevant files are `GPL-2.0-or-later` | Typed `f01` request, response, retry, and profile-mapping basis | Its four fixed choices, no-response SET, and model matches do not establish SP11 support or safe capability discovery |
| [SP11 Surface registry addition](https://github.com/jglathe/linux_ms_dev_kit/commit/c4a069095395ecd1e936f488511dfd9016b9c479) | Commit `c4a069095395ecd1e936f488511dfd9016b9c479`; relevant registry file is `GPL-2.0-or-later` | Exact Denali SSAM topology evidence | The group instantiates thermal-sensor `f02`, not profile `f01`; never broaden the profile driver alias to make it bind |
| [Surface Aggregator Module](https://github.com/linux-surface/surface-aggregator-module/tree/de6d403852f33f5445c25971a3f25e6ebafbf824) | Evidence-only pin `de6d403852f33f5445c25971a3f25e6ebafbf824`; top-level GNU GPL v2, relevant module `GPL-2.0-or-later` | Pre-SP11 SSAM architecture and protocol corroboration | It does not establish SP11 support; its raw-request tool is prohibited as a discovery mechanism |
| [Experimental SSAM command database](https://github.com/linux-surface/surface-aggregator-cmddb/tree/226a69997f89263f903da36517bca639f044382b) | Commit `226a69997f89263f903da36517bca639f044382b`; no repository licence or file SPDX was found | Evidence only | Do not copy its code, YAML, constants, or descriptions or make an implementation depend on it |
| [SP11 G6 touchscreen source](https://github.com/geocausa/SP11X1e-touchscreen/tree/6bbcf7a4759a73014047a57e819219dd7f34951a) | Commit `6bbcf7a4759a73014047a57e819219dd7f34951a` for the released Phase 91 source, whose client is built from `phase55/modules` | Existing validated touchscreen transport only, subject to its recorded provenance and licence | Phase labels do not describe runtime behaviour. The installer supplies no client-profile parameters, so compiled defaults select Phase 75; the client retains no report descriptor, publishes no HID child, and has no pen path |
| [SP11 audio UCM revision](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/695592192691348d39445198a90ebcc9383eaa94) | Tracked microphone-route commit `695592192691348d39445198a90ebcc9383eaa94` | Existing device-specific UCM evidence only | This commit is not proof of original derivation or redistribution terms. The UCM files have no SPDX header; reuse and future releases remain blocked until provenance and licence are reviewed |
| [HID-over-SPI v4 series](https://lore.kernel.org/all/20260609-send-upstream-v4-0-b843d5e6ced3@chromium.org/) | Message-ID `20260609-send-upstream-v4-0-b843d5e6ced3@chromium.org`; base commit `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b`; decompressed thread mbox SHA-256 `3b26ce90730b9bb4d1ff8394db65fcf5f999c94329973fa673dca582ff13f0ca` | Long-term Linux HID transport design evidence; all 11 patches apply textually to the JG baseline | Textual application is not build or correctness evidence. V4 does not select the SP11 quad path, rejects fragmented input, assumes transport ownership already held by the custom client, and has unresolved automated-review findings; it remains evidence-only |
| [Public feature demonstration](https://www.youtube.com/watch?v=WJqRIeTjUbI) | Video and description as observed during planning | Feasibility evidence and acceptance-test targets | The implementation is unavailable and must not be reconstructed by copying private work |
| Target SP11 OLED observations | Report produced by `scripts/collect-sp11-feature-parity-inventory.sh`; sanitized conclusions in the [2026-08-07 Wave 1 evidence report](sp11-wave1-read-only-target-evidence-20260807.md) | Reproducible, sanitized hardware facts | Reports exclude identifiers and are not automatically committed; manually review before publication |

## Established target facts

The read-only schema-3 inventory run on 2026-08-07 established the following
on the target OLED X1E80100 machine. Its output was reviewed in-session rather
than added to git:

- Ubuntu 26.04 runs `7.2-rc5-jg-0sp11v3-qcom-x1e`.
- the device tree identifies `microsoft,denali-oled` and `qcom,x1e80100`;
- G6 touch works through the QSPI/GPI exact-ABI module set built from the
  Phase 91 source pin; `behavior_stats` reports `profile=phase75`, matching the
  installer's lack of client-profile parameters and the compiled defaults;
- WSA8845, SoundWire, LPASS playback, and LPASS capture components bind;
- no media or video device node is present;
- the kernel enables Qualcomm CCI, CAMSS, OV02C10, and OV13858 as modules but
  does not expose IMX681, VD55G0, or VD55G1 configuration symbols in the
  running configuration;
- no IPTSD service or pen input device is present;
- no platform-profile interface is exposed; the live registry-defined SSAM
  client is thermal-sensor `f02`, while the installed profile driver matches
  absent `f01` and is not loaded;
- the current `gpio-keys` input exposes a switch, not volume keys; and
- the kernel offers s2idle and deep sleep with WFI and `cpu-sleep-0` enabled,
  while resume remains unqualified; and
- the running v3 ABI differs from the persistent GRUB saved entry, which still
  points to v2, so experimental one-shot boot remains blocked until the chosen
  known-good persistent fallback is made explicit.

These observations establish work boundaries, not feature completion.

## Open evidence questions

1. Does a Linux-captured 1,484-byte G6 report descriptor hash to the public
   candidate value, which report IDs and sizes appear during pen hover and
   contact, and do its usages satisfy IPTSD's descriptor predicates?
2. Which CAMSS CCI masters, CSIPHY instances, clocks, regulators, and reset
   GPIOs connect the three camera sensors on this exact firmware revision?
3. Does a controlled target chip-ID read confirm the public mappings
   `OVTID858` to OV13858 and `OVTI02C1` to OV02C10, and what sensor is behind
   `SMO55F1` given the mismatch with VD55G0's published `SMO55F0` PNP ID?
4. Does a controlled 3.2 MHz DMIC build outperform the currently validated
   2.4 MHz build without speaker or suspend regression?
5. Which Denali PSCI idle state causes the resume failure, if cpuidle rather
   than a dependent device is responsible?
6. Does this SP11 expose an exact performance-profile `f01` client at all; if
   so, which target-derived capabilities and modes are safe, and is any
   low-power frequency ceiling firmware-owned or a separate Linux policy?

## AI assistance

Planning has been reviewed with Codex and OpenCode using a GLM-5.2 route. For
changes intended for upstream Linux, follow the current
[kernel coding-assistant policy](https://github.com/torvalds/linux/blob/master/Documentation/process/coding-assistants.rst),
including human review, human-only DCO certification, and the requested
assistance attribution.
