---
id: adrs-adr001
title: "ADR001: Feature-oriented CLI with shared orchestration"
description: Architecture decision for keeping delivery layers separate from feature behaviour.
---

## Status

Accepted on 2026-08-30.

## Context

`linux-armer` must support interactive guidance and predictable terminal automation without maintaining two implementations of image-building behaviour. The workflow spans downloads, kernel releases, device trees, image layouts, host checks, and clean-up. These concerns evolve at different rates and require focused tests.

Image creation is long-running and produces large artefacts. Users need to see what will happen before execution and need durable evidence of completed steps and output digests. Other workflows have different evidence needs: a userspace pull produces a verified bundle manifest, a doctor run produces a point-in-time report, and clean-up produces a reviewed plan and recovery receipt.

## Decision

The executable and Cobra commands will remain thin delivery layers. Bubble Tea models will own only interaction state and presentation. Domain behaviour will live in feature-oriented packages for catalogue, kernel, image, doctor, and clean-up concerns. Platform process and container execution will sit behind narrow interfaces.

Managers may compose simpler feature services. Both command and wizard entry points will submit the same typed request to the same manager.

Image creation will create a deterministic operation plan with stable step identifiers. Mutable completion records, observed digests, and published outputs will be stored separately in an execution journal. Image planning must not mutate host or network state.

Other workflows will use the narrow evidence type that matches their trust boundary rather than being forced through the image plan abstraction. These records include verified kernel and userspace bundle manifests, dry-run installation operations, static doctor reports, and immutable clean-up plans plus recovery receipts.

## Consequences

- Interactive and non-interactive flows cannot silently diverge in behaviour.
- Feature packages can be tested without Cobra or Bubble Tea dependencies.
- Image plans are suitable for dry runs, review, and future resume support.
- Image journals provide useful troubleshooting and provenance without changing the original plan.
- Feature-specific records remain smaller and more truthful than a generic plan that does not fit their operation.
- More domain types and explicit orchestration code are required than in a single command package.
