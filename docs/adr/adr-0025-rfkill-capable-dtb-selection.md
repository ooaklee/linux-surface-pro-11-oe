---
id: adrs-adr025
title: "ADR025: rfkill-Capable DTB Selection"
# prettier-ignore
description: Architecture Decision Record (ADR) for preferring Surface Pro 11 Denali DTBs that contain disable-rfkill over newer unpatched fallback-kernel DTBs.
---

## Context

[ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) introduced a
patched qcom-x1e kernel path for the Surface Pro 11 WCN7850 rfkill blocker.
That decision assumed the installed DTB injector could prefer the newest
versioned Denali DTB without undoing the kernel patch.

The first Docker git-fallback build produced patched `7.0.0-22-qcom-x1e`
packages, while the installed system already had an unpatched
`7.0.0-32-qcom-x1e` fallback. In that state, sorting DTB candidates by version
can copy the newer unpatched `7.0.0-32` DTB into `/boot/sp11-denali.dtb`, even
though the patched `7.0.0-22` DTB is the one that contains the
`disable-rfkill` property.

Wi-Fi rfkill bring-up needs both parts at the same time:

- an ath12k module that understands `disable-rfkill`;
- a loaded Denali DTB whose WCN7850 node contains `disable-rfkill`.

## Decision

The installed-system DTB injector will prefer Denali DTB candidates that contain
the literal `disable-rfkill` property. Among rfkill-capable candidates it will
still choose the highest versioned path. If no candidate contains that property,
it will fall back to the previous highest-versioned Denali DTB behavior.

This keeps the fallback-kernel safety model from [ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
while preventing a newer unpatched fallback DTB from replacing the patched DTB
needed for the active Wi-Fi experiment.

## Consequences

The injector can now select an older patched DTB over a newer unpatched DTB.
That is intentional for the rfkill experiment, but it means the selected DTB is
not always the newest installed hardware description.

Once Ubuntu's newer qcom-x1e kernels carry the same Denali `disable-rfkill`
property, the injector will naturally return to selecting the newest matching
DTB.

Manual testing should verify `/boot/sp11-denali.dtb` contains
`disable-rfkill` before rebooting into the patched kernel.
