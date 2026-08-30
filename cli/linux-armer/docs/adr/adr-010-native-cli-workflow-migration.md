---
id: adrs-adr010
title: "ADR010: Native CLI ownership of maintained workflows"
description: Architecture decision for replacing legacy repository scripts with typed, testable linux-armer domains while preserving specialist and historical context.
---

## Status

Accepted and completed on 2026-08-30. All 38 files that remained in the legacy
`scripts` directory, their obsolete test workflow, and the six associated
root-level test and tool files have been removed. The registers below preserve
the final native owner, explicit retirement, or specialist rehoming outcome
for that historical material. Completion of the software migration does not
claim that every physical hardware gate has passed.

## Context

The repository accumulated shell and Python helpers while Surface Pro 11
support was being discovered. Some helpers implemented necessary kernel,
firmware, Bluetooth, IPTSD, camera, diagnostic, release, and removable-media
workflows. Others installed out-of-tree touchscreen modules, manual WSA
routing, PipeWire sinks, raw-GPT live images, or broad support bundles that the
current integration kernel and direct hybrid-ISO adapter superseded.

Exposing a Cobra command that merely invokes one of those helpers does not make the workflow part of the CLI. It preserves two behaviour contracts, keeps validation in an untyped subprocess, and prevents the released companion binary from operating without a repository checkout. Porting every historic branch is also unsafe because it would present retired workarounds as supported choices.

The maintained CLI must support a complete path from host preparation through kernel and userspace acquisition or building, ISO creation and validation, removable-media writing, installed-system hand-off, and bounded diagnosis. It must remain suitable for future distribution adapters. Windows-only collection cannot run inside a Linux executable, but its output needs a strict contract that the CLI can validate and consume. Some firmware and audio files have redistribution restrictions, and release publication changes external state.

Historical ADRs and dated hardware reports explain how the current support was discovered. Rewriting them to remove old command names would falsify that history, while leaving current how-to guides pointed at retired helpers would mislead operators.

## Decision

Maintained workflows are implemented as typed Go domains and orchestrated by
managers. Cobra commands and the Bubble Tea wizard parse input, call managers,
and render results; they do not contain hardware policy or reproduce
orchestration. The project has not introduced a generic script-runner
abstraction.

The command roots are `catalog`, `kernel`, `image`, `userspace`, `handoff`,
`doctor`, `clean`, and `wizard`. Behaviour is placed under the domain that owns
its outcome:

- `kernel` owns source resolution, building, bundle inspection, guarded installation, preflight checks, and release preparation or validation;
- `image` owns creation, structural validation, removable-device discovery, writing, and read-back verification;
- `userspace` owns component acquisition, building, receipt-backed installation and rollback, and installed support status;
- `handoff` owns private, device-bound import and application of Windows-collected platform firmware and Bluetooth evidence;
- `doctor` owns read-only host, kernel, hardware, and userspace evidence, with sensitive values redacted by default;
- `clean` owns only recognised, reversible removal of retired workarounds;
- `wizard` remains a terminal interface over the same managers and policies as non-interactive commands.

Distribution-neutral packages own kernel bundles, companion payloads,
userspace receipts, Windows hand-offs, removable media, plans, journals, and
platform process boundaries. Each distribution adapter owns its bootloader,
initramfs, installer, and live-media discovery contract. Ubuntu therefore
retains its Casper UUID contract without making Casper concepts part of the
removable-media writer or future Fedora and Debian adapters.

Destructive device and system-mutation workflows support a deterministic
preview. They use explicit target roots, exact allow-lists, precondition
revalidation, private backups where restoration is possible, and a receipt or
journal. A command operating on the running root accepts `/` only when that
mode is explicitly part of its contract and the caller has already obtained
the required privilege; an alternate-root command never silently falls back
to `/`. Build commands instead publish into fresh destinations through their
own transaction contracts; the native IPTSD build does not currently provide a
dry run.

