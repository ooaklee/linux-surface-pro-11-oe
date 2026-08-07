---
id: adr-0051-release-and-tag-cleanup
title: "ADR0051: Remove Broken or Incorrect Releases and Tags"
# prettier-ignore
description: Decision record for auditing the project's GitHub releases and tags, removing artifacts with false functionality or provenance, and preserving valid historical releases.
---

# ADR0051: Remove Broken or Incorrect Releases and Tags

## Status

Accepted and executed (2026-08-07). Amended the same day to record the names
and validation rules for the authorized experimental r1 successors.

## Context

The touchscreen clean-install retrospective in
[ADR0050](adr-0050-sp11-touchscreen-clean-install-release-flow.md) found that
the public `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3` release could not be treated as a
reproducible release:

- its tag pointed to the v2 support commit rather than the commit recorded by
  the release manifest or the later v3 merge;
- its checksum file listed itself with the empty-file hash and named a release
  notes file that was not uploaded;
- the touchscreen modules were added without a dedicated immutable provenance
  manifest; and
- its install instructions allowed a stock controller to remain in the
  initramfs, causing a clean installation to report `Invalid proto 9`.

That discovery required a broader question: whether other historical releases
or tags also made claims that their artifacts, provenance, or tagged source did
not support. Removing only the most recent release would leave earlier known
failures available for new users to install.

### Audit scope and method

The audit examined all 11 GitHub releases, all 11 remote tags, and all 12 local
tags that existed before cleanup. The additional local tag was the unpublished
`sp11-qcom-x1e-7.2-rc5-jg-0` source marker.

For each release, the audit:

1. listed the release title, target, assets, and published instructions;
2. resolved the local and remote tag to a commit;
3. downloaded the small checksum and provenance manifests;
4. compared the manifest's support commit with the tag target;
5. compared checksum entries with the actual uploaded asset names;
6. inspected the tagged tree for the support files claimed by the release;
7. compared functionality claims with the device evidence and later ADRs; and
8. distinguished a superseded but valid experiment from an artifact known to
   be broken or incorrectly identified.

Age or supersession alone was not grounds for deletion. A historical release
could remain when its claims and known provenance limitations were disclosed,
its tag matched the support commit named by the manifest, and no device
evidence showed that its primary purpose failed.

## Findings

### Releases and tags removed

| Release and tag | Finding | Evidence |
| --- | --- | --- |
| `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3` | Incorrect tag, invalid checksum set, incomplete touchscreen provenance, and unsafe clean-install instructions | Tag `1fe13d2` was the v2 tree; the manifest recorded `25bd39c`; v3 merged as `0a3fbdd`; `SHA256SUMS` named itself and a missing notes asset; ADR0050 records the clean-install failure |
| `sp11-qcom-x1e-7.1.3-jg-0-touch` | The released kernel did not contain the touchscreen patches it claimed to provide | Tag `353b9e1` predates the touchscreen change and contains no touchscreen patch paths; the manifest recorded `050c19e`; ADR0042 records that the installed release lacked the patches and touchscreen configuration |
| `sp11-ubuntu-live-direct-jg-7.1.1` | The tag could not reproduce the image described by its manifest | Tag `8b866b5` pointed to the parent of manifest commit `8f38745`, which added the Johan G. 7.1.1 support used by the image |
| `sp11-audio-topology-v1` | The included Surface UCM profile was functionally broken and had a corrected successor | Its `HiFi` verb referenced nonexistent `WSA2` controls and aborted before exposing `Speaker` or `Mic`; ADR0044 documents the defect and the v2 correction |

The deleted tag targets and conflicting manifest commits are retained here
because the public refs no longer provide that audit trail:

- `sp11-qcom-x1e-7.2-rc5-jg-0sp11v3` targeted
  `1fe13d2e124f40dbeccfca99910375952c8e7a1b`; its manifest recorded
  `25bd39c8f187ce2b965ce2c5a82145c5596a024f`, and the reviewed v3 change
  later merged as `0a3fbdd06c9821cd13564325b1921effeaf58cf5`.
- `sp11-qcom-x1e-7.1.3-jg-0-touch` targeted
  `353b9e12e6adbbee29e629c4c35332c404643dd6`; its manifest recorded
  `050c19efc7e66ad03bc9a156f1290a21a21323be`.
- `sp11-ubuntu-live-direct-jg-7.1.1` targeted
  `8b866b5619b43c739ef58b09dcdcb8f9848fbf57`; its manifest recorded direct
  child `8f387451fa45296a6bba3e49cab0f3bec4ac2cfd`.
- `sp11-audio-topology-v1` targeted the matching support commit
  `f79eab7a9e276dfd2816a3e048b9b886c9637e61`; it was removed for its
  functional UCM defect rather than a tag mismatch.

The removed asset inventory consisted of:

