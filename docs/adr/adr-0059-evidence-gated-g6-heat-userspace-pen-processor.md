---
id: adr-0059-evidence-gated-g6-heat-userspace-pen-processor
title: "ADR0059: Evidence-Gated G6 HEAT Userspace Pen Processor"
# prettier-ignore
description: Architecture Decision Record (ADR) for processing the Surface Pro 11 G6 pen HEAT stream in evidence-gated userspace with fail-closed input synthesis.
---

# ADR0059: Evidence-Gated G6 HEAT Userspace Pen Processor

## Status

Accepted and offline-verified (2026-08-21), then superseded for production pen
input by ADR0067 (2026-08-29). This decision is retained for the raw
`/dev/g6ts-heat` diagnostic and replay architecture. Implemented by commit
`7f76bf5b17660024d320d90ef65cd7dc24461fa8`, which adds the daemon,
deterministic replay, typed uinput integration, systemd unit, and OpenEmbedded
recipe. The implementation has passed macOS and Linux builds, sanitizer runs,
static analysis, and replay of the P4-P8 capture corpora. Live hardware pen
output remains deliberately disabled until the raw presence and
contact-related mappings are validated; this status does not claim
hardware-verified pen parity.

## Superseding note (2026-08-29)

ADR0067 replaces `g6-pen` as the production pen-input direction. The raw ABI,
daemon, and replay tooling remain available for controlled diagnostics, while
the package no longer enables `g6-pen.service` automatically. This note does
not rewrite the accepted decision below.

## Context

The Surface Pro 11 G6 touchscreen exposes a native HID pen descriptor, but the
captured firmware traffic does not contain native pen report `0x01`. Windows
instead consumes proprietary HEAT reports `0x0b`, `0x0c`, `0x0d`, and `0x1a`
as a five-report cycle, with ordered `0x07` and `0x6e` sideband, and
synthesizes the final pen report in software.

The Phase-1 Windows HID-SPI and ETW investigation established enough structure
to build a bounded parser and replayable transport:

- report `0x0c` anchors the cycle, whose remaining core reports occur in six
  observed orderings;
- the region-1, channel-6 kind-`0x5c` record contains two banks of fixed-size
  DFT vectors whose strongest valid centers track the X and Y sensor axes;
- generation changes, explicit transport boundaries, sequence gaps, and stale
  input must be authoritative safety events; and
- native pressure, presence, fine position, barrel-button, eraser/tool, and
  tilt mappings are not yet established from raw HEAT data.

Most importantly, the available captures do not provide a safe presence
classifier. All aligned raw P4/P5 cycles had processor presence set, while a
proxy comparison against final in-range output showed substantial overlap
between positive and negative energy features. Signal also persists for some
cycles after Windows closes tracking. Enabling a guessed threshold could
therefore create false hover or contact.

Kernel commit `13e51c469a2aeb596d6961da1cab8e4169f33dcd` exports exact HEAT
content through the versioned `/dev/g6ts-heat` record ABI. The kernel remains
responsible for transport integrity, ordering, and lifecycle boundaries; it
does not embed unverified pen-recognition policy. A separate architecture is
needed to iterate on the proprietary signal processing safely, reproduce
results without hardware, and integrate the eventual processor into the
OpenEmbedded image.

## Decision

We will process G6 HEAT pen data in the `g6-pen` userspace service and keep the
kernel interface limited to the versioned raw transport ABI.

- Live operation must validate ABI v1 with `G6_HEAT_IOC_GET_INFO` before
  creating a uinput device. Each read is one complete record containing exact
  HID content without the report ID.
- The processor anchors on report `0x0c`, accepts the six observed core report
  orderings, preserves the two `0x0b` instances, and treats `0x07` and `0x6e`
  as opaque sideband that cannot open or complete tracking.
- A reset, suspend, transport fault, generation change, sequence gap, or stale
  watchdog expiry must cancel pending samples and emit an immediate lift.
  Reacquisition after a transport discontinuity requires a structurally valid
  clear cycle; malformed or positive-looking traffic cannot clear the inhibit
  state. Incomplete and unsupported cycles are discarded without producing
  input.
