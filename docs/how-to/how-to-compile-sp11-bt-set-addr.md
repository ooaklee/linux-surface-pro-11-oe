---
id: how-to-compile-sp11-bt-set-addr
title: "Migrate Legacy Bluetooth Address Configuration"
# prettier-ignore
description: Replace legacy Bluetooth address tooling with linux-armer's private same-device hand-off workflow.
---

# How To: Migrate Legacy Bluetooth Address Configuration

Last reviewed: 2026-08-30

The old standalone Bluetooth address implementation is retired. Do not compile
or install it. `linux-armer handoff apply` now owns the validated same-device
address workflow and creates the required system integration itself.

## Migrate

1. Collect the Bluetooth component on Windows with
   `cli/linux-armer/tools/collect-sp11-windows-handoff.ps1`.
2. Import it on the same Surface with `linux-armer handoff import`.
3. Preview the application:

   ```sh
   linux-armer handoff apply <id> \
     --target-root / \
     --feature bluetooth \
     --dry-run
   ```

4. Repeat the apply with its exact confirmation.
5. Verify with `linux-armer doctor userspace --feature bluetooth` and
   `linux-armer doctor hardware bluetooth`.

The hand-off is private, proprietary and device-bound. It must not be
published or included in an image or release. See
[Bring Up Bluetooth](how-to-bring-up-bluetooth.md) for the full collection,
recovery and retention procedure.
