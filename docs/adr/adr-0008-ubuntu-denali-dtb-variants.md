---
id: adrs-adr008
title: "ADR008: Ubuntu Denali DTB Variants"
# prettier-ignore
description: Architecture Decision Record (ADR) for supporting Ubuntu's Surface Pro 11 Denali DTB filenames while preserving explicit custom-DTB testing.
---

## Context

[ADR007](adr-0007-auto-dtb-extraction-and-debug-entries.md) introduced
best-effort DTB extraction from the Ubuntu concept ISO. Testing against the
current Resolute X1E concept ISO showed that there is no loose
`x1e80100-microsoft-denali.dtb` file in the ISO root.

The ISO uses layered `casper/*.squashfs` images. The Surface Pro 11 X1E DTBs
observed there are named:

- `x1e80100-microsoft-denali-oled.dtb`
- `x1e80100-microsoft-denali-oled-el2.dtb`

The older Surface Pro 11 Arch notes and kernel work use
`x1e80100-microsoft-denali.dtb`.

## Decision

The live USB builder will use a stable internal destination,
`/dtb/sp11-denali.dtb`, regardless of the source filename.

In auto mode, the builder will search the ISO file tree and each
`casper/*.squashfs` layer for these X1E candidates, in order:

- `x1e80100-microsoft-denali-oled.dtb`
- `x1e80100-microsoft-denali.dtb`
- `x1e80100-microsoft-denali-oled-el2.dtb`

The installed-system support helper will search Ubuntu's
`/usr/lib/firmware/*/device-tree/qcom/` DTB path, the older kernel-image DTB
paths, and `/boot`, then copy the selected DTB to `/boot/sp11-denali.dtb` for
GRUB injection.

## Consequences

The builder can use the current Ubuntu concept ISO as a DTB source when it
contains the X1E OLED Denali DTB.

Custom DTB testing remains possible with `--dtb`, including Dale Whinham's
older filename or future upstream candidate filenames.

The default candidate order intentionally targets the verified X1E Surface Pro
11 class. LCD, 5G, X1P, or other variants may need a different explicit DTB and
should get their own ADR before becoming default behavior.
