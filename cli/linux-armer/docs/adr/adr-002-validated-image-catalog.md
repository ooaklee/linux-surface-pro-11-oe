---
id: adrs-adr002
title: "ADR002: Strict, human-readable installation-media catalogue"
description: Architecture decision for curated image metadata and adapter support declarations.
---

## Status

Accepted on 2026-08-30.

## Context

Users need a clear list of ARM64 installation media, upstream download locations, and project support status. Upstream naming conventions vary, some URLs are mutable, and ISO files require different transformations from compressed raw disk images. Treating every listed artefact as buildable would create unsafe expectations.

The catalogue should be easy to review and update without compiling Go code, while malformed metadata must fail early and report all actionable errors in one pass.

## Decision

The built-in catalogue will use the versioned `supported-isos.json` document. Each entry will declare a stable kebab-case ID, display metadata, exact upstream filename, architecture, artefact kind, HTTPS artefact and homepage URLs, adapter, support level, experimental and mutable flags, compatibility notes, and verification date. The filename must be a portable basename, must match the final artefact URL path segment exactly, and must have the extension required by the artefact kind. Publisher checksums are optional and, when present, must identify SHA-256 or SHA-512 explicitly.

A dedicated catalogue package will decode JSON with unknown-field rejection, normalise `aarch64` and `arm64` to the canonical `arm64` value, aggregate semantic validation failures, and expose defensive sorted views. Adapter and support declarations must agree: `catalog-only` entries use `adapter: none`; implemented entries name an available adapter.

Initially, only `ubuntu-concept-resolute-x1e` is implemented through the `ubuntu-casper` adapter. Other entries remain visible as `catalog-only` media until purpose-built adapters can create and validate them.

## Consequences

- Maintainers can review catalogue changes as readable data diffs.
- Unknown fields, filename disagreements, and inconsistent support claims fail before an image build starts.
- Mutable URLs can be disclosed clearly and paired with user-supplied checksums.
- Adding a catalogue entry does not imply that `image create` supports its media layout.
- Schema changes require an explicit version update and loader changes.
