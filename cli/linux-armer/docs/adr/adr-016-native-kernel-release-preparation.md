---
id: adr-016-native-kernel-release-preparation
title: "ADR016: Native kernel release preparation and v3 retirement"
description: Architecture decision for preparing path-free, closed kernel release directories from exact native build output while rejecting retired out-of-tree touchscreen bundles.
---

# ADR016: Native kernel release preparation and v3 retirement

## Status

Accepted on 2026-08-30.

## Context

The repository's original kernel release helper combined several generations
of build policy. It could consume loosely related package and metadata
directories, infer some release identity, tolerate source-less local drafts,
and optionally add an exact-ABI out-of-tree touchscreen module set. The
validator also knew about local and remote Git tags. Those behaviours were
useful during bring-up, but they no longer describe the maintained kernel.

The native kernel builder now emits one closed directory with the package
bytes, a normal kernel bundle, exact Git and recipe provenance, and a checksum
set covering only those packages. Release preparation can therefore consume a
typed build contract instead of reconstructing policy from shell output.

The `sp11v3` touchscreen release used separate `gpi`, `spi-geni-qcom`, and
`mshw0485_touch` modules. Later kernels carry that stack in-tree. Continuing to
accept the old ABI or its module bundle would make it possible to publish a
current-looking release that reintroduced obsolete module precedence and
initramfs repair requirements.

Public release metadata must not reveal a contributor's host paths or the
Docker volume identity derived from their workspace. Preparation also must not
become implicit authority to create a remote release.

## Decision

The `internal/kernel/releaseprep` domain owns local kernel release preparation
and validation. Cobra exposes it as:

```text
linux-armer kernel release prepare
linux-armer kernel release validate <release-directory>
```

Preparation accepts exactly one fresh directory emitted by
`internal/kernel/build`, a tag-like release name, one new output path, one or
more corresponding-source archives, and one or more explicitly named licence
text files. It requires the build directory to contain exactly the builder's
bundle, private provenance, package checksum file, and coherent package set.
The recorded bundle must match the builder's exact release identity,
repository, package paths, roles, sizes, digests, versions, ABI, architecture,
and device-tree contract.

The complete private build provenance is retained only in the in-memory plan
so a mutating run can revalidate it. The public projection includes the safe
HTTPS source URL, Git ref, immutable revision and tree, commit time, compiled
recipe digest, digest-pinned container image, and toolchain digest. It omits
the Docker work-volume name and every input or output path. Human and JSON
delivery output follows the same path-free boundary.

`--dry-run` performs the full read-only inspection and hashing pass but creates
no parent or output directory. A mutating run revalidates all inputs, creates a
mode-`0700` sibling staging directory, copies each file with cancellation and
digest checks, writes deterministic public contracts, validates the complete
staging directory, then changes the completed directory to public read/search
permissions. Publication uses one rename into an absent destination. The
receipt reports publication and the subsequent parent-directory durability
flush separately.

The prepared directory is a closed flat set. `SHA256SUMS` covers every other
file exactly once, including the public bundle, release manifest, generated
British-English notes, source archives, and licence files. Validation rejects
unknown or trailing JSON, symbolic links, special files, directories, extra or
missing files, case-folded filename collisions, checksum or size drift,
package role/version/ABI drift, unpaired headers, source URLs outside the
native builder's bounded repository-URL contract, ambiguous Git refs, mutable
container images, absent source or licence evidence, and notes that do not
match the manifest-derived text.

The `sp11v3` ABI and recognisable out-of-tree touchscreen files are rejected
explicitly. The old v3 release remains historical evidence in earlier ADRs,
but it is not an input variant of the maintained release API.

This domain performs no remote tag lookup, GitHub CLI invocation, upload,
publication, installation, privilege escalation, or hardware probing. Every
manifest remains experimental with `hardware_qualified: false`. A future
publication command would require its own authority, confirmation, recovery,
and re-download validation contract.

## Consequences

- A released ARM64 companion can prepare and validate kernel release bytes
  without a repository script directory.
- Release input must come directly from the native builder; historic build
  manifests and mixed directories are intentionally incompatible.
- Corresponding source and explicit licence evidence can no longer be omitted,
  even for a rehearsal that uses `--dry-run`.
- Public manifests and command receipts are suitable for sharing without
  exposing local filesystem or Docker workspace identity.
- Release preparation is recoverable before the final rename and refuses an
  existing or raced output rather than merging or overwriting it.
- Closed-directory validation is stronger than package-only acquisition but
  remains structural, not a legal judgement, reproducibility proof, or Surface
  hardware qualification.
- The former v3 out-of-tree touchscreen release path has no compatibility flag;
  users must move to a kernel carrying the drivers in-tree.

## Superseded operational paths

The maintained commands replace the former kernel release-preparation and
touchscreen-release validation helpers. Historical ADRs may continue to name
those helpers as evidence of the workflow used at the time; current procedures
must use the commands above and the current
[kernel release how-to](../../../../docs/how-to/how-to-release-kernel-artifacts.md).