- four v3 kernel packages, three touchscreen modules, a patched-source
  archive, the kernel release manifest, the package list, and `SHA256SUMS`;
- four 7.1.3 touchscreen kernel packages, a patched-source archive, two
  kernel metadata files, and `SHA256SUMS`;
- three split live-image parts, the image outline, the image manifest, and
  `SHA256SUMS`; and
- the audio topology binary, two UCM files, the card matcher, `CMakeLists.txt`,
  release notes, the audio manifest, and `SHA256SUMS`.

The live image itself was not proven corrupt. Its release was removed because
the tag-to-manifest mismatch made the published source identity incorrect. A
large binary release must remain traceable even when its runtime output looked
valid during the original test.

### Releases and tags preserved

The following seven releases were retained:

| Release | Tag/provenance result | Reason retained |
| --- | --- | --- |
| `sp11-qcom-x1e-7.0.0-22.22-rfkill1` | Tag and manifest match `dd93fa7` | Bounded Wi-Fi rfkill build with matching source provenance |
| `sp11-qcom-x1e-7.1.1-jg-0-sp11` | Tag and manifest match `8b866b5`; manifest records `Support repo dirty: true` | Retained legacy Johan G. kernel with bounded claims and disclosed non-clean provenance |
| `sp11-qcom-x1e-7.1.3-jg-0-sp11` | Tag and manifest match `421e4be`; manifest records `Support repo dirty: true` | Retained legacy kernel without a false touchscreen claim, but not a clean reproducibility example |
| `sp11-qcom-x1e-7.1.3-jg-1` | Tag and manifest match `320317b` | Reproducible baseline build with bounded experimental claims |
| `sp11-qcom-x1e-7.1.3-jg-1-dmic-2p4mhz` | Tag and manifest match `b4d6922` | Device-validated diagnostic DMIC build |
| `sp11-qcom-x1e-7.1.3-jg-1-v2` | Tag and manifest match `c67df67` | Device-validated 2.4 MHz DMIC default kernel |
| `sp11-audio-topology-v2` | Tag and manifest identify `c67df67` | Corrected single-WSA UCM and validated microphone route |

The local-only `sp11-qcom-x1e-7.2-rc5-jg-0` tag at `ca379d2` was retained
during the original cleanup. A later 2026-08-07 audit found that marker absent
from the active checkout. It never had a GitHub release or remote tag, and it
is not required for release provenance because the upstream source tag and
full source commit are now recorded explicitly.

The two retained dirty-manifest releases are legacy artifacts, not templates
for future publication. Their tags correctly identify the commits recorded by
their manifests, and their primary claims are not known to be false, but the
uncommitted build-time support-tree state cannot be reconstructed from the tag.
Current release tooling refuses dirty support repositories by default.

## Decision

Delete the four broken or incorrectly identified GitHub releases and their
remote and local tags:

```text
sp11-qcom-x1e-7.2-rc5-jg-0sp11v3
sp11-qcom-x1e-7.1.3-jg-0-touch
sp11-ubuntu-live-direct-jg-7.1.1
sp11-audio-topology-v1
```

Use the following criteria for future cleanup decisions. A release and its tag
must be removed when evidence establishes one or more of these conditions:

- the release's primary functionality was not present or did not work;
- the tag does not resolve to the support commit recorded by the manifest;
- the tagged tree lacks the patches, scripts, or instructions claimed by the
  release;
- the documented integrity check cannot succeed against the published asset
  set; or
- the release creates an unsafe default path that a clean installation cannot
  reproduce.

Do not delete a release merely because a newer version exists. Preserve useful
historical experiments when their names, claims, tag targets, and manifests
remain accurate.

### Deletion procedure

For each selected release:

1. capture the tag target, manifest commit, asset list, and reason for removal
   in this ADR or a linked retrospective;
2. delete the GitHub release and its remote tag together with:

   ```bash
   gh release delete "$tag" \
     --repo ooaklee/linux-surface-pro-11-oe \
     --cleanup-tag \
     --yes
   ```

   The `--cleanup-tag` flag is mandatory. If post-deletion verification still
   finds the remote tag, delete that exact ref explicitly with
   `git push origin --delete "$tag"`;
3. delete the corresponding local tag;
4. verify independently that the release, remote tag, and local tag are all
   absent; and
5. remove live documentation links or amend historical ADRs to state that the
   artifact was removed.

Do not move a broken public tag to a corrected commit and do not reuse its
name. A corrected artifact must receive a new immutable tag so caches, mirrors,
and prior audit records cannot confuse the two releases.

The corrective standalone kernel/module bundle is named
`sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1`, and the corrective image is named
`sp11-ubuntu-live-direct-7.2-rc5-jg-0sp11v3-r1`. The `-r1` suffix identifies
new immutable public artifacts; it does not change the installable
`7.2-rc5-jg-0sp11v3-qcom-x1e` kernel ABI. Neither retired original name may be
recreated.

