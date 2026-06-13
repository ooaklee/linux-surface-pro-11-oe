---
id: adrs-adr001
title: "ADR001: Target Repo and Scope"
# prettier-ignore
description: Architecture Decision Record (ADR) for keeping the Ubuntu Surface Pro 11 bring-up in a dedicated repo while using upstream projects as references.
---

## Context

The Ubuntu Surface Pro 11 work draws from multiple active upstream efforts:

- the Surface Laptop 7 Ubuntu bring-up,
- the Surface Pro 11 Arch Linux bring-up,
- linux-surface tracking issues and packaging work,
- Fedora Snapdragon Windows-on-Arm install notes,
- Canonical Snapdragon X concept images.

Those projects have different distribution targets, assumptions, and packaging
formats. The Surface Laptop 7 work is closest to the desired Ubuntu experience,
while the Surface Pro 11 Arch work has the device-specific Denali knowledge.

The target hardware has been verified separately in
[the 2026-06-13 hardware report](../hardware-report-20260613.md).

## Decision

We will keep the Ubuntu Surface Pro 11 solution in this dedicated repository.
The upstream repositories remain references and inputs, not files we modify in
place. This repository owns the Ubuntu-oriented README, scripts, image-building
workflow, hardware notes, and ADR history.

We will target the Microsoft Surface Pro 11, SKU
`Surface_Pro_11th_Edition_2076`, with Snapdragon X Elite/X1E80100 hardware.
Support for other Snapdragon X devices is out of scope unless explicitly added
by a future ADR.

## Consequences

The repository can evolve toward a plug-and-play Ubuntu workflow without
forking or disturbing the reference projects.

We must copy only reusable logic and public configuration patterns. Proprietary
firmware blobs and generated local test artifacts remain outside git.

Future decisions should link back to this ADR when they depend on the dedicated
Surface Pro 11 Ubuntu scope.
