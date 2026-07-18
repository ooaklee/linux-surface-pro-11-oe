---
id: adr-0043-jglathe-qcom-7-1-3-jg-1-build-reproducibility
title: "ADR0043: Reproducible JG 7.1.3-jg-1 Kernel Builds"
# prettier-ignore
description: Architecture Decision Record (ADR) for regenerating tag-specific qcom-x1e annotations and reusing Git source checkouts reliably when building Johan G.'s 7.1.3-jg-1 kernel.
---

# ADR0043: Reproducible JG 7.1.3-jg-1 Kernel Builds

## Status

Accepted (2026-07-18).

Validated by a complete `binary-indep binary-qcom-x1e` Docker build and by
installation on a Surface Pro 11, where the resulting
`7.1.3-jg-1-qcom-x1e` kernel boots and works on the device.

## Context

Johan G.'s `jg/ubuntu-qcom-x1e-7.1.3-jg-1` tag requires two local
build-compatibility patches: updated Ubuntu qcom-x1e config annotations and
the packaged Stubble paths described by [ADR-0037](adr-0037-jglathe-qcom-7-1-1-stubble-paths.md).
The previous annotations patch was tied to `7.1.3-jg-0`. Reusing it for
`7.1.3-jg-1` caused Ubuntu's `check-config` step to reject the generated
configuration.

The annotations are partly derived from Kconfig toolchain probes. The
`7.1.3` source recorded rustc 1.88.0 and LLVM 20.1.5, while the verified
`ubuntu:26.04` build environment provides rustc 1.93.1 and LLVM 21.1.8. It
also exposes additional Rust feature probes and supplies the package version
signature. An annotations patch generated with missing dependencies or a
different compiler can therefore disagree with the real package build even
when `olddefconfig` itself completes.

The first regeneration attempt exposed three reproducibility problems:

1. The cross-compiler package was named as `aarch64-linux-gnu-gcc-15`, but
   Ubuntu packages the executable in `gcc-15-aarch64-linux-gnu`. Falling back
   to another compiler can change Kconfig `cc-option` results.
2. `debian/scripts/misc/annotations` was invoked outside the kernel source
   directory without an explicit annotations file. Its implicit lookup could
   not find `debian.qcom-x1e/config/annotations`, so export stopped before
   producing a usable `.config`.
3. Installing only a small hand-selected dependency set did not guarantee the
   same Rust, bindgen, Stubble, and compiler probes as the package build.

Repeated Git builds also spent unnecessary time and network bandwidth on
source preparation. With `--reset-source`, the build helper deleted a valid
checkout and cloned it again. It also queried the remote before checking
whether the requested branch or tag was already present locally. The JG refs
look branch-like but are published as tags, so branch-only handling is not
sufficient.

## Decision

### Add a dedicated annotations regeneration helper

Add `scripts/regenerate-qcom-x1e-annotations.sh` as the supported way to
refresh the tag-specific annotations patch for JG qcom-x1e tags.

The helper will:

- run in an ARM64 `ubuntu:26.04` container using the same case-sensitive
  Docker work volume as the kernel builder;
- install `gcc-15`, `gcc-15-aarch64-linux-gnu`, and the base tools needed to
  generate the source package's build metadata;
- generate `debian/control` when necessary and use `mk-build-deps` to install
  the complete source build-dependency set;
- pass `-f "$src/debian.qcom-x1e/config/annotations"` on both annotations
  export and import, so operation does not depend on the current directory;
- inject the same `CONFIG_VERSION_SIGNATURE` used by the package build;
- run `rustavailable` as a best-effort probe, followed by `olddefconfig`, with
  the package build's GCC 15, Rust, bindgen, kernel release, ABI, and Python
  make arguments;
- reject a missing or empty generated patch before changing the patch
  directory; and
- replace only stale
  `0001-debian-qcom-x1e-update-annotations-for-*.patch` files, leaving other
  compatibility patches untouched.

The output filename includes the full version token, for example:

```text
0001-debian-qcom-x1e-update-annotations-for-7.1.3-jg-1.patch
```

`--reset-source` remains the recommended regeneration mode because it creates
the patch relative to the upstream tag. `--keep-source` is available for
expert use, but only when the existing tree has already had any prior
annotations patch reverted.

### Make Git source preparation reusable and tag-aware

Update `scripts/build-sp11-qcom-x1e-kernel.sh` so Git-mode builds:

- create new checkouts with `git clone --depth 1 --branch`, limiting the
  initial transfer to the requested ref;
- implement `--reset-source` for a valid Git checkout with
  `git reset --hard` and `git clean -ffdx` instead of deleting the checkout;
- continue removing an existing non-Git source directory when reset was
  explicitly requested;
- check local remote-branch and tag refs before falling back to
  `git ls-remote`;
- distinguish branch refs from tag refs, rather than assuming every
  slash-containing JG ref has a corresponding `origin/<ref>` branch; and
