---
id: adr-0050-sp11-touchscreen-clean-install-release-flow
title: "ADR0050: Surface Pro 11 Touchscreen Clean-Install and Release Flow"
# prettier-ignore
description: Retrospective and decision record for making the Surface Pro 11 touchscreen module, initramfs, diagnostics, and release flow reproducible on clean and upgraded systems.
---

# ADR0050: Surface Pro 11 Touchscreen Clean-Install and Release Flow

## Status

Accepted (2026-08-06), amended 2026-08-07. The implementation and module
identities are validated on the existing OLED X1E80100 development device. A
clean-install hardware run remains the gate for stable or hardware-qualified
promotion of a touchscreen bundle.

The project owner authorized one bounded exception for the fresh r1 kernel and
image to be published as explicitly experimental prereleases after their
automated package, module, DTB, image, provenance, and fresh-download checks
pass. The clean-install matrix remains outstanding; these prereleases must say
so and must not be described as clean-install validated or hardware-qualified.

## Context

The `sp11v3` release was announced after the MSHW0485 touchscreen worked on the
development Surface. A second OLED X1E80100 user then reported a dead input
device and this controller error in
[Ubuntu Discourse post 2077](https://discourse.ubuntu.com/t/ubuntu-concept-snapdragon-x-elite/48800/2077):

```text
geni_spi a88000.spi: Invalid proto 9
```

The user added `spi_geni_qcom.sp11_windows_se_init=1`, added module-load files,
ran `update-initramfs -u`, and rebooted successfully. Those changes were made
together, so the report did not isolate which change was causal.

Source and device evidence distinguish them:

- The stock Johan G. `spi-geni-qcom` at kernel source commit `8f953dd` rejects
  protocol 9 with `Invalid proto 9`.
- The controller built from the pinned geocausa Phase 91 source accepts
  protocol 9 on `a88000.spi`
  unconditionally. `sp11_windows_se_init` is consulted later to choose a
  controller-initialization path; it does not enable protocol-9 recognition.
- The development Surface works with `sp11_windows_se_init=N` and logs
  `applied Linux-integrated QSPI SE preparation`.
- Its three loaded module source versions match the `updates/` files, and they
  load during the initramfs phase before the root filesystem is available.
- The pinned source's reference deployment explicitly excludes the experimental
  Windows controller sequence from its validated baseline.

“Phase 91” identifies the source pin. The support installer supplies no
`mshw0485_touch` profile parameters, so the driver's defaults select the Phase
75 runtime profile. `behavior_stats` is the authoritative runtime-profile
observation; later Phase 76–91 behavior gates are not implied by the source
revision.

The 2026-08-06 diagnostic on the development Surface identified loaded and
selected source versions `A9BE6B3E2AEF71B5F41F865` (`gpi`),
`3A825FCED27D92B662FFA0E` (`spi_geni_qcom`), and
`CF6FA888C2B8E129277C297` (`mshw0485_touch`). The patched controller accepted
protocol 9 at 1.22 seconds and registered the input device at 1.32 seconds;
the root filesystem was not mounted until 2.25 seconds. That ordering proves
the working machine already obtained the override stack from its boot image.

The high-confidence root cause is therefore a stale initramfs that loaded the
stock controller (and potentially stock GPI DMA module) before the root
filesystem's `updates/` overrides were available. Rebuilding the initramfs was
the likely decisive action in the community recovery. The Windows-derived
controller path may still be useful for a future machine-specific A/B test,
but the report does not establish that it is generally required.

### Why development did not reproduce the failure

The development machine was stateful: it had gone through repeated Phase 91
deployments, module swaps, and initramfs rebuilds before the v3 release test.
The v3 modules were already selected in its boot image. The published script,
however, only copied modules and ran `depmod`; it printed a reboot instruction
without performing the mandatory initramfs rebuild. Documentation listed a
separate `dracut` command, but the release had not been validated from a
pristine stock-module initramfs. This was an upgrade-path test presented as a
clean-install-capable flow.

### Adjacent release-integrity findings

The same retrospective found two packaging defects in the original release:

1. The now-removed public tag `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3` pointed to commit
   `1fe13d2` (the v2 tree), while the v3 support changes are in `25bd39c` and
   merge commit `0a3fbdd`. The release command allowed GitHub to create a tag
   at the then-current default branch instead of naming the manifest commit.
2. The published checksum file was regenerated manually after the three `.ko`
   files were added. It contains an impossible empty-file hash for itself and
   names `RELEASE-NOTES.md`, which was used as the release body rather than
   uploaded. Full verification therefore cannot pass.

The audit captured the manifest and checksum defects before the release and
tag were removed on 2026-08-07. They must not be used as the template for
another release.

## Decision

### Build

- Pin the touchscreen source to an immutable Phase 91 commit and record the
  separately observed runtime profile.
- Refuse dirty or wrong-origin source checkouts and support an explicit offline
  build from the pinned commit.
- Resolve or require the exact target ABI instead of assuming `uname -r`.
- Refuse non-`sp11v3` targets by default because successful compilation does
  not prove that the kernel contains the required touchscreen device tree.
- Verify headers, `Module.symvers`, replaceable GPI/SPI config, module names,
  vermagic, aliases, parameters, and source versions before producing a bundle.
- Record the module source URL, ref, commit, target ABI, source versions, and
  hashes in a generated manifest.

### Install and boot image

- Install the matched `gpi`, `spi-geni-qcom`, and `mshw0485_touch` set as one
  exact-ABI operation.
- Make the initramfs refresh part of the installer, not a follow-up note. Use
  `update-initramfs` on Ubuntu and a guarded `dracut` fallback.
- Add explicit initramfs-tools and dracut inclusion configuration for all three
  modules, run `depmod`, and verify both module selection and initramfs content.
- Make the kernel `--install-only` flow require the three-module bundle for an
  `sp11v3` image unless the operator explicitly chooses a kernel-only install.
- Never unload or replace the live GPI/SPI drivers in place. Install for the
  target boot and require a reboot.
- Keep `sp11_windows_se_init=0` as the validated default. Expose `=1` only as
  an explicit, warned recovery profile.

### Diagnostics

Provide a touchscreen-specific diagnostic that compares selected and loaded
module source versions, checks the live device tree, firmware and input node,
and classifies the main signatures:

| Signature | Classification |
| --- | --- |
| `Invalid proto 9` | Stock/stale `spi-geni-qcom` loaded; repair module selection and initramfs first |
| `CH START completion timeout` | Stock or mismatched GPI DMA path likely loaded |
| No enabled `spi@a88000` / MSHW0485 child | Wrong kernel, ABI, or device tree |
| Protocol 9 accepted but client init fails | Investigate transport/client state; only then A/B the opt-in cold-init profile |
| `Microsoft Surface G6 Touch` plus initialized log | Controller, DMA, client, and input registration succeeded |

### Release

- Treat the three modules and their immutable source provenance as first-class
  release assets.
- Generate one explicit upload-asset list. Hash exactly that list, excluding
  `SHA256SUMS` itself and the local notes file, then append the checksum file to
  the upload list.
- Create the GitHub release with `--target <support-commit>` and reject an
  existing tag that resolves elsewhere.
- Validate tag commit, package ABI/version/roles, module vermagic/source
  versions/aliases, touchscreen DTB content, checksum coverage, and exact asset
  equality before publication and again from a fresh download.
- Publish new immutable corrective tags rather than recreating or moving the
  retired originals. The standalone bundle uses
  `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1`; the image uses
  `sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1`. The installable kernel ABI
  remains `7.2-rc5-jg-0sp11v3-qcom-x1e`.
- An explicitly authorized experimental prerelease may precede the full
  hardware matrix only when its release notes disclose the outstanding gate,
  retain the fallback and recovery requirements, and make no stable or
  hardware-qualified claim. All integrity and provenance gates still apply.

### Automated evidence for the r1 prereleases

The corrective-release rehearsal completed the non-device checks available on
the ARM64 build host:

- all 198 tests in the pinned Phase 91 touchscreen source passed with its
  documented `python3 -m unittest discover -s tests -v` command;
- the semantic release validator passed package role, ABI, dependency, module
  identity, vermagic, source-version, alias, parameter, provenance, checksum,
  and packaged touchscreen-DTB checks;
- missing and deliberately mismatched module bundles were both rejected during
  preflight, before package installation could begin; and
- all four kernel packages, all three touchscreen modules, and the module
  manifest extracted from the validated raw image matched the curated payload
  byte for byte.

These checks cover the refusal behavior in matrix item 4 and the artifact side
of the release. Items 1–3 and 5–7 still require the physical Surface Pro 11
transitions described below.

### Corresponding-source supplement

The r1 kernel and image prereleases initially included the patched JG kernel
source but not a self-contained archive of the GPL touchscreen-module source.
On 2026-08-07 the releases were amended additively, without moving tags or
replacing binary assets. Both now carry the exact geocausa commit's licence and
twelve build/source files under `phase55/modules/`, a source notice, and source
checksums. The image release also carries the matching patched kernel source.

Future image preparation requires seven binding inputs: the patched-kernel and
exact touchscreen source archives, `SOURCE-NOTICE.md`, the fresh schema-v2
kernel build manifest, the matching kernel release manifest, and the matching
touchscreen module manifest, plus the image-build manifest. The helper validates
the archive identities, exact two-partition GPT and ESP contents, pinned input
ISO, kernel-manifest DTB output, exact committed support tree, and embedded
image payload against those manifests,
then attaches and hashes all seven inputs in the prepared release. An upstream
URL and commit pin alone do not replace corresponding-source distribution.
Historical r1 assets remain immutable and are not evidence that a future
candidate satisfies this newer gate.

## Validation matrix

Stable or hardware-qualified promotion must cover:

1. a clean v3 install while an older kernel is running;
2. a deliberately stale stock-module initramfs, followed by guarded repair;
3. an already-working v3 reinstall (idempotency);
4. missing and mismatched module bundles (refusal before package mutation);
5. both initramfs-tools and dracut paths;
6. cold power-on, Linux reboot, Windows-to-Linux boot, and suspend/resume;
7. default Linux-integrated initialization, with the Windows sequence tested
   separately only if a correctly loaded module still fails.

## Consequences

- The community's reported clean-install failure becomes a detected and
  repairable module-selection error.
- A release can no longer claim touchscreen support when it contains only the
  v3 kernel packages or loose, untracked `.ko` additions.
- Building modules for experimental ABIs now requires an explicit override.
- Installation does more validation and may take longer because the exact
  initramfs is rebuilt and inspected.
- The original v3 release and tag were removed on 2026-08-07. This ADR retains
  the audit evidence; a corrective successor must use a new immutable tag.
- The authorized r1 prereleases can make corrected artifacts available for
  community testing before the complete hardware matrix finishes, but their
  experimental status and the remaining gate become part of the public
  release record.

## Related

- [ADR0041: Surface Pro 11 Touchscreen Kernel Patch Set](adr-0041-sp11-touchscreen-patches.md)
- [ADR0042: Surface Pro 11 Touchscreen Integration Troubleshooting](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR0051: Remove Broken or Incorrect Releases and Tags](adr-0051-release-and-tag-cleanup.md)
- [geocausa Phase 91 controller source](https://github.com/geocausa/SP11X1e-touchscreen/blob/6bbcf7a4759a73014047a57e819219dd7f34951a/phase55/modules/spi-geni-qcom.c)
- Removed original v3 release and tag: `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3`
