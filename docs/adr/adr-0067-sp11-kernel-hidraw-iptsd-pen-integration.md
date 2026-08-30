---
id: adr-0067-sp11-kernel-hidraw-iptsd-pen-integration
title: "ADR0067: SP11 Kernel HIDRAW Bridge and Pinned iptsd Pen Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for exposing the Surface Pro 11 G6 DFT stylus stream through a private HIDRAW compatibility device and decoding it with pinned upstream iptsd while retaining direct kernel touch.
---

# ADR0067: SP11 Kernel HIDRAW Bridge and Pinned iptsd Pen Integration

## Status

Accepted for X1E/OLED integration on 2026-08-30 on matching
`sp11/integration-7.2.x-pen-part-2` branches. ARM64 kernel builds, checkpatch,
the pinned userspace build, manifest verification, offline installation, final
v19 kernel packaging, and live pressure, tilt, and barrel-button testing pass.
X1P hardware, eraser transitions, transport recovery, repeated suspend/resume,
OpenEmbedded recipe parse/build validation, and release qualification remain.

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
- The driver defaults to the validated Phase 84 profile: SET_FEATURE `0x05`
  minimal initialization, one response per level-low IRQ, bounded ready-line
  quiescing, and cold host-fault recovery. Read-only module parameters retain a
  load-time fallback without installing a global modprobe configuration that
  could affect an older fallback kernel.

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

## X1E/OLED Live Acceptance — 2026-08-30

The installed `7.2.0-jg-0sp11v19-qcom-x1e` package from kernel commit
`ec96c9da79af` was booted with the Phase 84 values later promoted to the driver
defaults. The support checkout was at `6e7aaeee4bfc`. The system exposed one
`045e:0c83` HIDRAW bridge, one iptsd process, and one virtual stylus; iptsd
reported zero restarts.

An 18-second dual-device capture produced 3,903 virtual-stylus events. Pressure
ranged from 0 through 3309, both tilt axes varied, hover/tool entry and exit
were observed, and the barrel button was confirmed manually immediately after
the capture. Normal one-, two-, and three-finger touch was then confirmed to
work as expected. The native raw-HEAT pen device remained silent as expected
for the DFT/iptsd production path.

The driver ended at 5,059 interrupts and 5,059 handled interrupts, with 5,058
single-response cadence IRQs; that one-count difference was already present at
the post-boot baseline before the capture. All 5,057 subsequent IRQs were
accounted for by two report `0x07` records plus DFT reports `0x0b=2022`,
`0x0c=1011`, `0x0d=1011`, and `0x1a=1011`. Panel resets, recovery failures,
host-fault recoveries, transport errors, protocol errors, drain overflows, and
kernel taint remained zero.

This accepts the core X1E installed-system pen path for integration. It does
not claim X1P, eraser, forced transport recovery, or repeated suspend/resume.

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
- X1E live acceptance establishes the core pen path, dynamic HIDRAW discovery,
  a single daemon/device owner, pressure, two-axis tilt, the barrel button, and
  normal one-, two-, and three-finger touch. Before release, complete X1P,
  eraser, edge/corner, comprehensive touch/gesture regression, transport
  recovery, multiple cold boots, and repeated suspend/resume gates.
- The live-image builder carries the installer and payload on `SP11DATA`; it
  does not inject iptsd into the running live desktop. Live-session and
  installed-system behavior remain separate test gates.
