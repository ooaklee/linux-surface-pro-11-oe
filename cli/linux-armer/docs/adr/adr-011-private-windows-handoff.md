---
id: adrs-adr011
title: "ADR011: Private device-bound Windows hand-off"
description: Architecture decision for collecting, importing, retaining, and later applying restricted same-device Windows evidence.
---

## Status

Superseded on 2026-08-30 by ADR021.

## Context

The Surface Pro 11 needs a bounded set of platform firmware that an authorised operator may obtain from the device's Windows installation. Bluetooth also needs the public controller address for the same physical adapter. These values are not ordinary redistributable userspace artefacts: firmware bytes may be proprietary, a Bluetooth address is a persistent hardware identifier, and raw Windows hardware identifiers would make collections linkable.

Copying files directly from a mounted Windows root leaves selection, provenance, completeness, and destination policy inside a privileged Linux installer. Passing a Bluetooth address on a command line exposes it to shell history and process inspection. Treating either payload as an ISO companion would turn private, device-bound material into distributable image content.

Windows and Linux cannot share one executable collector, but they can share one strict, versioned data contract. Linux must treat Windows signature results as claimed collection evidence rather than pretending it independently verified Authenticode.

## Decision

The `handoff` domain will own a v1 private interchange contract whose canonical document is `linux-armer-windows-handoff.json`. The envelope fixes its schema version, kind, privacy classification, canonical UTC collection time, collector identity, Surface Pro 11 platform, ARM64 architecture, and audited Wi-Fi PCI identifier. Unknown, duplicated, missing, `null`, mis-cased, malformed, oversized, byte-order-marked, or trailing JSON input will be rejected.

Each collection will generate a fresh cryptographically random 32-byte salt. The collector will export neither the SMBIOS product UUID nor the selected Bluetooth adapter instance identifier. It will instead record domain-separated SHA-256 bindings over the raw salt and each canonical identifier. Reusing neither a bare hardware digest nor a salt prevents separate collections from becoming trivially linkable while allowing a future same-device apply transaction to re-derive the expected binding.

Platform firmware is a strict union: either all eleven compiled Surface Pro 11 source, payload, and Linux destination mappings are present in canonical order, or the section records one allowed absence reason. Every included file records its exact size and SHA-256 together with bounded active DriverStore provenance and a Windows-side valid-catalogue claim. Linux validates the claim's shape and the copied bytes but does not call that an independent signature verification. Windows Wi-Fi firmware is excluded; Linux WCN7850 board data remains owned by the distribution firmware package.

Bluetooth evidence is also a strict union. An included section contains a canonical unicast public address, one compiled provenance type, and the salted adapter-instance binding. The address type redacts ordinary string and diagnostic formatting. Public import, list, and purge results expose only booleans, counts, collection time, platform, and content address; they never expose the address, raw identifiers, salts, or bindings.

`handoff import` will accept only a closed source directory containing the exact manifest and declared payload paths. It will reject extra paths, case collisions, alternate separators, symbolic links, special files, missing entries, byte mismatches, and mutation during verification or copying. Publication uses a private same-filesystem staging directory, mode `0700` directories, mode `0600` files, exact manifest-byte content addressing, no-replace rename, directory synchronisation, and complete post-publication revalidation. Identical concurrent imports converge on one validated entry; a conflicting or corrupt existing entry blocks import.

`handoff list` will revalidate every direct store child before returning redacted summaries. `handoff purge` will first return a plan bound to the current closed set, require the exact phrase `purge <content-address>`, revalidate the plan, atomically isolate that direct child, validate it again, and remove only its verified files and directories. It will never accept a blanket `yes`, an arbitrary path, or recursive deletion of unchecked content.

Import and retention do not authorise application. ADR013 subsequently defined the same-device application, exact transaction planning, byte-exact backup, and rollback-capable receipt contract that this decision left as future work.

Collected documents and payloads will never be included in an ISO, release, issue, or diagnostic bundle. The collector source itself may be a manifest-tracked companion file because it contains policy and code rather than collected device data.

## Consequences

- Windows collection and Linux consumption share one typed, hostile-input-tested contract without sharing an operating-system-specific executable.
- Firmware selection and destination authority move out of privileged ad hoc scripts and into a fixed reviewable policy.
- Ordinary command output remains useful without disclosing reusable hardware identity.
- Import, audit, and retention can ship before system mutation because those authorities remain deliberately separate.
- An operator must keep the private store backed up or retain an authorised Windows source; content addressing does not make restricted payloads redistributable.
- At the time of this decision, same-device application, firmware rollback, Bluetooth rollback, and hardware validation remained explicit future gates. ADR013 subsequently completed the transaction and rollback design.
