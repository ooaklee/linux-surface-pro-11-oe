---
id: adrs-adr010
title: "ADR010: Native CLI ownership of maintained workflows"
description: Architecture decision for replacing legacy repository scripts with typed, testable linux-armer domains while preserving specialist and historical context.
---

## Status

Accepted on 2026-08-30.

## Context

The repository accumulated shell and Python helpers while Surface Pro 11 support was being discovered. Some helpers still implement necessary kernel, firmware, Bluetooth, IPTSD, camera, diagnostic, release, and removable-media workflows. Others install out-of-tree touchscreen modules, manual WSA routing, PipeWire sinks, raw-GPT live images, or broad support bundles that the current integration kernel and direct hybrid-ISO adapter have superseded.

Exposing a Cobra command that merely invokes one of those helpers does not make the workflow part of the CLI. It preserves two behaviour contracts, keeps validation in an untyped subprocess, and prevents the released companion binary from operating without a repository checkout. Porting every historic branch is also unsafe because it would present retired workarounds as supported choices.

The maintained CLI must support a complete path from host preparation through kernel and userspace acquisition or building, ISO creation and validation, removable-media writing, installed-system hand-off, and bounded diagnosis. It must remain suitable for future distribution adapters. Windows-only collection cannot run inside a Linux executable, but its output needs a strict contract that the CLI can validate and consume. Some firmware and audio files have redistribution restrictions, and release publication changes external state.

Historical ADRs and dated hardware reports explain how the current support was discovered. Rewriting them to remove old command names would falsify that history, while leaving current how-to guides pointed at retired helpers would mislead operators.

## Decision

Maintained workflows will be implemented as typed Go domains and orchestrated by managers. Cobra commands and the Bubble Tea wizard will parse input, call managers, and render results; they will not contain hardware policy or reproduce orchestration. The project will not introduce a generic script-runner abstraction.

The command roots are `catalog`, `kernel`, `image`, `userspace`, `handoff`, `doctor`, `clean`, and `wizard`. New behaviour will be placed under the domain that owns its outcome:

- `kernel` owns source resolution, building, bundle inspection, guarded installation, preflight checks, and release preparation or validation;
- `image` owns creation, structural validation, removable-device discovery, writing, and read-back verification;
- `userspace` owns component acquisition, building, receipt-backed installation or removal, and installed support status;
- `handoff` owns private, device-bound import and application of Windows-collected platform firmware and Bluetooth evidence;
- `doctor` owns read-only host, kernel, hardware, and userspace evidence, with sensitive values redacted by default;
- `clean` owns only recognised, reversible removal of retired workarounds and explicitly managed build caches;
- `wizard` remains a terminal interface over the same managers and policies as non-interactive commands.

Distribution-neutral packages will own kernel bundles, companion payloads, userspace receipts, Windows hand-offs, removable media, plans, journals, and platform process boundaries. Each distribution adapter will continue to own its bootloader, initramfs, installer, and live-media discovery contract. Ubuntu therefore retains its Casper UUID contract without making Casper concepts part of the removable-media writer or future Fedora and Debian adapters.

Every mutating workflow will support a deterministic preview. System mutations will use explicit target roots, exact allow-lists, precondition revalidation, private backups where restoration is possible, and a receipt or journal. A command operating on the running root may accept `/` only when that mode is explicitly part of its contract and the caller has already obtained the required privilege; an alternate-root command will never silently fall back to `/`.

Writing installation media is irreversible and receives a stronger boundary. Device discovery will issue an opaque identity bound to the whole external removable USB device. A write plan will bind the canonical source path, image size and SHA-256 digest to that identity. Execution will require the exact confirmation phrase from the plan, re-inspect the device, reject identity drift, system storage, read-only or undersized devices, and an image stored on the target. After confirmation and privilege checks, the manager may unmount observed target filesystems; it must then perform another inspection and reject any remaining mount before opening the raw device. Success requires a flushed write and SHA-256 read-back of exactly the source length; an operating-system command reporting that bytes were copied is not sufficient evidence.