Writing installation media is irreversible and receives a stronger boundary.
Device discovery issues an opaque identity bound to the whole external
removable USB device. A write plan binds the canonical source path, image size,
and SHA-256 digest to that identity. Execution requires the exact confirmation
phrase from the plan, re-inspects the device, and rejects identity drift,
system storage, read-only or undersized devices, and an image stored on the
target. After confirmation and privilege checks, the manager may unmount
observed target filesystems; it then performs another inspection and rejects
any remaining mount before opening the raw device. Success requires a flushed
write and SHA-256 read-back of exactly the source length; an operating-system
command reporting that bytes were copied is not sufficient evidence.

Windows collectors emit a single JSON document with a versioned envelope, a
fixed kind, collection time, producer identity, privacy classification, and a
kind-specific payload. Device binding uses a fresh random salt and a
domain-separated digest of that salt and the canonical SMBIOS system UUID.
This lets the target re-derive and compare the binding without exporting the
UUID or making separate hand-offs trivially linkable. The Go decoder rejects
unknown fields, unsupported versions, malformed hardware addresses, duplicate
or contradictory candidates, and data that does not match the selected
Surface model. Sensitive Bluetooth addresses are accepted from a
mode-restricted file or standard input, never required on the command line,
and redacted in ordinary output.

A Windows hand-off is private device data, not an image or userspace-release
manifest. The whole document and payload are private, including firmware
provenance, times, device binding, and the Bluetooth address. `handoff import`
stores it through a content-addressed, mode-restricted transaction;
`handoff apply` revalidates it before mutation; and `handoff purge` provides
confirmed retention control. The companion builder admits only its fixed
source snapshot, catalogues, binary, and explicitly allowed portable userspace
artefacts, so collected hand-off data cannot enter a redistributable ISO. The
Windows collector itself may be included as an ordinary, manifest-tracked
companion file because it contains no collected device data. Wi-Fi board
firmware remains owned by the distribution's Linux firmware package and is not
inferred from Windows network-adapter data.

Release preparation and publication remain separate operations. Preparation
creates a closed, checksummed, policy-checked artefact set without changing a
remote service. Any future publication command must use an additional explicit
confirmation, preserve draft-first recovery, re-download and validate the
published assets, and refuse content whose redistribution terms are not
declared. Implementing preparation does not authorise the CLI or an automation
to publish a release.

The historical 39-file inventory, including one file already removed from the
legacy `scripts` directory, is assigned one of three outcomes: maintained
behaviour moves into a typed native domain, an obsolete workaround is retired,
or specialist work is rehomed outside the hardware companion API. A command
that merely invokes Bash is not accepted as a native port.

Current how-to documentation uses the CLI. Dated reports and ADRs retain former
commands only as historical evidence, with an explicit non-prescriptive notice
and a current native owner. Links to files selected for retirement were
removed before deletion so the current documentation does not depend on absent
helpers.

Each port or retirement is accepted only after the applicable software gates
below pass:

- the replacement has unit tests for its policy and hostile inputs;
- CLI integration tests cover preview, success, and failure delivery;
- any destructive path has revalidation, interruption, and recovery coverage;
- the respective current documentation uses the replacement command;
- no production Go path invokes the helper or a generic shell wrapper;
- relevant cross-platform builds, race tests, static checks, doc-comment checks, and British-English checks pass;
- required hardware behaviour that cannot be simulated is recorded as an
  outstanding hardware gate rather than claimed from structural tests.

The following register records the final disposition of every file in the
historical legacy directory. A native owner means the CLI owns the maintained
software contract; it is not a blanket hardware-qualification statement.

