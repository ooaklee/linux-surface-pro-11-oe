---
id: adr-0069-standalone-lexr-workflow-ownership
title: "ADR0069: Standalone Lexr and OE Workflow Ownership"
# prettier-ignore
description: Architecture Decision Record (ADR) for keeping the Lexr command-line application independent while retaining Surface Pro 11 hardware integration and release continuity in OE.
---

# ADR0069: Standalone Lexr and OE Workflow Ownership

## Status

Accepted on 2026-08-31.

ADR0068 is reserved by the USB4 integration work developed independently of
this decision.

## Context

The Surface Pro 11 support repository originally developed its image,
kernel, userspace, recovery and diagnostic orchestration under
an embedded CLI tree. That application now has an independent project identity,
release lifecycle and issue tracker as [Lexr](https://github.com/ooaklee/lexr.sh).

Keeping a second source copy in OE would split issue ownership and allow the
two implementations to drift. Running Lexr-dependent automation from OE would
also require OE to obtain a private cross-repository checkout credential while
Lexr remains access-controlled. That reverses the intended ownership boundary.

OE nevertheless remains the public authority for Surface Pro 11 integration
evidence, kernel and device-support artefacts, historical decisions, patches,
recipes and compatibility release links. Moving the CLI must not move or break
those established release channels.

## Decision

- Lexr owns its Go source, catalogues, tests, documentation, issue tracker,
  binary releases and Lexr-dependent automation.
- OE links the independently versioned project at `cli/lexr` as an HTTPS Git
  submodule. The recorded gitlink is an auditable source identity; updating it
  requires the same review as any other OE dependency change.
- Lexr releases contain Lexr executables and their checksum manifest only.
  Kernel, IPTSD, audio, camera and other Surface Pro 11 support artefacts
  continue to be published through the established OE release page.
- Kernel and IPTSD build/publication automation runs from Lexr. A dedicated,
  repository-scoped credential permits only the required cross-repository OE
  release operation, and publication remains bound to an exact OE `main`
  revision.
- OE does not run a workflow which checks out private Lexr source. The
  superseded kernel-build, IPTSD-integration and script-test workflows are
  removed from OE.
- The completed native-workflow audit assigns every former repository script,
  shell test and root helper tool to a typed Lexr owner, explicit retirement or
  specialist rehoming. OE therefore removes that second execution surface as
  recorded by [ADR0070](adr-0070-retire-superseded-repository-scripts.md).
  Historical reports retain their original commands beneath explicit
  non-prescriptive notices.
- Existing OE repository and release URLs remain stable external provenance.
  Lexr-owned pre-release media, private hand-off, installed-state and bundle
  identifiers advance to explicit Lexr-only contracts rather than carrying a
  second product identity into the standalone repository.

The initial gitlink pins Lexr commit
`8fa487fe616f5324d3215274780daafe6b5f9118`. That revision completed the
Lexr-only naming boundary and passed the standalone Linux quality, OE IPTSD
integration, Windows PowerShell collector and Pester contract jobs before the
OE cut-over advanced to it.

## Consequences

- A recursive OE clone gives authorised contributors the exact reviewed Lexr
  source; cloning without submodules still provides the complete OE evidence
  and integration repository.
- Contributors without access to Lexr cannot initialise the submodule during
  the access-controlled phase. This restriction disappears if the standalone
  repository becomes public; no OE history or URL change is then required.
- OE pull requests do not need a Lexr repository token, and untrusted pull
  request code cannot receive the credential used for OE release publication.
- The two repositories have clear release boundaries while users retain the
  existing OE links for kernels and device-support payloads.
- Current operator guidance has one implementation boundary: the pinned Lexr
  binary and its typed domains. Patch inputs, dated evidence, userspace source
  and OpenEmbedded recipes remain in OE without retaining a second runnable
  orchestration surface.

## Alternatives Considered

**Keep a copied CLI in OE (rejected).** This would create two authoritative
source trees and make fixes, release notes and security review easy to miss.

**Run all workflows from OE with a private Lexr checkout token (rejected).**
This would assign automation ownership to the repository which does not own
the executable source and would expose an unnecessary credential boundary.

**Move hardware-support releases to Lexr (rejected).** Existing OE release
links are already shared, and Lexr's own releases should remain a predictable
binary-only distribution surface.

**Delete scripts before completing the native-workflow audit (rejected).** A
bulk deletion without replacement mapping would hide recovery gaps. Deletion
became acceptable only after the pinned Lexr revision recorded every native,
retired or rehomed outcome and current OE guidance stopped depending on the
files.
