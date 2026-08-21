---
id: adr-0060-pen-integration-status
title: "ADR0060: Pen Integration Status: Hover Validated, Tap-to-Click Deferred"
# prettier-ignore
description: Architecture Decision Record (ADR) for integrating validated G6 pen hover while deferring desktop tap-to-click and full pen parity.
---

# ADR0060: Pen Integration Status: Hover Validated, Tap-to-Click Deferred

## Status

Accepted (2026-08-21). Live-hardware hover and position validation is complete.
Tap-to-click behavior and full button and tool parity are deferred to a
follow-up. This decision advances the evidence-gated userspace design recorded
in ADR0059.

## Context

ADR0059 delivered the evidence-gated `g6-pen` userspace daemon with hardware
output disabled until presence and position could be validated. Testing on a
Surface Pro 11 has now established that the report `0x0c` FF00 max-energy
decode can gate presence with energy thresholds. Per-bank index hysteresis
stabilizes the decoded position, and a one-second stale watchdog releases the
pen when it leaves range without a final decodable cycle. In practice,
out-of-range transitions do not produce usable cycles, so release normally
arrives through this stale path.

Tap detection was reworked around a stillness window. A tap candidate must
remain within two percent on each axis for 60-800 ms at the end of hover. The
window ends at the last decoded cycle rather than at the later stale deadline,
so the watchdog delay cannot turn a short hover into a long one. During live
testing, the lift path exposed a pacer bug: cancelling the queued position
frames also swallowed the generated tap frames. Tap frames marked with
`G6_VALID_TAP` now bypass pacing and reach uinput as `BTN_TOUCH` down and up.

Desktop behavior remains incomplete. It has not yet been demonstrated that a
compositor converts those `BTN_TOUCH` events into clicks, and the correct
right-click button semantics remain unvalidated.

## Decision

Merge the current pen implementation into the integration line now. Validated
hover and position handling need not wait for desktop tap-to-click parity.

Follow-up work will complete and validate:

- tap-to-click behavior on a desktop compositor;
- pen button and eraser mapping; and
- production enablement of `g6-pen.conf`.

## Consequences

- Hardware pen output remains experimental rather than production-ready.
- The validated hover-only path can be used safely with energy-gated presence,
  stable position selection, and stale release.
- Tap frames reach uinput, but taps may not become desktop clicks until the
  deferred compositor work is completed.
- Button, eraser, and full pen-parity claims remain out of scope for the
  current integration state.
