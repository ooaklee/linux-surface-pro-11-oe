---
id: adr-0071-fedora-iptsd-package-source-ownership
title: "ADR0071: Fedora IPTSD Package-Source Ownership"
# prettier-ignore
description: Architecture Decision Record (ADR) for retaining Fedora IPTSD package-source inputs in OE while Lexr owns Fedora image and package-build orchestration.
---

# ADR0071: Fedora IPTSD Package-Source Ownership

## Status

Accepted on 2026-09-01.

## Context

Fedora Workstation Live needs distribution-native ownership for installed
packages. The maintained Surface Pro 11 pen path also needs a native IPTSD
build from the pinned upstream source and every corresponding Meson fallback;
repackaging the portable payload's Ubuntu-built binaries would not provide a
Fedora-native or source-complete result.

OE remains the authority for Surface Pro 11 integration sources, presets,
lifecycle templates, licences, and hardware evidence. Lexr owns executable
image, kernel, userspace, and release orchestration under
[ADR0069](adr-0069-standalone-lexr-workflow-ownership.md). Reintroducing a root
RPM builder, kernel package, workflow, or shell validation suite in OE would
restore the duplicate execution surface removed by
[ADR0070](adr-0070-retire-superseded-repository-scripts.md).

Fedora's image-specific boot and installation lifecycle is recorded in
[Lexr ADR027](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-027-fedora-erofs-remaster-and-installed-handoff.md).
That adapter owns EROFS extraction and recreation, custom-kernel RPM
construction, dracut and `kernel-install` policy, Anaconda hand-off, hybrid ISO
publication, and structural validation. Those responsibilities are not
userspace source inputs.

## Decision

- Retain the pinned IPTSD identity, device presets, lifecycle templates,
  integration licence, and evidence under `userspace/iptsd-sp11`.
- Add the reusable Fedora spec template and its archive contract under
  `userspace/iptsd-sp11/packaging/fedora`. Do not add a root build wrapper,
  Fedora workflow, root packaging tree, kernel RPM implementation, or a second
  image-remastering path to OE.
- Require a source archive containing the exact pinned upstream tree, every
  corresponding Meson fallback source and patch, this repository's integration
  tree, all redistributed licence texts, and `SOURCE.env`. Prebuilt payload
  binaries are not package sources.
- Render only the declared version, source timestamp, and changelog-date
  placeholders. Lexr must checksum and validate its source archive before
  invoking Fedora's native package toolchain.
- Install the binaries under `/usr/libexec`, presets under `/usr/share`, and
  the systemd and udev integration under Fedora's `/usr/lib` paths. The package
  conflicts with both generic `iptsd` and legacy `g6-pen`, and provides
  `sp11-iptsd = %{version}-%{release}`.
- On installation, reload udev rules and retrigger only already-enumerated
  HIDRAW nodes whose parent is one of the maintained `001C:045E:0C80` or
  `001C:045E:0C83` digitizers. Never emit a subsystem-wide synthetic event for
  unrelated HIDRAW devices.
- Keep the kernel as the sole direct-touch provider. The packaged IPTSD daemon
  decodes the private HIDRAW stylus stream and creates only the pen device.

## Consequences

- OE keeps the reusable, reviewable Fedora userspace source contract next to
  the hardware integration it packages, without regaining a runnable distro
  build surface.
- Lexr can build a Fedora-native binary RPM and source RPM from authenticated
  inputs while keeping image, kernel, Anaconda, and publication policy in one
  adapter.
- The source RPM can satisfy redistribution obligations for IPTSD and its
  fallback dependencies instead of relying on binaries built for another
  distribution.
- Updating the integration README or adding Fedora packaging files changes
  Lexr's exact checked-in integration-file contract; the linked Lexr revision
  must advance those digests and file identities at the same time.
- A successful native build and structural image validation do not qualify
  stylus, touch, suspend/resume, USB boot, installation, or installed-system
  behavior. Those remain explicit physical Surface Pro 11 gates.

## Alternatives Considered

**Keep all Fedora packaging in Lexr (rejected).** The executable workflow
belongs there, but the IPTSD spec is part of the device integration and must
evolve with its pinned sources, presets, licence set, and lifecycle templates.

**Restore the complete Fedora kernel and userspace packaging draft in OE
(rejected).** That would duplicate Lexr's adapter-owned kernel, image, and
validation policy and contradict the completed repository migration.

**Repackage the portable IPTSD binaries (rejected).** Those binaries were
built against an Ubuntu userspace. A Fedora package must be rebuilt natively
from the exact source-complete input.
