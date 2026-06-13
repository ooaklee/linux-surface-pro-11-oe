---
id: adrs-adr007
title: "ADR007: Auto DTB Extraction and Debug Entries"
# prettier-ignore
description: Architecture Decision Record (ADR) for extracting the Surface Pro 11 Denali DTB from the Ubuntu concept ISO when available and adding a text/debug boot path.
---

## Context

[ADR003](adr-0003-denali-dtb-and-grub-injection.md) required an explicit
Denali DTB input. Since then, the Ubuntu Snapdragon X concept stream has gained
Microsoft Surface device-tree and hardware-ID work. The current ISO may already
contain `x1e80100-microsoft-denali.dtb`.

Community reports also show that Surface Pro 11 boot attempts can fail after
GRUB with a black screen, even when the Denali DTB loads. A first test image
needs a lower-noise diagnostic path for distinguishing installer graphics
issues from kernel/device-tree failures.

## Decision

The image builder will default `--dtb` to `auto`. In auto mode, it extracts
`x1e80100-microsoft-denali.dtb` from the Ubuntu concept ISO inside the build
container. If extraction fails, the builder exits with instructions to provide
an explicit DTB.

The GRUB menu will include a USB-safe text/debug entry that removes
`quiet splash`, enables `debug`, disables Plymouth, and boots to
`multi-user.target`.

## Consequences

The common path is simpler: a user can build test media from the current Ubuntu
concept ISO without separately building a kernel only to obtain the DTB.

The builder remains deterministic when the user supplies an explicit DTB, which
is useful for testing Dale Whinham's Surface Pro 11 kernel tree or newer
upstream candidate DTBs.

The debug boot entry does not guarantee visible output if the underlying panel
or DRM path fails early, but it gives the next test a better chance of yielding
actionable boot logs.
