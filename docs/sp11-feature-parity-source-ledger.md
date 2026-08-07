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
| [linux-surface ACPI dumps](https://github.com/linux-surface/acpidumps/tree/master/surface_pro_11_qcom) | Commit `1d0a2ce742b450fe3f65287adbe174ddccabe228` | Public ACPI namespace and resource evidence; no repository licence is declared | ACPI names do not prove Linux device-tree wiring, sensor modes, register sequences, or firmware commands |
| [Linux X1E80100 CAMSS binding](https://www.kernel.org/doc/Documentation/devicetree/bindings/media/qcom%2Cx1e80100-camss.yaml) | Use the copy in the kernel baseline or feature branch and record that full kernel commit | CAMSS resource and media-graph contract | Does not identify the SP11 sensor wiring |
| [Linux OV13858 driver](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov13858.c) | Exact JG baseline commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Public rear-sensor identity and driver contract | Existing modes and ACPI-only power assumptions must be validated before a Denali DT node |
| [Linux OV02C10 driver](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/media/i2c/ov02c10.c) | Exact JG baseline commit `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` | Public front-sensor identity hypothesis for ACPI ID `OVTI02C1` | The HID-to-driver match does not prove the target chip, address, CCI path, endpoint, or board wiring |
| [linux-surface IPTSD](https://github.com/linux-surface/iptsd/tree/a83bc1232f7096f8b33b50fdbda249cd640de670) | Candidate research pin `a83bc1232f7096f8b33b50fdbda249cd640de670` (`v3.1.0`, `GPL-2.0-or-later`) | Descriptor and parser research; an evidence-gated G6 pen backend only if the live reports require it | Stock IPTSD opens HIDRAW read/write and changes device mode, has no `045e:0c83` preset, and must not be pointed at the G6 device |
| [Surface Aggregator Module](https://github.com/linux-surface/surface-aggregator-module) | Candidate research pin `de6d403852f33f5445c25971a3f25e6ebafbf824`; choose and record the exact code reused by a platform-profile branch | Existing SSAM protocol and driver architecture | No SP11 firmware command is assumed from another Surface model |
| [SP11 G6 touchscreen source](https://github.com/geocausa/SP11X1e-touchscreen/tree/6bbcf7a4759a73014047a57e819219dd7f34951a) | Commit `6bbcf7a4759a73014047a57e819219dd7f34951a` for the released Phase 91 source | Existing validated touchscreen transport only, subject to its recorded provenance and licence | The installer sets no client-profile parameters, so the source defaults to the Phase 75 runtime profile; pen is outside its scope |
| [SP11 audio UCM revision](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/695592192691348d39445198a90ebcc9383eaa94) | Tracked microphone-route commit `695592192691348d39445198a90ebcc9383eaa94` | Existing device-specific UCM evidence only | This commit is not proof of original derivation or redistribution terms. The UCM files have no SPDX header; reuse and future releases remain blocked until provenance and licence are reviewed |
| [HID-over-SPI v4 series](https://lore.kernel.org/all/20260609-send-upstream-v4-0-b843d5e6ced3@chromium.org/) | Message-ID `20260609-send-upstream-v4-0-b843d5e6ced3@chromium.org`; base commit `05f7e89ab9731565d8a62e3b5d1ec206485eeb0b`; decompressed thread mbox SHA-256 `3b26ce90730b9bb4d1ff8394db65fcf5f999c94329973fa673dca582ff13f0ca` | Long-term Linux HID transport design reference | The public v4 ACPI/OF paths do not support multi-lane SPI; per-file SPDX inventory and applicability review remain required before reuse |
| [Public feature demonstration](https://www.youtube.com/watch?v=WJqRIeTjUbI) | Video and description as observed during planning | Feasibility evidence and acceptance-test targets | The implementation is unavailable and must not be reconstructed by copying private work |
| Target SP11 OLED observations | Report produced by `scripts/collect-sp11-feature-parity-inventory.sh` | Reproducible, sanitized hardware facts | Reports exclude identifiers and are not automatically committed; manually review before publication |

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
- no platform-profile interface is exposed;
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
6. Which SSAM commands represent the SP11 firmware performance modes, and is
   the reported 2.515 GHz power-saver ceiling firmware-owned or a separate
   Linux policy?

## AI assistance

Planning has been reviewed with Codex and OpenCode using a GLM-5.2 route. For
changes intended for upstream Linux, follow the current
[kernel coding-assistant policy](https://github.com/torvalds/linux/blob/master/Documentation/process/coding-assistants.rst),
including human review, human-only DCO certification, and the requested
assistance attribution.
