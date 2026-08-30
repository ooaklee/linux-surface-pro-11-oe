---
id: adrs-adr001
title: "ADR001: Feature-oriented CLI with shared operation plans"
description: Architecture decision for keeping delivery layers separate from feature behavior.
---

## Status

Accepted on 2026-08-30.

## Context

`linux-armer` must support interactive guidance and predictable terminal automation without maintaining two implementations of image-building behavior. The workflow spans downloads, kernel releases, device trees, image layouts, host checks, and cleanup. These concerns evolve at different rates and require focused tests.

The operations are long-running and produce large artifacts. Users need to see what will happen before execution and need durable evidence of completed steps and output digests.

## Decision

The executable and Cobra commands will remain thin delivery layers. Bubble Tea models will own only interaction state and presentation. Domain behavior will live in feature-oriented packages for catalog, kernel, image, doctor, and cleanup concerns. Platform process and container execution will sit behind narrow interfaces.

Managers may compose simpler feature services. Both command and wizard entry points will submit the same typed request to the same manager.

Every material workflow will create a deterministic operation plan with stable step identifiers. Mutable completion records, observed digests, and published outputs will be stored separately in an execution journal. Planning must not mutate host or network state.

## Consequences

- Interactive and non-interactive flows cannot silently diverge in behavior.
- Feature packages can be tested without Cobra or Bubble Tea dependencies.
- Plans are suitable for dry runs, review, and future resume support.
- Journals provide useful troubleshooting and provenance without changing the original plan.
- More domain types and explicit orchestration code are required than in a single command package.
