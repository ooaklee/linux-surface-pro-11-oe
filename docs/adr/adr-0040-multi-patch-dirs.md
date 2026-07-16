---
id: adr-0040-multi-patch-dirs
title: "ADR0040: Multiple Patch Directories for Kernel Build Scripts"
# prettier-ignore
description: Architecture Decision Record (ADR) for introducing --patch-dirs to support applying kernel patches from multiple directories in a single build invocation.
---

# ADR0040: Multiple Patch Directories for Kernel Build Scripts

## Status

Accepted (2026-07-16).

## Context

The kernel build scripts (`build-sp11-qcom-x1e-kernel.sh` and its Docker
wrapper `build-sp11-qcom-x1e-kernel-docker.sh`) accepted exactly one patch
directory via `--patch-dir`. This was sufficient whilst the only patches
needed were the two Wi-Fi `disable-rfkill` patches in
`patches/ubuntu-qcom-x1e-7.0/`.

Two developments changed this:

1. **Johan G.'s independent qcom-x1e tree** carries the rfkill and Denali
   DTB patches upstream but requires its own build-compatibility patches
   (config annotations, stubble paths) in `patches/jglathe-qcom-x1e-7.1.3/`.

2. **Surface Pro 11 touchscreen enablement** adds 14 new kernel driver
   patches (GPI DMA QSPI, GENI SPI QSPI, HID-over-SPI transport driver,
   Denali DTS modifications) in `patches/sp11-touchscreen/`. These must be
   applied alongside the build-compatibility patches on the JG tree.

Without multi-directory support, users would need to manually merge patch
sets into a temporary combined directory and renumber the files each time,
which is error-prone and incompatible with automated CI pipelines.

## Decision

Introduce a `--patch-dirs` option that accepts a space-separated list of
patch directory paths. Patches from each directory are applied in the order
the directories are listed.

The existing `--patch-dir` remains available for single-directory use. If
both options are passed, `--patch-dirs` takes precedence.

The inner build script (`build-sp11-qcom-x1e-kernel.sh`) iterates over
each directory with the existing `git apply --check` + `git apply` logic.
The `apply_patches` function was refactored to iterate a list of
directories rather than a single path.

The Docker wrapper (`build-sp11-qcom-x1e-kernel-docker.sh`) validates
that every directory exists and passes the space-separated list through to
the inner script as a single `--patch-dirs "path1 path2 ..."` argument.

## Alternatives Considered

**Merge directories manually (rejected).** Creating a temporary combined
directory with renumbered patches works but adds manual steps before every
build, breaks provenance tracking, and complicates CI automation.

**Inside patch subdirectories (rejected).** Splitting `patches/` into
subdirectories like `patches/jglathe-7.1.3/drivers/` and
`patches/jglathe-7.1.3/debian/` still requires merging before the single
`--patch-dir` argument, so it does not solve the problem.

**Multiple `--patch-dir` flags (considered).** Accumulating directories
through repeated `--patch-dir` flags (e.g.
`--patch-dir A --patch-dir B`) is idiomatic in some CLI tools but more
complex for script argument parsing and the Docker wrapper's path
translation. A single space-separated `--patch-dirs` argument is simpler
to implement and understand.

## Consequences

- Users building the JG 7.1.3 tree with touchscreen support use:
  `--patch-dirs "patches/sp11-touchscreen patches/jglathe-qcom-x1e-7.1.3"`
  instead of merging patch sets manually.

- The `apply_patches` function's inside-patch directory loop preserves the
  existing per-patch safety checks (`--reverse`-already-applied detection,
  Wi-Fi patch content grep for pre-satisfied patches).

- The info/listing section of the inner build script displays patches
  grouped by directory when `--patch-dirs` is active.

- `--patch-dir` continues to work unchanged for all existing single-set
  workflows (Ubuntu concept `qcom-x1e-7.0`, JG trees without touchscreen).
