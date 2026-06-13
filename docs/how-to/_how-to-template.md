---
id: how-to-[slug]
title: "[TITLE]"
# prettier-ignore
description: How-to guide for [TASK] [DESCRIPTION]
---

# How To: [TITLE]

Use this procedure to [briefly describe the task and outcome].

## Purpose

Explain why this procedure exists, when to use it, and what problem it solves.
Keep this section focused on user intent rather than implementation detail.

## Prerequisites

- [Required device, operating system, package, script, or account access.]
- [Required permissions, such as Administrator or root, if applicable.]
- [Required input files or artifacts.]

Note any optional privileges or tools that improve report quality, speed, or
debuggability.

## Procedure

1. [First action.]

2. [Second action.]

3. [Run the main command or perform the main operation.]

```bash
[example-command --with-placeholder]
```

4. [Wait for completion, if the command can take a while.]

5. [Confirm the expected final output.]

```text
[expected success message or output shape]
```

## Expected Output

Describe the files, directories, device state, logs, reports, or other outputs
that should exist after the procedure completes.

- [Expected output item.]
- [Expected output item.]
- [Expected output item.]

## Validation

List checks that prove the procedure completed successfully.

```bash
[validation-command]
```

Passing validation means [state exactly what the check proves]. It does not
prove [state important limits, such as hardware behavior that still needs real
device testing].

## Privacy and Safety

Call out destructive steps, sensitive data, proprietary files, credentials,
local paths, or other artifacts that should not be committed.

Before committing documentation or derived summaries, check that:

- no raw diagnostic archives or generated dump files were added,
- no local workstation paths are included,
- no personal account names, network addresses, tokens, or secrets are present,
- no proprietary firmware blobs or large generated images are copied into git.

## Troubleshooting

If [common failure] happens, [recommended recovery].

If [permission-related failure] happens, rerun with [required permission].

If the process appears to hang, wait for [known slow step] before interrupting.

## Related Documents

- [Related guide or report](../path/to-related-document.md)
- [Related ADR](../adr/adr-XXXX-example.md)
