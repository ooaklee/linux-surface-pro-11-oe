---
id: adrs-adr006
title: "ADR006: Audited userspace companion with compiled capability boundaries"
description: Architecture decision for diagnosing and managing Surface Pro 11 userspace support safely.
---

## Status

Accepted on 2026-08-30.

## Context

A custom kernel is only one part of a usable Surface Pro 11 system. Platform firmware, audio topology and UCM data, pen processing, camera packages, wireless integration, Bluetooth initialisation, power-profile support, and retired workarounds can each affect the installed experience.

These components have different maturity, provenance, and redistribution constraints. Some are already integrated in the kernel or distribution, some have exact project releases, and restricted firmware must come from an authorised source. Converting historical shell scripts into one generic command runner would preserve obsolete workarounds and allow editable data to become executable behaviour.

Users need one companion command that can explain what is missing after a kernel installation while keeping observation, downloads, builds, privileged installs, and legacy clean-up as distinct trust boundaries.

## Decision

The CLI will maintain a versioned, human-readable `supported-userspace.json` catalogue. Each component will declare a stable identifier, support level, capability, redistribution policy, available action flags, compatibility evidence, notes, remediation, and an exact release asset allow-list where applicable. A dedicated package will reject unknown fields, invalid values, inconsistent actions, duplicate identifiers, malformed release metadata, and insecure URLs.

Catalogue action flags are declarative capabilities. They are not commands, writable paths, or permission grants. Pull, build, and install implementations will remain compiled, component-specific adapters with explicit selectors and bounded arguments.

`userspace status` and `doctor userspace` will use the same static inspector. It may inspect files, symbolic links, package metadata, kernel ABIs, GRUB arguments, and ELF metadata below an explicitly selected target root, but it will not execute target binaries, start services, contact the network, access live devices, or mutate the system. Reports will distinguish passed, warning, failed, and skipped checks and will carry the catalogue component identifier and maturity level that determine readiness.

The default report will fail only when catalogue-required support is missing. An explicitly selected supported or experimental feature will also fail on its own unmet checks so automation can ask a narrow question. Diagnostic-only and obsolete checks will never become system requirements. Kernel compatibility will use explicit minimum and tested-through Surface integration generations compiled into policy and cross-checked against catalogue metadata. Audio diagnosis will require the validated FullIO boot argument. IPTSD diagnosis will statically inspect AArch64 ELF loaders and dependencies without invoking `ldd` or any target executable.

An alternate target root is a point-in-time inspection boundary, not a hostile-filesystem sandbox. Operators must keep mounted alternate roots trusted and quiescent while a report is produced.

`userspace pull` will require the remote release to contain exactly the catalogue's allow-listed assets. The checksum manifest must match its hosting-service digest, and every installable payload must have matching hosting-service and publisher `SHA256SUMS` digests before an atomic cache entry and bundle manifest are published.

`userspace build` will expose only maintained workflows for the pinned `iptsd` integration and the experimental camera packages. It will pass validated options to those workflows rather than evaluating catalogue text or arbitrary command fragments.

Kernel and userspace source builds will require a complete OE checkout because their reviewed Docker and package helpers remain repository resources. Standalone release archives will support image creation, downloads, verification, diagnosis, and published-bundle installation without claiming to contain those source-build helpers.

`userspace install` will verify the selected bundle again before any mutation. Dry runs will remain available without privilege. A real install will require effective root privileges and explicit `--yes` confirmation; the CLI will not elevate itself. Component adapters will own their fixed destinations, target-root constraints, backup behaviour, and transaction boundaries.

The pinned `iptsd` archive is a reviewed root-execution boundary: its exact archive digest covers the installer, payload validator, integration templates, binaries, sources, and licences. The adapter will securely extract that archive, constrain its target root, and execute only the contained installer; that installer runs the contained payload validator before its first write. Any accepted archive-digest change therefore requires the same review as a code change, including comparison with the adapter's compiled writable-target preflight.

The experimental camera adapter will pass only the five pinned local packages to one `apt-get` transaction and disable recommended packages. Required dependencies may still be resolved from repositories configured by the target operating system, so they remain part of the target distribution's trust boundary rather than the verified camera bundle.

The `recommended` selector will include only the supported audio release and pinned `iptsd` integration. The experimental camera package set will require an explicit selection. Restricted platform firmware will remain status-only and will never be downloaded or installed by the CLI.

Legacy clean-up will remain a separate, reversible command group. A userspace status, pull, build, or install operation will never remove an old workaround implicitly.

## Consequences

- Users get one consistent diagnosis after installing or upgrading a Surface kernel without requiring privileged or network access for the read-only check.
- Human-readable catalogue changes remain reviewable but cannot introduce executable commands or new write locations.
- Release drift, partial mirrors, substituted assets, and mixed component generations fail before installation.
- Privileged mutation is narrow, explicit, and preceded by a reproducible dry run.
- The default recommendation favours the supported audio and pen path while keeping experimental camera changes opt-in.
- Restricted firmware requires a separate authorised acquisition process, even when the doctor reports it missing.
- New managed components require both catalogue metadata and a reviewed compiled adapter; adding data alone cannot enable a new action.
