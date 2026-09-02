---
id: adr-0072-sp11-power-profiles-daemon-class-interface
title: "ADR0072: SP11 Power Profiles Use the Native Class Interface"
# prettier-ignore
description: Architecture Decision Record (ADR) replacing the SP11 synthetic ACPI platform-profile compatibility path with a pinned power-profiles-daemon class-interface integration.
---

# ADR0072: SP11 Power Profiles Use the Native Class Interface

## Status

Accepted on 2026-09-02. This decision supersedes the SP11-specific kernel
compatibility mechanism in [ADR0061](adr-0061-sp11-platform-profile-framework-non-acpi.md),
but retains its hardware evidence for the Surface profile handler and profile
transitions.

## Context

The Surface Pro 11 boots from device tree with ACPI disabled. Kernel 7.2's
platform-profile framework now registers its native per-handler class without
ACPI, and the Surface handler appears as
`/sys/class/platform-profile/platform-profile-0`. The same framework creates
the historical aggregate files under `/sys/firmware/acpi` only when a genuine
ACPI kobject exists.

The interface change is commit `3953c459a0c6` in the history used by the
`7.2.2-jg-0sp11v1-qcom-x1e` PR25 build. The current target branch carries the
same implementation as `84f6900b705a`. The running SP11 system already exposes
one native handler with all four expected choices, while distribution
power-profiles-daemon 0.30 probes only the historical ACPI paths and therefore
selects its placeholder driver.

Creating a fake `/sys/firmware/acpi` hierarchy in the kernel would preserve an
old userspace assumption in generic kernel code. It would also broaden a
shared subsystem change beyond the Microsoft Denali guardrails used for the
rest of the SP11 series.

## Decision

- Pin upstream power-profiles-daemon 0.30 and carry one reviewable userspace
  patch in `userspace/power-profiles-daemon-sp11`.
- Preserve the genuine ACPI interface as the first choice on ACPI systems.
- When the legacy files are absent, consume exactly one complete
  `platform-profile-*` class device. Reject multiple devices rather than
  selecting one nondeterministically.
- Recognise the kernel ABI's canonical `balanced-performance` spelling while
  retaining 0.30's underscore spelling for compatibility.
- Apply the patch through the existing meta-openembedded 0.30 recipe with a
  `meta-sp11` append. Give the resulting package revision suffix `.sp11.1` so
  it upgrades cleanly from the distribution build. Do not duplicate the
  upstream recipe.
- Treat `7.2.2-jg-0sp11v1-qcom-x1e` as the minimum supported 7.2.2 pairing.
  Lexr evaluates compatibility against installed `/lib/modules` ABIs, so the
  userspace can be staged before rebooting the new kernel. A missing live class
  device is a runtime warning and leaves PPD's placeholder available; it is not
  a reason to fabricate kernel ABI.
- Keep the older 7.2.0/v8 result as historical evidence. New 7.2.2 releases do
  not carry the synthetic legacy kernel interface.

## Consequences

- Kernel code remains aligned with the native class model and no longer needs
  an SP11 userspace compatibility kobject.
- The userspace patch is generic enough for a single non-ACPI handler, while
  ambiguity remains fail-closed.
- OpenEmbedded can build the integration directly. A checksum-pinned Ubuntu
  `0.30-2+sp11.1` package is built for local qualification; publication still
  requires a source-complete signed release and a verified Lexr install
  workflow before it is offered as a production download.
- The first physical qualification must verify class-device count, all three
  desktop transitions, the four underlying kernel choices, persistence across
  reboot, and a clean daemon/kernel journal.

## Rejected Alternatives

**Re-create `/sys/firmware/acpi` from generic kernel code.** This makes a
userspace limitation a permanent kernel ABI and risks upstream rejection.

**Hard-depend on one ABI-named Debian kernel package.** Ubuntu kernel image
package names include the ABI, so this would prevent normal future upgrades
and make install-before-reboot recovery unnecessarily fragile.

**Pick the first class device when several exist.** Directory iteration order
is not a machine-wide power policy. The daemon must fall back until explicit
multi-handler aggregation is designed and tested upstream.
