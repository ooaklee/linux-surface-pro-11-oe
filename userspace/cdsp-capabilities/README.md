# CDSP advertised-capability source (experimental)

This standalone Linux-UAPI utility can collect firmware-advertised unsigned-PD
and architecture attributes without loading the SDK-linked compute worker.
It is **source-only, not a qualified device diagnostic or an installable Lexr
component**. A successful query would report advertisements, not permission to
deploy a DSP program.

## Contents and provenance

[`source/`](source/) is the unchanged R88-r2 kit: 15 regular files, including
the complete manifest and checksum list. It contains C sources, the public
Linux FastRPC UAPI, a Makefile, guarded offline tests, instructions and licence
texts. No Windows executable, proprietary SDK, firmware, factory data or
compiled payload is included.

The source manifest SHA-256 is:

```text
3c796c771b127a45cbd5302de99541f4f3acb4bbdd463126bd3c9e7081a47e81
```

Authored sources retain BSD-3-Clause and the copyright attribution to
**SP11 native compute contributors**. The public UAPI retains GPL-2.0 WITH
Linux-syscall-note; all three licence texts remain under `source/LICENSES/`.
Public attribute declarations are pinned to
[FastRPC a56e9d4](https://github.com/qualcomm/fastrpc/tree/a56e9d4de3614a8d8f4b0e15ff561350c4b686e3).
`UNSIGNED_PD_SUPPORT=1` and `ARCH_VER=6` are **attribute identifiers**, not
observed capability values.

## Building and safety boundary

Read the complete [`source/README.txt`](source/README.txt). Build as an ordinary
nonroot user on native Linux ARM64 with a C11 compiler, make, libc and public
Linux headers. Optional `make check` executes software and requires an isolated
environment with no FastRPC device nodes exposed; its guard refuses named
nodes. No package installer, service activation or permission change is supplied.

**A real query is active.** Opening a FastRPC node reserves a session;
`GET_DSP_INFO` on a cache miss and closing the session can send kernel-internal
firmware control RPCs. Do not run the README's live query command without a
separately agreed test window and independently verified device/channel
identity. A basename and character-device check alone do not identify physical
CDSP. The utility does not create a user PD or load a custom DSP program, but
that does not make it a passive file inventory.

Cache freshness and firmware epoch remain unknown. Successful close does not
prove firmware acknowledgement. No whole-command timeout or DSP-quiescence
guarantee is claimed; the full README explains raw returns, error handling and
the absence of automatic retry, alternate-device or signed-PD fallback.

## Validation status

The exact kit completed a native ARM64 offline build on 19 October 2026:
10 recorded commands, 15 wrapped-syscall cases and 11 CLI cases. The saved
output was an AArch64 PIE with the standard loader and libc-only closure;
compiler and command stderr were empty. A separate OpenCode review covered
that finite software scope. These fixtures used wrapped operations or
help/rejected/absent-node paths and the standard output-failure sink.
**No physical CDSP node was opened or queried in that validation.**

Publication rechecks the exact source bytes, modes and manifest closure; it
does not claim another build or a live capability observation. Physical ISA,
unsigned-PD support, cache age, firmware release acknowledgement, real
transport and compute-worker deployment remain unqualified.

## Lexr status and related work

There is no Lexr CDSP installation adapter or tested runtime compatibility
contract yet. This directory intentionally has **no `lexr.yaml`**, automatic
install registration, service, or compatibility range. An eventual integration
must preserve explicit live-query consent and the distinction between returned
attributes and deployment qualification.

See the separate [native compute source](../native-compute/) and
[Lexr's sensor build workflow](https://github.com/ooaklee/lexr.sh/pull/76).
Neither is a runtime compatibility guarantee for this utility.