Both corrective releases were published on 2026-08-07 as experimental
prereleases. Their remote tags resolve to support commit
`acdc959ca7a32318e321c2c11e96bae6b9980f53`. This publication does not promote
either artifact to hardware-qualified or stable status.

### Future release gates

Before publishing any new binary release:

- create it with an explicit `--target <support-commit>`, including image
  releases prepared by `prepare-sp11-image-release-assets.sh`;
- require the manifest support commit and local and remote tag targets to
  agree;
- generate checksums from the exact upload list rather than adding assets
  afterward;
- validate a fresh download against exact asset membership and semantic
  package or image checks;
- keep release notes out of `SHA256SUMS` when they are used only as the GitHub
  release body; and
- retain a new tag only after the release validator passes.

When `gh release create` creates a previously absent tag, fetch that exact tag
locally before the post-publication validator runs. The validator compares the
manifest support commit with both the local and remote tag targets.

Touchscreen releases additionally follow the exact-ABI module, DTB,
initramfs, and provenance gates in ADR0050.

The project owner authorized the fresh r1 kernel and image as experimental
prereleases while ADR0050's clean-install hardware matrix is outstanding. This
is a distribution exception, not a hardware qualification. The r1 notes must
disclose the outstanding matrix and require a known-good fallback kernel and
recovery media. Stable or hardware-qualified promotion remains blocked until
the matrix passes; checksum, source, support-commit, tag, asset-equality, and
fresh-download gates are not waived.

## Execution and verification

The four releases were deleted with GitHub's release cleanup operation, which
also deleted their remote tags. Their local tags were then deleted explicitly.

Post-cleanup verification established:

- all four release lookups fail because the releases no longer exist;
- all four remote tag lookups return no matching refs;
- all four local tag lookups return no matching refs;
- seven preserved GitHub releases and their seven remote tags remain;
- eight local tags remain, including the valid local-only 7.2-rc5 source tag;
- no repository document links directly to any deleted GitHub release; and
- `git diff --check` passes for the tracked documentation amendments, and the
  new ADR contains no trailing whitespace.

### Evidence-retention limitation

The release API responses and small manifests were inspected before deletion,
but a complete redacted raw audit bundle was not committed first. The deleted
assets can therefore no longer be fetched independently from GitHub. This ADR
preserves the resolved commits, asset inventory, comparison results, and links
to corroborating repository history, but not the original API response bodies.

Future release cleanup must commit a privacy-reviewed textual audit appendix
containing the release JSON, checksum file, and small provenance manifests
before deleting the remote release. Binary assets remain excluded.

## Consequences

- New users cannot accidentally download artifacts already known to be broken
  or incorrectly identified.
- The public release list is shorter but more trustworthy.
- Historical reasoning remains available in git and the ADRs even though the
  binary assets are no longer published.
- Deleting a release removes its assets from normal GitHub access. Those
  binaries are not recoverable from the git repository unless another copy
  exists elsewhere.
- The deleted tags could technically be recreated from their recorded commit
  IDs, but their names are retired and must not be reused for replacement
  releases.
- Valid older releases remain available; cleanup does not imply that only the
  newest release may be retained.

## Alternatives Considered

### Leave broken releases published with a warning

Rejected. Existing download links, cached instructions, and direct asset URLs
can bypass an edited warning. A known-broken kernel or boot image remains a
risk while its release assets are public.

### Move the existing tags to corrected commits

Rejected. Moving a public tag destroys the stable relationship between a name
and the source previously downloaded under that name. It also leaves mirrors
and caches with conflicting histories.

### Delete every historical release

Rejected. Several older releases have matching tag provenance and bounded,
validated purposes. Removing correct artifacts would discard useful rollback
and diagnostic options without improving the accuracy of the remaining
release set.

### Keep the live image because its runtime validation passed

Rejected. Runtime validation does not repair incorrect source provenance. A
published image must be bound to the exact support commit recorded by its
manifest.

## Related

- [ADR0026: Prebuilt Kernel Release Artifacts](adr-0026-prebuilt-kernel-release-artifacts.md)
- [ADR0038: Split Compressed Live Image Release Assets](adr-0038-split-compressed-live-image-release-assets.md)
- [ADR0042: Surface Pro 11 Touchscreen Integration Troubleshooting](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR0044: Surface Pro 11 UCM Uses One WSA Macro and Two Microphone Channels](adr-0044-sp11-ucm-single-wsa-macro-microphone.md)
- [ADR0047: JG 7.2-rc5-jg-0 Kernel Build](adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)
- [ADR0050: Surface Pro 11 Touchscreen Clean-Install and Release Flow](adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [Release Prebuilt Kernel Artifacts](../how-to/how-to-release-kernel-artifacts.md)
