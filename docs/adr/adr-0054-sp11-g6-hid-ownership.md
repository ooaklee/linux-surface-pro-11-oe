---
id: adr-0054-sp11-g6-hid-ownership
title: "ADR0054: Surface Pro 11 G6 HID Ownership"
# prettier-ignore
description: Architecture decision for exposing G6 reports through a HIDRAW-only child before selecting a Surface Pro 11 pen parser or IPTSD integration.
---

# ADR0054: Surface Pro 11 G6 HID Ownership

## Status

Accepted (2026-08-07) for the research and first diagnostic implementation.
Pen parsing, userspace selection, and persistent deployment remain gated by
live report evidence and one-shot recovery validation.

## Context

The pinned touchscreen client proves a working GPI/QSPI transport and finger
input path, but it does not register a Linux HID device or expose HIDRAW. It
validates a device descriptor and requests a report descriptor, then handles
only two spontaneous report IDs. Pen reports may therefore be present but are
not observable through a standard Linux raw-HID boundary.

Stock IPTSD is not a passive probe: the reviewed v3.1.0 path opens HIDRAW
read/write, can request metadata, and writes device modes during start and
stop. Its G6 descriptor and geometry compatibility are unproven. The public
HID-over-SPI v4 series provides the preferred generic architecture but does
not yet support the SP11's multi-lane QSPI path or validated device lifecycle.

## Decision

Keep the custom touchscreen driver as transport and lifecycle owner. The first
feature branch will add a G6-specific `BUS_SPI` HID child connected with
`HID_CONNECT_HIDRAW` only. It will retain the live report descriptor, feed only
spontaneous input reports to HID core, reject every transport-backed GET, SET,
OUTPUT, and unknown raw request, keep raw access restrictive, and preserve the
existing finger input device. Tests must prove that rejected callbacks never
reach QSPI and synchronous replies never enter the input stream.

Do not connect generic HID input during this phase. This prevents duplicate
touch devices and separates evidence collection from parser behavior.

After a one-shot diagnostic build captures the descriptor hash and bounded
report ID/size histograms, choose one pen owner:

1. standard Linux HID input if a complete standard pen report is observed and
   a reviewed pen-only collection mapping prevents duplicate touch devices;
2. an evidence-gated, read-only, pen-only IPTSD G6 backend if DFT/MPP framing
   requires it; or
3. a separately reviewed parser if neither existing path fits.

The generic HID-over-SPI QSPI port remains a parallel upstream objective, not
a prerequisite for the first diagnostic boundary.

## Consequences

- Report discovery cannot silently change controller mode.
- Existing touch remains independently testable and available during pen
  research.
- A vendor/product match alone cannot authorize IPTSD or a parser; descriptor,
  report schema, geometry, and service security are explicit gates.
- The first implementation adds no pen feature by itself.
- Raw payloads remain local and short-lived; public evidence contains hashes,
  schemas, counters, and synthetic fixtures.
- The custom bridge may later be retired when generic HID-over-SPI supports
  the required QSPI and lifecycle contract.

## Related

- [G6 HIDRAW and IPTSD research](../sp11-g6-hidraw-iptsd-research.md)
- [Full feature-parity execution plan](../sp11-full-feature-parity-execution-plan.md)
- [ADR0049: v3 touchscreen build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR0053: one-shot experimental boot](adr-0053-one-shot-experimental-kernel-boot.md)
