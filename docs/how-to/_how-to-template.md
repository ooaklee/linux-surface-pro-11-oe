---
id: how-to-[slug]
title: "[TITLE]"
# prettier-ignore
description: How-to guide for [TASK] [DESCRIPTION]
---

# How To: [TITLE]

Last reviewed: YYYY-MM-DD

Use this procedure to [state the operator outcome].

## Before you begin

- State the supported device, operating system and required access.
- Name the exact `linux-armer` capability and its support grade.
- Keep a known-good boot or recovery path when changing a system.

## Inspect the current state

Run read-only diagnostics first:

```sh
linux-armer <read-only-command>
```

Use `--dry-run` for a mutating command only when that command's help advertises
it; not every workflow has a preview mode.

Record the command version, selected kernel ABI and any redacted report needed
to reproduce the result. Never include credentials, device-bound material or
private paths in a public report.

## Apply the change

Show the smallest native CLI command that performs the task. Explain every
placeholder and confirmation gate. Do not prescribe repository scripts or
unbounded manual filesystem changes.

## Verify the result

Use a native validation or doctor command and list the observable acceptance
criteria. Distinguish a static pass from physical hardware qualification.

## Recover

Describe the durable receipt, retained fallback or other exact reversal path.
Do not describe deletion by path guessing.

## Related guidance

- Link only current operator guidance.
- Treat dated reports and superseded decisions as historical evidence.
