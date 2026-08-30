---
id: adrs-adr002
title: "ADR002: Strict, human-readable installation-media catalog"
description: Architecture decision for curated image metadata and adapter support declarations.
---

## Status

Accepted on 2026-08-30.

## Context

Users need a clear list of ARM64 installation media, upstream download locations, and project support status. Upstream naming conventions vary, some URLs are mutable, and ISO files require different transformations from compressed raw disk images. Treating every listed artifact as buildable would create unsafe expectations.

The catalog should be easy to review and update without compiling Go code, while malformed metadata must fail early and report all actionable errors in one pass.

## Decision

The built-in catalog will use the versioned `supported-isos.json` document. Each entry will declare a stable kebab-case ID, display metadata, architecture, artifact kind, HTTPS artifact and homepage URLs, adapter, support level, experimental and mutable flags, compatibility notes, and verification date. Publisher checksums are optional and, when present, must identify SHA-256 or SHA-512 explicitly.

A dedicated catalog package will decode JSON with unknown-field rejection, normalize `aarch64` and `arm64` to the canonical `arm64` value, aggregate semantic validation failures, and expose defensive sorted views. Adapter and support declarations must agree: catalog-only entries use `adapter: none`; implemented entries name an available adapter.

Initially, only `ubuntu-concept-resolute-x1e` is implemented through the `ubuntu-casper` adapter. Other entries remain visible as catalog-only media until purpose-built adapters can create and validate them.

## Consequences

- Maintainers can review catalog changes as readable data diffs.
- Unknown fields and inconsistent support claims fail before an image build starts.
- Mutable URLs can be disclosed clearly and paired with user-supplied checksums.
- Adding a catalog entry does not imply that `image create` supports its media layout.
- Schema changes require an explicit version update and loader changes.
