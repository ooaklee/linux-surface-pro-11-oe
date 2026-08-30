---
id: adrs-adr009
title: "ADR009: Single-manifest on-media companion bundle"
description: Architecture decision for carrying an offline Linux ARM64 CLI, corresponding source, catalogues, and eligible userspace releases on installation media.
---

## Status

Accepted on 2026-08-30.

## Context

A live image can boot the selected kernel while still lacking the tools needed to diagnose userspace support or install a verified support release without network access. Carrying only kernel packages under the ISO support directory leaves the operator to obtain a matching CLI and source tree separately after boot.

The companion payload must remain distribution-neutral so future image adapters can use it without adopting Ubuntu Casper behaviour. It must also preserve exact provenance, reject untracked files, and respect different redistribution policies for the CLI and each userspace component. A second ISO-level manifest would create competing inventories and make it unclear which document is authoritative.

The repository does not currently declare project-wide redistribution terms for the CLI source and binary. Local image generation may record that fact, but publication automation must not infer a licence or claim permission that has not been granted.

## Decision

A distribution-neutral `image/companion` package will own the fixed companion layout, immutable source snapshot, static Linux ARM64 cross-build, catalogue validation, optional offline userspace staging, and payload validation. The image manager will resolve requests and enforce compiled redistribution policy. Distribution adapters will only place the completed directory on their media and attach its inventory to the existing image manifest.

The sole ISO inventory remains `sp11/linux-armer-manifest.json`, with the same
bytes published as the adjacent `*.iso.manifest.json` sidecar. Manifest schema
v3 adds a mandatory `companion_bundle` attribute; no companion-level manifest
will be created. Image publication stages the ISO, those exact manifest bytes,
and the completed execution journal as one fresh output set. Descriptor-bound,
no-replace renames publish the metadata first and the ISO last as the commit
marker, with exact post-rename and complete-set verification. Because Linux and
macOS do not provide conditional unlink-by-inode, a failure retains recoverable
transaction entries and reports their paths instead of risking a pathname-based
rollback. The journal is execution evidence, not another manifest. A portable
`linux-armer-userspace-bundle.json` receipt may remain inside a userspace
release because the existing installer uses it to verify relocatable component
files. That receipt is payload evidence, not an ISO inventory, and
`companion_bundle` records its digest and size like every other companion file.

The canonical included layout is:

```text
sp11/companion/
├── bin/linux-arm64/linux-armer
├── source/linux-armer_<version>_source.tar.gz
├── catalogues/supported-isos.json
├── catalogues/supported-userspace.json
├── licences/<declared-project-documents>
└── userspace/<component>/<release>/
```

The source builder will first copy the maintained source allow-list into a private, read-only snapshot. It will build the executable and create the deterministic source archive from that same snapshot. A clean Git-backed source must match the recorded revision before and after snapshotting. The executable must be a statically linked, little-endian AArch64 ELF with mode `0755`. Requesting a companion therefore adds a host Go toolchain prerequisite, which will be checked before any image or kernel download.

The `companion_bundle` attribute will always be present. An image without a requested payload will record:

```json
{
  "included": false,
  "root": "sp11/companion",
  "reason": "not-requested",
  "userspace": []
}
```

The companion directory must then be absent. An included record will identify the tool, executable, source archive, both catalogues, project-licence state, any licence or notice files, and every offline userspace artefact. Finished-image validation will extract the directory, rehash every declared file, reject missing or additional paths, verify the executable format and mode, and fail if the record and media disagree.

The initial compiled offline allow-list contains only IPTSD. Its pinned release archive includes corresponding source and licence material and may satisfy its `source-required` catalogue policy. Restricted audio and platform firmware will never be included. The `recommended` selector will be rejected because it contains restricted audio, and experimental camera packages will remain excluded until their redistribution and source obligations have a component-specific review. An editable catalogue alone cannot authorise a new offline component.

When the source root has no recognised project-level licence or copying document, a locally requested image may be created with `project_licence` set to `not-declared` and an explicit warning. No current pipeline publishes images containing the companion. Any future companion-publication pipeline must fail until the copyright holder selects a project licence, that document is inventoried, and the statically linked binary's required third-party notices are available. The builder will not invent terms.

## Consequences

- A live or installed system can use the exact image-associated CLI and eligible support files without first relying on network access.
- Future distribution adapters share one neutral companion contract while retaining ownership of their own boot and media-discovery behaviour.
- One authoritative image manifest covers both boot artefacts and companion files; the userspace receipt remains narrowly scoped verification evidence.
- Source, binary, catalogues, and manifest provenance fail together when they disagree or change during staging.
- Offline inclusion remains deliberately narrower than interactive userspace download and installation support.
- Locally generated companion images can be evaluated now, but public redistribution remains blocked until explicit project and dependency licence obligations are met.
