---
id: sp11-g6-hidraw-iptsd-research
title: "Surface Pro 11 G6 HIDRAW and IPTSD Research"
# prettier-ignore
description: Provenance-safe transport, HIDRAW, report-schema, pen, and IPTSD execution gates for the Surface Pro 11 G6 touchscreen.
---

# Surface Pro 11 G6 HIDRAW and IPTSD Research

## Result

Preserve the working custom QSPI/GPI transport and add a HIDRAW-only HID child
before attempting pen parsing. Do not point stock IPTSD at the G6 device.

The first kernel change must expose independently observed reports without
changing the controller mode or creating a second touch input device. A later
evidence gate decides whether the pen is standard HID, requires an IPTSD G6
backend, or needs a separate independently developed parser.

This is a research and execution boundary, not evidence that pen works. No
target state was changed to reach this decision.

## Pinned evidence

### Current G6 transport

The released touchscreen modules are built from geocausa commit
[`6bbcf7a4759a73014047a57e819219dd7f34951a`](https://github.com/geocausa/SP11X1e-touchscreen/tree/6bbcf7a4759a73014047a57e819219dd7f34951a).
At that revision, the client:

- requires a 1,484-byte report descriptor and validates device identity
  `045e:0c83`, version `0004` during enumeration;
- requests the report descriptor but neither retains nor hashes it;
- creates no Linux HID device or HIDRAW node;
- handles spontaneous DATA report IDs `0x40` and `0x12`, while other IDs are
  not surfaced to userspace; and
- registers a separate `BUS_SPI`, ten-slot, finger-only multitouch input
  device.

The source is a Phase 91 pin, but the installed module receives no client
profile parameters. Its compiled defaults select the Phase 75 runtime profile.
The collector therefore records `behavior_stats`'s `profile` value instead of
inferring runtime behavior from the repository phase name.

The public source's descriptor analysis describes Pen report ID `0x01`, but
that is a candidate to verify from Linux, not proof that the target emits a
complete pen report. The first hardware gate records only the live descriptor
hash and report ID/size histograms; it does not publish personal strokes or raw
payloads.

### IPTSD v3.1.0

The candidate userspace baseline is linux-surface IPTSD commit
[`a83bc1232f7096f8b33b50fdbda249cd640de670`](https://github.com/linux-surface/iptsd/tree/a83bc1232f7096f8b33b50fdbda249cd640de670),
tagged v3.1.0 and licensed `GPL-2.0-or-later`.

It is not safe as a discovery tool on this device:

- discovery opens HIDRAW read/write and can request metadata;
- the runner writes a multitouch feature mode on start and a singletouch mode
  on exit;
- no `045e:0c83` geometry preset exists;
- its descriptor predicates and heatmap framing have not been proven against
  a Linux-captured G6 descriptor and reports; and
- the upstream service and generic udev discovery rule do not provide the
  device-specific restriction required for this experiment.

An ID match is insufficient. A G6 backend is considered only if the live
descriptor passes the reviewed usage predicates, the report framing is mapped
from independently captured Linux data, and physical geometry is measured or
obtained through a separately reviewed read-only path.

### Generic HID-over-SPI

Jingyuan Liang's public
[HID-over-SPI v4 series](https://patchew.org/linux/20260609-send-upstream-v4-0-b843d5e6ced3%40chromium.org/)
is the preferred long-term upstream architecture. It registers a Linux HID
device, parses the report descriptor, implements control requests, and feeds
spontaneous data into HID core.

It is not a drop-in replacement for the current SP11 transport. The reviewed
v4 ACPI and device-tree paths explicitly leave multi-lane SPI unsupported,
while the SP11 depends on the existing QSPI/GPI controller and its validated
lifecycle. Before any patch reuse, archive and hash the reviewed public mbox,
preserve authorship and SPDX tags, and record it in the source ledger.

## Architecture decision

The first implementation has four ownership boundaries:

1. The current custom driver continues to own reset, enumeration, synchronous
   GET/SET responses, controller mode, GPI/QSPI operation, recovery, and the
   existing finger input device.
2. A G6-specific `BUS_SPI` HID child receives the observed vendor, product,
   version, and retained report descriptor.
3. The child connects with `HID_CONNECT_HIDRAW` only. Generic HID input and
   HID multitouch remain disconnected to prevent duplicate touch events.
4. Spontaneous DATA reports alone are delivered as report ID plus payload.
   Synchronous control replies are never injected as input. Initial raw
   callbacks reject every transport-backed GET, SET, OUTPUT, and unknown
   request. HID core may serve only the locally retained descriptor.

The HIDRAW node is root-only during research. Collection opens it read-only,
is time-bounded, stores raw material outside git, and publishes only hashes,
counts, lengths, and independently derived field descriptions.

## Execution branches and gates

| Sequence | Branch | Scope and exit gate |
|---|---|---|
| G6-R0 | `lsp11-x-g6-contract-research` | Ledger, ADR, collector schema, privacy boundary, and no target mutation |
| G6-K1 | `lsp11-x-g6-hidraw-bridge-7.2-rc5` in the kernel fork | Retained descriptor, HIDRAW-only child, rejecting controls, scalar counters, and synthetic/KUnit tests |
| G6-C1 | `lsp11-x-g6-report-schema` in the support repository | Descriptor-only checker and bounded local histogram tool; publish no report payloads |
| G6-D1 | Decision gate | Select standard HID pen, an IPTSD G6 backend, another independently licensed parser, or stop |
| G6-U1 | `lsp11-x-iptsd-g6-v3.1.0` in a dedicated IPTSD fork | Only if required: read-only transport-owned mode, exact descriptor allowlist, pen-only output, unit/fuzz tests |
| G6-P1 | `lsp11-x-g6-pen-package` in the support repository | Disabled-by-default restricted service, explicit device access, measured geometry, clean uninstall |
| G6-I1 | `lsp11-x-g6-pen-integration-7.2-rc5` in the kernel fork | One-shot device matrix and regression evidence |
| G6-UP1 | `lsp11-x-spi-hid-qspi-7.2-rc5` in the kernel fork | Parallel long-term port of public HID-over-SPI to the validated QSPI lifecycle |

Each kernel branch starts from the protected integration branch and uses a
distinct co-installable ABI. It cannot become the persistent boot default
until the one-shot recovery contract is proven on the target.

## Collector schema

The public inventory may record:

- module path, SHA-256, source version, vermagic, and an explicit allowlist of
  boolean profile parameters;
- `behavior_stats` profile, initialization stage, mode state, heat/error,
  reset/recovery, IRQ, DMA, and framing counters;
- SPI-to-HID-to-HIDRAW topology, bound drivers, modalias, and `BUS_SPI`
  vendor/product/version;
- report-descriptor length, SHA-256, collection/usage summary, report IDs, and
  bit lengths, but not descriptor bytes by default;
- per-report-ID count and min/max/last size, unknown-ID count, and malformed
  length count; and
- safe evdev capabilities and service hardening state.

It must exclude feature/CFU/provider arrays, raw headers and payloads,
handwriting trajectories, device identifiers unrelated to the G6 contract,
firmware, private traces, and remote-access details. `lsusb` is not G6
identity evidence because the live controller is on SPI.

## Hardware sequence

1. Complete offline compile, static analysis, malformed-length tests,
   synthetic descriptor tests, and control-operation rejection tests.
2. Confirm recovery media, the saved fallback, and a no-op one-shot boot before
   installing the distinct diagnostic ABI.
3. Boot the HIDRAW bridge once. Record the device descriptor, live report
   descriptor SHA-256, and report ID/size histograms across idle, finger, pen
   hover, and pen contact. Do not retain payloads beyond local schema work.
4. Repeat five cold and five warm starts. Any descriptor or framing drift
   blocks parser work.
5. In bounded local sessions, derive fields for out-of-range, hover, contact,
   pressure sweep, every observed physical control, eraser, palm, and
   simultaneous touch. Replace the captures with synthetic fixtures.
6. Run offline parser and fuzz tests. If the standard HID pen collection is
   selected, add a reviewed pen-only collection mapping without substituting
   the descriptor, and prove it cannot create a second touch node or events.
   If IPTSD is selected, enable pen-only output manually for a single one-shot
   boot while kernel touch remains authoritative.
7. Acceptance covers 100 hover cycles, 200 strokes, ten pressure sweeps, 50
   cycles for every evidenced control, palm/touch coexistence, cold boots, and
   s2idle. Service restarts apply only to a userspace parser path; a standard
   kernel-HID path instead repeats bind/boot and duplicate-touch checks. Record
   observed ranges and semantics.

## Rollback and no-go boundary

For a userspace parser path, rollback stops and disables the experimental
service and revokes its device rule. For a standard kernel-HID path, rollback
boots the known-good v3 ABI and removes only the experimental ABI after
evidence capture. Neither path replaces the fallback's initramfs module set.

Stop immediately on duplicate touch devices, an unexpected control write,
descriptor drift, IRQ or reset storm, stuck contact, lost ordinary touch, or
failure to return to the fallback after reset.

The following are out of scope:

- stock IPTSD or generic udev auto-start on the live G6 node;
- any transport-backed raw GET/SET/OUTPUT request, mode change, firmware/CFU
  operation, or replay of unknown reports during discovery;
- firmware flashing, SPI scans, spidev competition, descriptor substitution,
  or vendor/product spoofing;
- generic HID-over-SPI deployment before QSPI and lifecycle parity are proven;
- simultaneous generic HID touch and the existing finger device;
- public raw strokes, handwriting, firmware, private captures, or proprietary
  research material; and
- a combined transport, parser, packaging, and persistent-default migration in
  one trial.

## Upstream destinations

Route the generic HID child and HID-over-SPI work to Linux HID/input
maintainers, generic GENI/GPI changes to their Qualcomm subsystem maintainers,
and Denali device-tree data to arm64 Qualcomm/DT maintainers. Offer an
independently justified G6 backend to IPTSD only if its maintainers accept the
architecture. Keep packaging, service policy, recovery tooling, and target
evidence in this support repository.