| Legacy file | Outcome | Native owner, retirement, or rehoming evidence |
| --- | --- | --- |
| `build-sp11-imx681-libcamera-docker.sh` | Native | `userspace build camera`, `userspace camera release prepare`, and `userspace camera release validate` own coherent camera packages |
| `build-sp11-iptsd-docker.sh` | Native | `userspace build iptsd` owns the pinned build and portable receipt |
| `build-sp11-live-usb-image.sh` | Retired | `image create` and `image validate` own the direct hybrid-ISO contract |
| `build-sp11-qcom-x1e-kernel-docker.sh` | Native | `kernel build` owns the containerised kernel build policy |
| `build-sp11-qcom-x1e-kernel.sh` | Native | `kernel build`, `kernel preflight`, and `kernel install` own source, package, and guarded-install behaviour |
| `build-sp11-touchscreen-modules.sh` | Retired | The touchscreen stack is in-tree; `userspace status` reports stale module overrides for manual review |
| `collect-sp11-kernel-source-metadata.sh` | Retired | Native kernel build and release manifests record immutable source provenance |
| `finish-sp11-installed-system.sh` | Native by decomposition | `kernel install`, `userspace install`, `userspace status`, `handoff apply`, and `doctor` own its maintained outcomes |
| `install-sp11-iptsd.sh` | Native | `userspace install iptsd` owns receipt-backed installation and rollback |
| `install-sp11-support.sh` | Retired | Focused native installers, `handoff`, and `doctor` replace the broad legacy bundle |
| `install-sp11-touchscreen.sh` | Retired | The in-tree stack needs no override installer; `userspace status` reports stale module overrides for manual review |
| `preflight-sp11-kernel-test.sh` | Native | `kernel preflight` owns read-only installation and recovery evidence |
| `prepare-sp11-audio-release-assets.sh` | Retired | `userspace audio release prepare` and `userspace audio release validate` own the current FullIO v19c release contract |
| `prepare-sp11-image-release-assets.sh` | Native replacement completed | `image release prepare` and `image release validate` own the ISO, manifest, journal, split, and reconstruction contract |
| `prepare-sp11-installed-system.sh` | Retired | Adapter-owned `image create` output and the focused installed-system commands replace this broad mutation |
| `prepare-sp11-kernel-release-assets.sh` | Native | `kernel release prepare` and `kernel release validate` own closed local release directories |
| `publish-sp11-audio-release.sh` | Native local half; remote half retired | `userspace audio release prepare` and `userspace audio release validate` are local-only; remote publication remains an explicit external maintainer action |
| `publish-sp11-imx681-libcamera-release.sh` | Native local half; remote half retired | `userspace camera release prepare` and `userspace camera release validate` own local proof; the CLI does not publish remotely |
| `regenerate-qcom-x1e-annotations.sh` | Rehomed | Annotation regeneration belongs to kernel-source maintainer tooling, outside the companion API |
| `render-sp11-imx681-raw.py` | Native | `userspace camera render` owns bounded deterministic RAW10 preview generation |
| `sp11-audio-migrate-to-native.sh` | Retired | `userspace install audio`, `userspace status`, and `clean` own installation and recognised cleanup |
| `sp11-audio-topology.sh` | Retired | The checksum-pinned FullIO topology and UCM release replaces generated fallback content |
| `sp11-bluetooth-mac.sh` | Native | `handoff import`, `handoff apply`, and `handoff restore` own private address input and recoverable application |
| `sp11-enable-wsa-routing.sh` | Retired | Current FullIO UCM owns routing; `clean` recognises the workaround |
| `sp11-fix-audio-boot-race.sh` | Retired | Current kernel and FullIO sequencing replace the disproved boot-race workaround |
| `sp11-grab-fw.sh` | Native | `handoff import`, `handoff apply`, and `handoff restore` own strict private Windows material transactions |
| `sp11-install-kde-desktop.sh` | Rehomed | Optional desktop replacement belongs to Ubuntu package-management guidance, not hardware enablement |
| `sp11-pipewire-speaker-sink.sh` | Retired | Current FullIO UCM exposes the speaker path; `clean` recognises user-scoped remnants |
| `sp11-wifi-board-fixup.sh` | Retired | Distribution firmware owns board data; `doctor hardware wifi` reports evidence without mutating it |
| `systemd/sp11-pipewire-restart.service` | Retired | Current FullIO startup no longer needs it; `clean` recognises the unit |
| `systemd/sp11-wsa-routing.service` | Retired | Current FullIO UCM owns routing; `clean` recognises the unit |
| `troubleshoot-sp11-audio.sh` | Native | `doctor hardware audio` and `doctor userspace` own bounded redacted evidence |
| `troubleshoot-sp11-bluetooth.sh` | Native | `doctor hardware bluetooth` owns bounded redacted evidence |
| `troubleshoot-sp11-touchscreen.sh` | Native current part; obsolete criteria retired | `doctor hardware touchscreen`, `kernel preflight`, and `doctor userspace` report current software state without obsolete out-of-tree success criteria |
| `troubleshoot-sp11-wifi-rfkill.sh` | Native | `doctor hardware wifi` owns bounded read-only evidence |
| `validate-sp11-imx681-raw.sh` | Native | `userspace camera capture` owns graph, transport, sampled-content, and emitted-error gates; physical checks stay explicit |
| `validate-sp11-iptsd-payload.sh` | Native | `userspace build iptsd` receipts and `userspace install iptsd` repeat the closed-set proof |
| `validate-sp11-touchscreen-release.sh` | Native generic part; obsolete part retired | `kernel release validate` owns generic package proof; out-of-tree touchscreen requirements are rejected |
| `write-image-to-macos-disk.sh` | Native | `image devices` and `image write` own identity-bound write, flush, and read-back verification |

