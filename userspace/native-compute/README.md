# Native compute source kit (experimental)

This is a buildable source foundation for a bounded sum/max interface over
Linux FastRPC. It is **not an installable userspace component, a qualified DSP
runtime, or an NPU/HTP backend**. No kernel, firmware, service or desktop
configuration is installed by this publication.

## Contents and provenance

[`source/`](source/) is the unchanged R86-r2 source kit: 255 regular files,
including its complete manifest and checksum list. It includes the authored
IDL, checked host API, libc-only intent launcher, SDK-linked worker, DSP
implementation, offline fixtures and build scripts. Public upstream snapshots
are pinned to:

- [Qualcomm QAIC](https://github.com/qualcomm/QAIC/tree/a66a0019fb488abae955bbc9b3a9de3dc15962d0).
- [Qualcomm FastRPC](https://github.com/qualcomm/fastrpc/tree/a56e9d4de3614a8d8f4b0e15ff561350c4b686e3).

The supplied FastRPC patch is applied only to a fresh build copy; the upstream
snapshots remain unchanged. No Windows executable, proprietary SDK binary,
firmware, factory data, prebuilt library or container layer is included.

The source manifest SHA-256 is:

```text
0d35d975b92f85b73374e2491719e784c112e9387af4e4ad0531d2dd58e95979
```

Read [`source/NOTICE.txt`](source/NOTICE.txt),
[`source/LICENSE-INVENTORY.json`](source/LICENSE-INVENTORY.json) and each
component's notices. Authored sources retain the BSD-3-Clause copyright
attribution to **SP11 native compute contributors**. QAIC and FastRPC retain
their original BSD/Clear and embedded third-party notices. The public Linux
UAPI retains GPL-2.0 WITH Linux-syscall-note. Importing this collection does not
relicense its components or supply a proprietary runtime or patent grant.

## Building and safety boundary

Read the complete [`source/README.txt`](source/README.txt) before building. Its
recipe requires a separately provisioned native Linux ARM64 environment and
ordinary nonroot execution. Keep the source read-only and use a fresh output
directory. Dependency-image provisioning is a separate, networked operation.
Building executes offline fixtures; it is not just source inspection.

**Do not execute the genuine `compute-rpc-worker`, even for `--help`.** Its
linked FastRPC library can open resources in constructors before `main`.
`compute-client --run-cdsp --expect-arch ...` is also an active device operation,
not a passive diagnostic. The offline launcher checks use an explicit local
mock worker, never the genuine SDK-linked worker. Do not copy or load generated
artifacts onto a device on the strength of these checks.

Applications must use the supplied checked sum/max API. Calling the generated
raw API directly bypasses count and pointer admission. The full source README
documents the supported argument, output, storage and error contracts.

## Validation status

The exact kit completed a native ARM64 offline build on 19 October 2026:
45 recorded commands, 27 launcher cases, 23 client-control scenarios,
266 checked-API assertions, 60 pure implementation checks, and 32 generated
AP-wire cases with 708 assertions. A separate OpenCode review covered that
finite software scope. The genuine worker was **linked, never executed**;
the Hexagon v73 DSO was analysis-only, not a proven QuRT deployment.

The saved build retained 224 inherited QAIC warnings and one aclocal advisory;
it was not globally warning-free. The kit's historical composition-time README
predates this later acceptance and is deliberately preserved unchanged.
Publication rechecks source bytes, modes and manifest closure; it does not
claim another build or a hardware test.

Actual device ISA, unsigned-PD support, firmware/shell/loader compatibility,
physical transport, real DSP arithmetic and NPU/HTP execution remain
unqualified. This is not full Surface feature parity.

## Lexr status and related work

There is no Lexr compute installation adapter or tested runtime compatibility
contract yet. Accordingly this directory has **no `lexr.yaml`**, is not added to
an automatic install catalogue, and must not be installed with the sensor
workflow by renaming it. Future support needs a separately reviewed producer,
consumer, dependency and hardware-qualification contract.

See the separate [CDSP capability source](../cdsp-capabilities/), the
[native sensor source work](https://github.com/ooaklee/linux-surface-pro-11-oe/pull/72)
and [Lexr's sensor build workflow](https://github.com/ooaklee/lexr.sh/pull/76).
Those components have distinct contracts; none establishes compute runtime
compatibility for the others.