Windows collectors will emit a single JSON document with a versioned envelope, a fixed kind, collection time, producer identity, privacy classification, and a kind-specific payload. Device binding will use a fresh random salt and a domain-separated digest of that salt and the canonical SMBIOS system UUID. This lets the target re-derive and compare the binding without exporting the UUID or making separate hand-offs trivially linkable. The Go decoder will reject unknown fields, unsupported versions, malformed hardware addresses, duplicate or contradictory candidates, and data that does not match the selected Surface model. Sensitive Bluetooth addresses will be accepted from a mode-restricted file or standard input, never required on the command line, and redacted in ordinary output.

A Windows hand-off is private device data, not an image or userspace-release manifest. The whole document and payload are private, including firmware provenance, times, device binding, and the Bluetooth address. `handoff import` will store it through a content-addressed, mode-restricted transaction, `handoff apply` will revalidate it before mutation, and `handoff purge` will provide confirmed retention control. The hand-off will never be embedded in a redistributable ISO, and image validation will test that exclusion. The Windows collector itself may be included as an ordinary, manifest-tracked companion file because it contains no collected device data. Wi-Fi board firmware remains owned by the distribution's Linux firmware package and is not inferred from Windows network-adapter data.

Release preparation and publication remain separate operations. Preparation will create a closed, checksummed, policy-checked artefact set without changing a remote service. Any future publication command must use an additional explicit confirmation, preserve draft-first recovery, re-download and validate the published assets, and refuse content whose redistribution terms are not declared. Implementing preparation does not authorise the CLI or an automation to publish a release.

The 39 files in the legacy `scripts` directory are divided by evidence rather than by extension:

1. Sixteen superseded implementations will stop appearing in current how-to paths and will be deleted after focused current-kernel, image, installed-boot, and cleanup checks pass.
2. Twenty-one maintained behaviours will be ported and parity-tested before their helpers are deleted. A command that still invokes Bash does not satisfy this gate.
3. Two specialist behaviours, annotation regeneration and optional Ubuntu desktop replacement, will be rehomed with their appropriate maintainer or example ownership rather than promoted into the hardware companion API.

Current how-to documentation will be rewritten around the CLI as each native contract lands. Dated test reports will retain their observations and commands but gain a prominent historical, non-prescriptive notice and a link to the current command. Existing ADRs will retain their original decision record and may gain a superseded-status note or a link to this decision.

A legacy helper may be removed only when all of the following are true:

- the replacement has unit tests for its policy and hostile inputs;
- CLI integration tests cover preview, success, and failure delivery;
- any destructive path has revalidation, interruption, and recovery coverage;
- the respective current documentation uses the replacement command;
- no production Go path invokes the helper or a generic shell wrapper;
- relevant cross-platform builds, race tests, static checks, doc-comment checks, and British-English checks pass;
- required hardware behaviour that cannot be simulated is recorded as an outstanding hardware gate rather than claimed from structural tests.

The following register records the initial disposition of every file in the legacy directory. It is an architectural scope record, not a claim that a port or hardware gate has already completed.