The migration also removed six root-level files that tested or supported the
legacy helpers. Their final dispositions are recorded separately because they
were never members of the 39-file `scripts` inventory.

| Auxiliary legacy file | Outcome | Native owner or retirement evidence |
| --- | --- | --- |
| `tests/test-iptsd-integration.sh` | Native | `internal/userspace/iptsd/repository_contract_test.go` validates the checked-in integration and layer recipe; the native IPTSD workflow runs the Go contract tests |
| `tests/test-kernel-patch-selection.sh` | Retired legacy semantics; native provenance retained | `internal/kernel/build` builds one immutable requested Git tree, while `internal/kernel/releaseprep` validates the corresponding source and closed release; repository-local patch injection is no longer a supported build mode |
| `tests/test-kernel-test-preflight.sh` | Native | `internal/kernel/install` manager and review tests cover coherent packages, the distinct bootable fallback, GRUB evidence, alternate roots, hostile inputs, rollback, and cancellation |
| `tools/collect-sp11-windows-bluetooth-address.ps1` | Native replacement | `cli/linux-armer/tools/collect-sp11-windows-handoff.ps1` emits the strict same-device private contract consumed by `handoff import`, `handoff apply`, and `handoff restore` |
| `tools/collect-sp11-windows-diagnostics.ps1` | Retired | The broad diagnostic archive exposed unrelated identifiers and had no bounded consumer. The strict Windows hand-off collector admits only reviewed firmware and Bluetooth evidence, while `doctor` owns bounded, redacted Linux diagnosis |
| `tools/sp11-bt-set-addr.c` | Native | `internal/bluetoothmgmt` owns the bounded Linux management-socket client used by the private hand-off lifecycle and tests its fixed protocol directly |

## Consequences

- A released companion binary can perform maintained workflows without carrying the repository's legacy script directory.
- Retired workarounds disappear from the supported path instead of becoming permanent CLI flags.
- Future image adapters reuse media, bundle, userspace, hand-off, and journalling contracts without inheriting Ubuntu Casper behaviour.
- Destructive writes and installed-system changes become previewable, identity-bound, revalidated, and evidenced.
- Windows-derived values have an auditable interchange format and a private import boundary.
- Maintainer publication remains possible without conflating local artefact preparation with authority to change a remote release.
- The legacy script directory, its obsolete test workflow, and its associated
  root-level shell tests and tools no longer form a second supported API.
- Structural and simulated checks cannot replace cold-boot, suspend, pen, wireless, Bluetooth, camera, audio, installation, or removable-media tests on actual Surface hardware, so those gates remain explicit.
