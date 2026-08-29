---
id: adr-0067-sp11-kernel-hidraw-iptsd-pen-integration
title: "ADR0067: SP11 Kernel HIDRAW Bridge and Pinned iptsd Pen Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for exposing the Surface Pro 11 G6 DFT stylus stream through a private HIDRAW compatibility device and decoding it with pinned upstream iptsd while retaining direct kernel touch.
---

# ADR0067: SP11 Kernel HIDRAW Bridge and Pinned iptsd Pen Integration

## Status

Proposed and build-verified on 2026-08-29 on matching
`sp11/integration-7.2.x-pen-part-2` branches. ARM64 kernel object builds,
checkpatch, the pinned userspace build, manifest verification, and offline
installation pass. Device testing, suspend/resume qualification, packaging of
the final kernel build, OpenEmbedded recipe parse/build validation, merge, and
release are pending.

This is integration in the SP11 kernel fork, not a claim of upstream Linux or
mainline support.

## Context

The existing `mshw0485_touch` driver owns the Surface Pro 11 G6 QSPI transport,
panel mode, recovery, and direct multitouch input. Its native pen descriptor
describes the final HID contract, but the panel emits DFT reports `0x0b`,
`0x0c`, `0x0d`, and `0x1a` rather than final native pen report `0x01`.

ADR0059 created a safe raw `/dev/g6ts-heat` ABI and a replayable experimental
processor. That work remains valuable for diagnostics, but the checked-in
`g6-pen` configuration is intentionally fail-closed and does not implement the
complete proprietary stylus processor.

Upstream `iptsd` already decodes this DFT protocol and emits standard Linux
stylus events. The `turbineBMW/surface-pro-11-linux` integration provides
useful independent evidence for hover, strokes, and eraser behavior with
`iptsd`, plus a practical udev/systemd/sleep lifecycle. Its touchscreen
transport differs from this tree, so that evidence cannot qualify this bridge
without testing it on the target kernel.

## Decision

The SP11 kernel driver will create a secondary, private-group HID device after
the physical report descriptor and product identity are validated.

- The secondary device starts with `HID_CONNECT_HIDRAW` only. The existing
  kernel path remains the sole direct touchscreen input provider.
- The bridge relays only DFT reports `0x0b`, `0x0c`, `0x0d`, and `0x1a` as
  `report ID || content`. It does not relay report `0x07` or privacy-sensitive
  sideband report `0x6e`.
- Feature GET `0x06` is proxied once to the panel and cached. Feature SET
  `0x05` values zero and one are acknowledged locally without changing panel
  mode, because the kernel transport remains the mode owner. Other feature and
  output requests are rejected.
- A transport generation boundary destroys the old HIDRAW device through a
  deferred worker outside the transport mutex. A new device appears only after
  the controller has recovered and its descriptor is unchanged.
- `/dev/g6ts-heat` remains available for bounded diagnostics and replay; it is
  not the production pen input path.

Userspace will use unmodified upstream `iptsd` v3.1.0 at commit
`a83bc1232f7096f8b33b50fdbda249cd640de670`, tree
`06c6e812873e117930eca60b8a32cec40fd13281`.

- Device-specific presets match `045e:0c80` and `045e:0c83`, disable iptsd's
  virtual touchscreen, and leave stylus processing enabled. Metadata supplies
  dimensions; the presets do not hard-code panel geometry.
- A guarded udev rule starts a dynamically instantiated systemd service for
  the matching HIDRAW node. `BindsTo=` stops it when that node disappears.
- A system-sleep hook stops the daemon before device suspend, then discovers
  and verifies the recreated node after resume.
- The lifecycle assets are adapted under the MIT license from
  `turbineBMW/surface-pro-11-linux` commit
  `05e5335bc72476d44390336701cf03efa5fd0165`.
- The production package conflicts with `g6-pen`, whose service is no longer
  enabled automatically, and with a generic `iptsd` package. The local
  installer masks generic `iptsd@.service`, while the SP11 udev rule replaces
  an earlier generic service request. Only one processor may own the stream.
- ARM64 payload builds include exact source identity, hashes, licenses, and the
  complete Meson fallback sources and patches linked into the binaries.

## Alternatives Considered

**Finish the proprietary `g6-pen` decoder first (deferred).** It preserves a
valuable research path, but complete presence, pressure, buttons, eraser, tilt,
and fine-position mappings are not all established in that implementation.

**Decode DFT reports directly in the kernel (rejected for this integration).**
That would duplicate a mature, changeable signal processor in privileged code
and make iteration and regression testing harder.

**Use UHID from the existing raw ABI (rejected).** Report `0x1a` is 4,350 bytes
including its report ID, which exceeds UHID's 4,096-byte report limit.

**Let iptsd own physical panel mode and touch (rejected).** The custom kernel
driver already provides validated direct touch and recovery. Competing mode
writes or a second virtual touchscreen would regress that path.

## Consequences

- The kernel change is a compatibility bridge while stylus signal processing
  remains in userspace.
- Direct touch should remain unchanged and duplicate iptsd touch output is
  disabled by device-matched policy.
- Reset and suspend recreate HIDRAW, so the old daemon must exit promptly and
  queued pre-reset reports must not produce ghost input. This is a mandatory
  hardware validation gate.
- Unmodified iptsd v3.1.0 advertises one stylus button (`BTN_STYLUS`). A
  second/top-button event is outside this candidate and remains a known
  userspace limitation.
- A successful build does not establish pen parity. Before merge, verify
  dynamic HIDRAW discovery, a single daemon/device owner, hover and immediate
  lift, edge and corner position, continuous strokes, pressure, tilt, barrel
  button, eraser transitions, unchanged multitouch and gestures, transport
  recovery, cold boot, and repeated suspend/resume cycles.
- The live-image builder carries the installer and payload on `SP11DATA`; it
  does not inject iptsd into the running live desktop. Live-session and
  installed-system behavior remain separate test gates.