| Legacy file | Initial decision | Maintained owner or retirement evidence |
| --- | --- | --- |
| `build-sp11-imx681-libcamera-docker.sh` | Port | Native camera build domain and coherent-package validation |
| `build-sp11-iptsd-docker.sh` | Port | Native IPTSD build domain and portable release receipt |
| `build-sp11-live-usb-image.sh` | Retire | Direct hybrid-ISO creation and validation |
| `build-sp11-qcom-x1e-kernel-docker.sh` | Port | Native containerised kernel-build manager |
| `build-sp11-qcom-x1e-kernel.sh` | Port | Kernel source, package, preflight, and install domains |
| `build-sp11-touchscreen-modules.sh` | Retire | Current in-tree touchscreen stack and stale-module cleanup |
| `collect-sp11-kernel-source-metadata.sh` | Retire | Immutable Git revision provenance |
| `finish-sp11-installed-system.sh` | Port by decomposition | Image hand-off plus focused firmware, Bluetooth, and status domains |
| `install-sp11-iptsd.sh` | Port | Receipt-backed atomic IPTSD installer and rollback |
| `install-sp11-support.sh` | Retire | Focused current installers; no broad legacy support bundle |
| `install-sp11-touchscreen.sh` | Retire | Current in-tree touchscreen stack and reviewed cleanup |
| `preflight-sp11-kernel-test.sh` | Port | `kernel preflight` policy and recovery evidence |
| `prepare-sp11-audio-release-assets.sh` | Retire | Current FullIO audio release contract |
| `prepare-sp11-image-release-assets.sh` | Retire | Current ISO, manifest, and journal release contract |
| `prepare-sp11-installed-system.sh` | Retire | Adapter-owned installed-system hand-off |
| `prepare-sp11-kernel-release-assets.sh` | Port | `kernel release prepare` and closed-set validation |
| `publish-sp11-audio-release.sh` | Port | Policy-gated userspace release preparation and explicit publication boundary |
| `publish-sp11-imx681-libcamera-release.sh` | Port | Coherent camera release preparation and validation |
| `regenerate-qcom-x1e-annotations.sh` | Rehome | Kernel-source maintainer tooling, outside the companion API |
| `render-sp11-imx681-raw.py` | Port | Camera RAW parser and deterministic preview domain |
| `sp11-audio-migrate-to-native.sh` | Retire | Current FullIO installer and legacy cleanup |
| `sp11-audio-topology.sh` | Retire | Current FullIO topology and UCM contract |
| `sp11-bluetooth-mac.sh` | Port | Private hand-off, configuration, apply, and removal transaction |
| `sp11-enable-wsa-routing.sh` | Retire | Native FullIO routing and recognised cleanup |
| `sp11-fix-audio-boot-race.sh` | Retire | Current kernel audio sequencing and recognised cleanup |
| `sp11-grab-fw.sh` | Port | Strict Windows hand-off import and firmware transaction |
| `sp11-install-kde-desktop.sh` | Rehome | Optional Ubuntu example, outside hardware enablement |
| `sp11-pipewire-speaker-sink.sh` | Retire | Native FullIO PipeWire exposure and user-scoped cleanup |
| `sp11-wifi-board-fixup.sh` | Port conditionally | Pinned board-data inspection; apply only with exact hardware evidence |
| `systemd/sp11-pipewire-restart.service` | Retire | Native FullIO startup and exact cleanup recognition |
| `systemd/sp11-wsa-routing.service` | Retire | Native FullIO routing and exact cleanup recognition |
| `troubleshoot-sp11-audio.sh` | Port | Redacted, bounded audio doctor evidence |
| `troubleshoot-sp11-bluetooth.sh` | Port | Redacted, timeout-bounded Bluetooth doctor evidence |
| `troubleshoot-sp11-touchscreen.sh` | Retire | Current in-tree touchscreen doctor; discard obsolete success criteria |
| `troubleshoot-sp11-wifi-rfkill.sh` | Port | Read-only Wi-Fi and kernel doctor evidence |
| `validate-sp11-imx681-raw.sh` | Port | Camera graph, capture, privacy, and RAW validation domain |
| `validate-sp11-iptsd-payload.sh` | Port | Native closed-set IPTSD release validator |
| `validate-sp11-touchscreen-release.sh` | Port in part | Generic kernel release validation; discard out-of-tree requirements |
| `write-image-to-macos-disk.sh` | Port | Cross-platform device discovery, write, flush, and read-back verification |

## Consequences

- A released companion binary can perform maintained workflows without carrying the repository's legacy script directory.
- Retired workarounds disappear from the supported path instead of becoming permanent CLI flags.
- Future image adapters reuse media, bundle, userspace, hand-off, and journalling contracts without inheriting Ubuntu Casper behaviour.
- Destructive writes and installed-system changes become previewable, identity-bound, revalidated, and evidenced.
- Windows-derived values have an auditable interchange format and a private import boundary.
- Maintainer publication remains possible without conflating local artefact preparation with authority to change a remote release.
- Migration requires temporary duplication while each native implementation proves parity; scripts remain until their individual gates pass.
- Structural and simulated checks cannot replace cold-boot, suspend, pen, wireless, Bluetooth, camera, audio, installation, or removable-media tests on actual Surface hardware, so those gates remain explicit.
