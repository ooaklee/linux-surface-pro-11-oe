---
id: how-to-compile-sp11-bt-set-addr
title: "Migrate Legacy Bluetooth Address Configuration"
# prettier-ignore
description: Replace legacy Bluetooth address tooling with Lexr.sh's private same-device hand-off workflow.
---

# How To: Migrate Legacy Bluetooth Address Configuration

Last reviewed: 2026-08-31

The old standalone Bluetooth address implementation is retired. Do not compile
or install it. `lexr handoff apply` now owns the validated same-device
address workflow and creates the required system integration itself.

Before collecting, [initialise the Lexr submodule](../../README.md#build-the-cli)
so that the canonical Windows collector is present. This requires an
authenticated checkout while Lexr remains private; once it is public, ordinary
anonymous submodule initialisation is sufficient.

## Migrate

1. Collect the Bluetooth component on Windows with
   `cli/lexr/tools/collect-sp11-windows-handoff.ps1`.
2. Import it on the same Surface into one explicit absolute user store:

   ```sh
   HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
   lexr handoff import /path/to/sp11-handoff --store "$HANDOFF_STORE"
   lexr handoff list --store "$HANDOFF_STORE"
   ```

   The unprivileged shell expands `$HOME` before any later `sudo` command.
3. Preview the application:

   ```sh
   lexr handoff apply <id> \
     --store "$HANDOFF_STORE" \
     --target-root / \
     --feature bluetooth \
     --dry-run

   sudo lexr handoff apply <id> \
     --store "$HANDOFF_STORE" \
     --target-root / \
     --feature bluetooth \
     --confirm '<exact phrase from the current dry run>'
   ```

4. Verify with `lexr doctor userspace --feature bluetooth` and
   `lexr doctor hardware bluetooth`.

The hand-off is private, proprietary and device-bound. It must not be
published or included in an image or release. See
[Bring Up Bluetooth](how-to-bring-up-bluetooth.md) for the full collection,
recovery and retention procedure.