- skip a tag fetch when that exact tag already exists locally, then check out
  and reset to it in detached-HEAD state.

Branch builds still fetch their requested branch so they can follow new
commits. Tag builds treat an existing local tag as stable. If an upstream
project moves a published tag, the cached checkout or Docker work volume must
be removed before rebuilding from the replacement tag.

The source build's existing `mk-build-deps` behavior remains the reference for
the regeneration environment; it is not replaced by the new helper.

## Alternatives Considered

**Edit the annotations patch by hand (rejected).** Manually copying the
symbols printed by `check-config` can miss toolchain-dependent values and the
version signature. Exporting, resolving, and importing the full configuration
keeps the annotations internally consistent.

**Use a reduced dependency set (rejected).** A minimal container may make Rust
or bindgen appear unavailable and generate a patch that differs from the real
package build.

**Allow compiler fallback (rejected).** Continuing with an arbitrary host
compiler after the GCC 15 cross-compiler package fails can change Kconfig
probe results. Regeneration must install and use the compiler expected by the
source package.

**Depend on annotations auto-discovery (rejected).** Auto-discovery depends on
the current directory and Debian environment files. Explicit `-f` arguments
are unambiguous and work from the helper's build directory.

**Delete and clone for every reset (rejected).** This guarantees a fresh tree
but repeatedly transfers and checks out a large kernel repository. Resetting
and cleaning a valid dedicated source checkout provides the required clean
state without discarding its Git objects.

**Probe the remote before inspecting local refs (rejected).** This makes every
repeat build depend on a network round trip even when the requested tag is
already present. Local-first detection preserves an offline path for cached
tags while retaining remote fallback for unknown refs.

**Keep a previously patched source tree by default (rejected).** Regenerating
from an already modified annotations file can create an incomplete or empty
delta. Clean upstream state is the safer default.

**Split the work into two ADRs (considered).** The annotations helper is
specific to JG tag transitions, while the Git source changes benefit every
Git-mode build. They remain in one ADR because they were introduced together
to make the same kernel build repeatable and share one validation outcome.

## Consequences

- Future `jg/ubuntu-qcom-x1e-7.1.3-jg-<n>` tags have a repeatable procedure
  for replacing their annotations patch before the package build.
- The regeneration environment intentionally installs the full source build
  dependencies. Its first run is slower and requires Ubuntu package network
  access, but its Kconfig result matches the real build more closely.
- All Git-mode kernel builds benefit from shallow initial clones and from
  preserving valid checkouts across `--reset-source` runs.
- `--reset-source` is destructive inside the dedicated kernel source
  checkout: tracked changes and untracked build output are discarded. It does
  not act on this support repository.
- Shallow checkouts do not contain general repository history. Developers who
  need history for patch archaeology must fetch it separately.
- Cached tags avoid repeated Git network queries and fetches, but deliberately
  do not detect an upstream retag without removing the cached source.
- The versioned annotations filename improves provenance and prevents a stale
  `jg-0` patch from being applied silently to a `jg-1` source tree.
- The helper removes only older versioned annotations patches. The Stubble
  compatibility patch and any other files in the patch directory remain in
  place.

## Validation

The `7.1.3-jg-1` annotations regeneration produced a patch covering the
toolchain-derived Rust and LLVM policies, Rust availability features, the
version signature, and obsolete DRM validation policy. The subsequent Docker
build used:

```text
binary-indep binary-qcom-x1e
```

The build passed Ubuntu's `check-config` stage and produced these four package
roles:

- `linux-image-7.1.3-jg-1-qcom-x1e`
- `linux-modules-7.1.3-jg-1-qcom-x1e`
- `linux-headers-7.1.3-jg-1-qcom-x1e`
- `linux-qcom-x1e-headers-7.1.3-jg-1`

The packages and corresponding patched source were published in the
[`sp11-qcom-x1e-7.1.3-jg-1` prerelease](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.1.3-jg-1).
After installation, I've confirmed that the new kernel works on the
Surface Pro 11.

## Related

- [ADR-0021: Git Fallback Kernel Build Toolchain](adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR-0023: Docker Kernel Build Case-Sensitive Work Volume](adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
- [ADR-0037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1](adr-0037-jglathe-qcom-7-1-1-stubble-paths.md)
- [ADR-0040: Multiple Patch Directories for Kernel Build Scripts](adr-0040-multi-patch-dirs.md)
- [`scripts/build-sp11-qcom-x1e-kernel.sh`](../../scripts/build-sp11-qcom-x1e-kernel.sh)
- [`scripts/regenerate-qcom-x1e-annotations.sh`](../../scripts/regenerate-qcom-x1e-annotations.sh)
- [`patches/jglathe-qcom-x1e-7.1.3/README.md`](../../patches/jglathe-qcom-x1e-7.1.3/README.md)