- The bounded `ff00-0c-max-energy` decoder may expose the evidence-backed coarse
  X/Y path for diagnostics. It must require the observed v1 record shape,
  region 1, channel 6, and valid vector trailers, while treating the varying
  mode byte as opaque.
- The shipped configuration keeps `hover.enabled=false`. Presence and fine
  position require additional evidence before production use. Tip/contact,
  pressure, barrel and secondary buttons, eraser/tool state, and signed tilt
  remain hard-gated in code with no configuration escape hatch until their raw
  HEAT mappings are independently validated.
- The uinput device advertises the synthesized processor contract: X/Y maxima
  `27388/18258` at 100 units/mm, pressure `0..4096`, and signed tilt
  `-9000..9000` at 5730 units/radian. Gated fields remain released or zero.
  Once enabled, each core position interval is emitted as four reports paced
  3.75 ms apart; lift and lifecycle boundaries always preempt the pacer.
- Binary ABI replay and the reviewable `G6T1` text form are first-class inputs.
  Replay is unpaced and timestamp-driven so identical input produces identical
  JSON output. Corpora containing report `0x6e` must be sanitized before they
  are shared because that sideband may contain a device or pen identifier.
- `meta-sp11` owns the OpenEmbedded recipe and systemd integration. The service
  waits for `/dev/g6ts-heat` and `/dev/uinput`, and the raw device permits only
  one reader.
- A feature gate may be relaxed only after captures supply positive and
  negative evidence, the raw mapping and units are documented, deterministic
  regression coverage is added, and the change receives independent review.

## Alternatives Considered

**Implement the proprietary processor in the kernel (rejected).** The mappings
are incomplete and are expected to evolve as captures improve. Userspace keeps
unverified signal processing out of a privileged transport driver and supports
sanitizers, deterministic corpus replay, and faster iteration.

**Synthesize native report `0x01` directly from guessed fields (rejected).** No
native `0x01` appeared in the captures, and the descriptor defines only the
output contract, not how HEAT fields produce presence, pressure, tool state, or
tilt.

**Enable the coarse decoder with heuristic presence thresholds (rejected).**
The measured positive and negative proxy classes overlap. The available data
cannot support a threshold with an acceptable false-input guarantee.

**Use the generic rectangular-centroid decoder as the production map
(rejected).** It is useful for synthetic tests and future validated layouts,
but it does not represent the observed nested DFT-vector format.

**Defer all implementation until every proprietary mapping is known
(rejected).** The versioned transport, lifecycle safety rules, deterministic
replay, packaging, and evidence-gated architecture are independently useful
and reduce the risk of later field-map work.

## Consequences

- The default image can package and run the service without generating false
  pen input. At present it consumes and validates traffic but creates only a
  typed, lifted pen device, so functional pen input remains unavailable by
  design.
- Kernel and userspace responsibilities are explicit: the kernel preserves raw
  records and lifecycle integrity, while userspace owns cycle assembly, signal
  processing, pacing, policy, and uinput emission.
- Captured traffic can reproduce parser and state-machine behavior on systems
  without SP11 hardware. The P4-P8 corpus exercised 3,156 cycles with no
  sequence gaps, incomplete bundles, or unanchored records; one valid P4
  region-0 cycle was correctly rejected as unsupported.
- Coarse center selection is not the proprietary fractional-position solver
  and can differ by roughly 219 X or 217 Y HIMETRIC units after scaling. It
  must not be described as full pen parity.
- Enabling hover requires a validated presence discriminator. Contact,
  pressure, buttons, eraser/tool state, and tilt require separate raw mappings
  and regression evidence.
- The service becomes a required runtime component for synthesized G6 pen
  input and exclusively owns `/dev/g6ts-heat` while active. ABI versioning
  constrains coordinated kernel/userspace upgrades and concurrent diagnostics.
- Unsanitized report `0x6e` data and replays that include it remain private.
