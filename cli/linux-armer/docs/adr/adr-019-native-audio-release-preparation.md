---
id: adr-019-native-audio-release-preparation
title: "ADR019: Native FullIO v19c audio release preparation"
description: Architecture decision for deterministic, local-only preparation and validation of the pinned Surface Pro 11 FullIO v19c audio release.
---

# ADR019: Native FullIO v19c audio release preparation

## Status

Accepted on 2026-08-30.

## Context

The Surface Pro 11 audio companion comprises protected vendor-derived topology
bytes and three ALSA UCM files. It must stay outside kernel packages while
remaining easy to verify and install after a matching kernel. The maintained
FullIO v19c inputs already have reviewed source revisions, immutable SHA-256
identities, a source checksum manifest, and an exact DMI-matcher transform.

The earlier publisher combined local staging with a possible GitHub release
mutation. A local preparation request does not authorise tag creation, uploads,
or any other remote change. The retired v2 preparation path also predates the
current FullIO v19c byte contract and must not become a compatibility mode in
the new command.

Release provenance needs to remain useful when copied between machines without
revealing either checkout's location. Preparation must also refuse partially
updated output, unknown files, symbolic-link routes, raced destinations, or a
source that changes after inspection.

## Decision

The `internal/audio/release` feature package owns the current FullIO v19c local
release workflow. Cobra exposes the domain as:

```text
linux-armer userspace audio release prepare \
  --source-root <SP11X1e-audio-checkout> \
  --tag sp11-audio-v19c \
  --kernel-tag <paired-kernel-tag> \
  --kernel-abi <paired-qcom-x1e-ABI>
linux-armer userspace audio release validate <release-directory>
```

All four preparation identities are compiled policy: the FullIO v19c topology,
card UCM file, HiFi UCM file, and upstream matcher base. The exact source paths,
source release, source revision, SHA-256 values, and known payload sizes are not
inferred from a checkout. Preparation also strictly parses the bounded source
`SHA256SUMS`, rejects repeated or non-portable names, validates every listed
regular file, and requires that it authenticates the pinned topology.

The matcher is generated directly in Go. Its base must contain exactly one line
with `Define.DMI_info` and no existing `If.SURFACEPro11` branch. The workflow
inserts the reviewed `If.SURFACEPro11in` condition, exact Microsoft DMI regular
expression, and exact card-profile include after that anchor. The complete
generated matcher must equal its compiled digest and byte length.

The release tag is the exact reviewed `sp11-audio-v19c` identity. Kernel input
is explicit rather than inferred: the tag must be `sp11-qcom-x1e-` followed by
the installed ABI without its final `-qcom-x1e`, and both values must name the
same supported `sp11v12` through `sp11v19` generation.

Preparation writes exactly seven files beneath a fresh
`build/release/sp11-audio-v19c` directory:

- the renamed FullIO topology;
- the card UCM profile;
- the HiFi UCM verb;
- the generated DMI matcher;
- `SHA256SUMS` covering those four installable artefacts in reviewed order;
- deterministic British-English `RELEASE-NOTES.md`; and
- deterministic `audio-release-manifest.json`.

The manifest contains no host path or preparation time. It records the explicit
kernel pairing, sorted source-checksum evidence, role-specific source inputs,
the four exact artefact identities, generated-file identities, the protected
vendor-byte boundary, and `remote_mutation: false`. The generated checksum file
must retain the already published FullIO v19c identity; it is not merely trusted
because it was created locally.

All reads are bounded, cancellation-aware, and tied to a stable regular-file
identity. Copies recheck the source object, size, and digest while streaming.
Output is built exclusively inside a private sibling transaction and completely
validated before publication. The final operation uses Linux or Darwin's
directory-relative atomic no-replace rename primitive. Unsupported platforms
fail before creating output. Cancellation is checked immediately before the
rename, and an existing or raced destination is never replaced.

Independent validation accepts only a direct child of the repository's fixed
`build/release` directory. It strictly decodes canonical JSON, rejects duplicate
or unknown members and excessive nesting, requires the exact seven regular
files, rechecks every compiled pin, regenerates the checksum file and notes, and
repeats the kernel, source-provenance, protected-byte, and no-remote-mutation
invariants. Release-provided executable code is neither required nor run.

## Consequences

- Users can prepare and validate the current audio companion through one native
  CLI hierarchy without invoking a repository shell helper.
- The release is intentionally specific to reviewed FullIO v19c bytes; a future
  topology or matcher needs a new compiled policy and architecture decision.
- Manifests and generated notes are reproducible across different checkout
  locations because neither contains host paths, timestamps, or Git state
  discovered during execution.
- Exact kernel tag and ABI pairing prevents an audio release from silently
  claiming compatibility with an unrelated kernel generation.
- Source `SHA256SUMS` remains evidence rather than an unchecked file copied into
  the release.
- Local preparation never implies permission to publish remotely. Remote release
  creation remains a separate operator action and authority boundary.
- The obsolete v2 preparation workflow is not ported and has no compatibility
  switch in this package.
