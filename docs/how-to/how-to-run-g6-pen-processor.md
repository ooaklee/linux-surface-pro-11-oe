---
id: how-to-run-g6-pen-processor
title: "Migrate from the Legacy G6 Pen Diagnostic"
# prettier-ignore
description: Replace diagnostic-only G6 processing with the maintained IPTSD userspace integration.
---

# How To: Migrate from the Legacy G6 Pen Diagnostic

Last reviewed: 2026-08-30

The G6 processor is diagnostic-only and is not the supported production pen
path. Do not enable it alongside IPTSD because both can compete for the same
device.

Inspect the current state:

```sh
linux-armer userspace show g6-pen
linux-armer doctor userspace --feature g6-pen
linux-armer doctor userspace --feature iptsd
```

If a recognised legacy service is present, use `linux-armer clean scan`, write
and review a `clean plan`, then apply that exact plan. Install the audited
IPTSD release using [Build and Validate Surface Pro 11 Pen
Support](how-to-bring-up-pen.md).

Historical G6 captures and dated reports remain experimental evidence. They do
not justify enabling the diagnostic processor on a normal system.
