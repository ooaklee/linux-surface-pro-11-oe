---
id: adr-0064-sp11-audio-release-strategy
title: "ADR0064: Dedicated SP11 Audio Release Strategy"
# prettier-ignore
description: Architecture Decision Record (ADR) for publishing the hash-pinned Surface Pro 11 FullIO topology and UCM pairing as a dedicated linux-surface-pro-11-oe release, separate from kernel packages and paired explicitly with the geocausa v12 kernel release.
---

> **Current operator notice (2026-08-30):** The former combined staging and
> publication helper below is superseded and non-prescriptive. Use
> `userspace audio release prepare` and `userspace audio release validate` for
> deterministic local assets, then `userspace install audio` for installation; see
> [Lexr ADR019](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-019-native-audio-release-preparation.md).
> Remote publication remains a separate maintainer action and is not authorised by preparation.

# ADR0064: Dedicated SP11 Audio Release Strategy

## Status

Accepted for the FullIO v19c and geocausa v12 release pairing. Publication is
still a separate, explicit maintainer action; this decision does not record a
published `sp11-audio-v19c` release.

## Context

The Surface Pro 11 kernel is necessary but is not a complete audio deployment.
The q6apm component probe returns the result of `audioreach_tplg_init()`.
`sound/soc/qcom/qdsp6/topology.c` constructs
`qcom/<card driver>/<card name>-tplg.bin`, calls `request_firmware()`, and then
loads the result with `snd_soc_tplg_component_load()`. A missing or invalid
topology therefore prevents the AudioReach component from probing correctly;
it cannot be repaired later by a kernel package post-install hook or by the
desktop audio session.

UCM is also functionally required. The SP11 card and HiFi files establish the
validated speaker route, PA and digital gains, DAC and VISENSE state, VI
feedback routes, and the MultiMedia3 microphone route. The package-owned
`conf.d/x1e80100/x1e80100.conf` needs an SP11 DMI branch so ALSA selects that
card profile. Without the complete topology/UCM pairing, a kernel can boot
while PipeWire and WirePlumber still expose no usable `HiFi` speaker and
microphone pair.

The FullIO topology includes protected vendor-derived bytes. Those bytes have
an explicit redistribution boundary and are deliberately excluded from the
kernel source tree and kernel Debian packages. Mixing them into a kernel `.deb`
would obscure provenance, couple two independently reviewed payload classes,
and make ordinary kernel redistribution include the protected payload.

The accepted pairing is:

- geocausa v12 kernel ABI `7.2.0-jg-0sp11v12-qcom-x1e`, with intended OE
  release tag `sp11-qcom-x1e-7.2.0-jg-0sp11v12`;
- FullIO v19c topology from SP11X1e-audio tag
  `native-audio-fullio-v19c-20260826`;
- the matching `MICROSOFT-Surface-Pro-11in.conf` and `SP11-HiFi.conf`, plus a
  hash-covered SP11 DMI matcher generated from the pinned upstream
  `x1e80100.conf` base.

## Decision

- Publish the topology and its complete UCM pairing as a dedicated GitHub
  release on `ooaklee/linux-surface-pro-11-oe`, using a distinct immutable tag
  such as `sp11-audio-v19c`.
- Treat that audio release as the single source of truth for the installable
  SP11 audio bundle. Keep the reproducible topology source, UCM development,
  and detailed acceptance evidence in `geocausa/SP11X1e-audio`, but do not ask
  users to assemble runtime files from multiple repositories.
- Stage only the hash-pinned FullIO v19c topology and UCM sources. Generate the
  `conf.d` matcher deterministically from the pinned upstream UCM base, include
  every installable file in `SHA256SUMS`, and fail closed on a missing file or
  source hash mismatch.
- Require every kernel release in this line to reference its compatible audio
  release in the kernel release notes. The audio release notes likewise name
  the supported kernel tag and ABI.
- Keep audio deployment and protected topology bytes out of the kernel
  repository and kernel Debian packages. Publication at the dedicated boundary
  remains subject to an explicit maintainer redistribution review.
- Use `scripts/publish-sp11-audio-release.sh` for staging and publication. Its
  dry-run mode performs all local staging and verification without invoking
  GitHub; its publish mode uses the reviewed notes and exact staged asset list.

## Consequences

- Users must install two compatible releases: the kernel bundle and the paired
  audio bundle. Installing only the kernel is insufficient.
- Maintainers must preserve and document kernel/audio release pairing whenever
  either side changes. A new incompatible topology, UCM sequence, control
  namespace, or ABI requires a new immutable audio tag rather than moving an
  existing tag.
- The topology, card UCM, HiFi UCM, generated DMI matcher, and release upload
  set are hash-pinned. Replacing any payload changes `SHA256SUMS` and requires a
  new release review.
- The UCM bundle includes `conf.d/x1e80100/x1e80100.conf`; the two Qualcomm UCM
  files alone are not a clean-install bundle on distributions whose upstream
  matcher lacks the SP11 DMI branch.
- Kernel packages remain distributable and auditable without silently carrying
  protected vendor-derived bytes. The dedicated audio release makes that
  boundary visible, but it also means release publication must not be automated
  past the explicit `--publish` action and redistribution review.
- The OE repository becomes the stable user-facing release location while the
  SP11X1e-audio repository remains the technical provenance and reproduction
  source.

## Related ADRs

- [ADR-0033](adr-0033-audio-topology-gap.md) — topology required for card
  instantiation
- [ADR-0044](adr-0044-sp11-ucm-single-wsa-macro-microphone.md) — corrected SP11
  UCM routing
- [ADR-0051](adr-0051-release-and-tag-cleanup.md) — immutable release and
  checksum integrity policy
- [ADR-0062](adr-0062-sp11-7-2-0-jg-0sp11v9-golden-v32-audio-line.md) — earlier
  canonical topology/UCM pairing
