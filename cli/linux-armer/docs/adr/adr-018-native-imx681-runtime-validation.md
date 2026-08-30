---
id: adrs-adr018
title: "ADR018: Native IMX681 runtime validation"
description: Architecture decision for bounded media discovery, private RAW10 capture evidence, and honest hardware qualification.
---

## Status

Accepted on 2026-08-30.

## Context

The IMX681 integration has separate kernel-transport, image-content, processed-userspace, and physical-device gates. A complete packed RAW10 file can prove that userspace dequeued full buffers, but it cannot by itself prove the physical Bayer order, useful exposure, correct privacy-LED lifetime, repeated lifecycle stability, or processed browser output. A quiet kernel log is also incomplete evidence while the tested camera path masks some CSID and VFE error interrupts.

The earlier runtime validator encoded the proven route and its safety boundaries in a large shell program with an embedded Python analyser. That left a supported hardware workflow outside the companion CLI, required the repository checkout after installation, and made consistent process, path, cancellation, privacy, and machine-readable output policy difficult to enforce.

Camera topology text is not trusted input. Entity names, device nodes, negotiated formats, links, logs, and output paths all cross a boundary controlled by the running host. The validator must not convert that text into shell syntax, follow an arbitrary device path, overwrite an existing capture, retain unbounded logs, or expose process identifiers. It must never introduce MMIO reads: accessing an inactive Surface camera power or clock domain can hang the bus.

## Decision

The `camera capture` domain will own the exact transient IMX681 route from the sensor through `msm_csiphy2`, `msm_csid0`, and `msm_vfe0_rdi0` to one discovered video node. Cobra exposes the workflow as `userspace camera capture`; the existing native renderer remains `userspace camera render`.

The command accepts ten through one hundred frames, an optional new output path, an optional exact running-kernel ABI, a read-only dry run, and JSON delivery. An omitted ABI still has a compiled gate: the running release must be a Surface `qcom-x1e` integration ABI at or after the generation that introduced the standalone IMX681 route. Dry-run discovery validates the loaded modules, exact graph, device types, permissions, and lack of current device users without changing the graph or reserving output files.

Production capture is Linux-only. It uses direct argument vectors for a fixed executable vocabulary and never invokes a shell. Short metadata operations and the stream receive separate deadlines. Standard output and error are bounded, external commands receive a stable C locale, standard input is closed, and cancellation terminates the child. The device-use probe discards process identifiers and reports only whether a selected node is busy.

The parser accepts a bounded `media-ctl` topology but treats every derived value as hostile. It requires one enabled IMX681 source link to the compiled PHY, declared PHY-to-CSID and CSID-to-VFE connections, and one enabled VFE capture target. An unexpected enabled target makes the route ambiguous and fails the operation. After configuration, every connection in the sensor-to-video chain must be present and enabled. Device nodes must use the fixed `/dev/mediaN`, `/dev/videoN`, or optional `/dev/v4l-subdevN` forms. Entity names must remain within a printable allow-list and cannot contain quoting, bracket, escape, or control characters that could change the media-controller mini-language.

The negotiated sensor media-bus code selects one of the four explicit Bayer orders and its corresponding packed V4L2 fourcc. The manager enables only the two mutable links needed by the proven path, applies 3840 by 2640 RAW10 to every compiled pad, configures the video node, then rereads and validates every negotiated pad, fourcc, stride, and image size. It does not reset unrelated links or install persistent configuration.

Output is a closed private set: raw bytes, topology before and after configuration, bounded V4L2 log, filtered post-capture kernel log, and a JSON sampled-content report. Every path must be absent and is reserved with exclusive creation and mode `0600` beneath a caller-controlled private directory or a newly created mode-`0700` temporary directory. Existing files, symbolic final paths, unsafe parent permissions, invalid UTF-8, and control-bearing names are rejected. Retained evidence is reopened only through a no-follow regular-file gate. A failed operation deliberately retains any reserved evidence so the failure can be reviewed.

The capture requires exactly 12,672,000 bytes per frame and validates every non-zero `bytes-used` report emitted by the installed V4L2 utility. The native analyser reads one frame at a time, hashes complete frames, deterministically samples packed RAW10 groups, rejects adjacent byte-identical or sampled-identical frames, and computes range, distinct-code count, population standard deviation, Shannon entropy, and minimum adjacent temporal change. The gates reject a sampled range below eight codes, fewer than eight distinct codes, standard deviation below one code, or entropy below one bit. Complete frame hashes stay in the private statistics sidecar rather than terminal guidance.

Post-capture kernel evidence is collected from the current boot through a bounded journal query with a bounded dmesg fallback. Only camera-related lines are retained. Emitted FIFO overflow or overrun, image-violation, truncation, stop-timeout, or halt-timeout text fails the run. The command does not infer that hidden hardware status is clean merely because no such line was emitted.

A successful result is deliberately named a transport and sampled-content pass. `hardware_qualified` remains false. Human output requires the operator to render and inspect a frame, observe that the privacy LED is off while idle, on only throughout streaming, and off after success or failure, and repeat start/stop plus suspend/resume. Processed libcamera, PipeWire, browser, exposure, gain, colour, and calibration tests remain separate gates.

## Consequences

- A released or on-media CLI can run the supported raw-camera diagnostic without a source checkout, shell validator, or Python analyser.
- Future distributions may reuse the runtime command because it depends on Linux media-controller semantics rather than an Ubuntu package layout.
- The exact current SP11 route remains compiled policy; a different sensor, PHY, CSID, VFE, mode, or layout requires an explicit reviewed change rather than heuristic selection.
- Private raw data and complete frame identities remain local evidence and are never added to an ISO companion, release bundle, diagnostic archive, or ordinary command output automatically.
- Device-busy checks and a dry run reduce interference with desktop camera clients, but the real command still changes transient graph state and must run only after those clients are closed.
- The command cannot prove masked hardware status, privacy-LED behaviour, lifecycle stability, or processed application output. Those limitations are part of the result contract rather than hidden caveats.
