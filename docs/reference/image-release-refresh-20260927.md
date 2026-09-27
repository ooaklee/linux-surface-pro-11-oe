---
id: image-release-refresh-20260927
title: "2026-09-27 Image Release Refresh"
description: Pre-retirement audit and reaction-retention policy for three experimental image releases selected for the five-distribution Lexr v0.5.0-rc.3 refresh.
---

# 2026-09-27 image release refresh

## Status and authorized scope

This is the **pre-retirement record** for the owner's requested refresh of
the experimental Surface Pro 11 live images. The release metadata and small
assets below were captured on 2026-09-27, before deletion. This record does
not assert that replacements have been published or that retirement has
finished. Commit this record and its evidence before removing any release.

The owner's original request was to rebuild all five implemented distributions
with Lexr `v0.5.0-rc.3`, then remove these three older GitHub release entries
and their uploaded assets after the replacements pass validation:

- `sp11-ubuntu-concept-26.04-v23-20260905`
- `sp11-elementary-os-8.1-v23-20260906`
- `sp11-arch-linux-arm-terminal-v23-20260909`

**Preserve all three Git tags at their existing targets.** Do not reuse their
names for new images. Kernel and userspace releases and all other image
releases are outside this retirement scope.

### Owner policy amendment: retain releases with reactions

The owner subsequently amended the request: **preserve any of these three
releases that has reactions**, retain its uploaded assets, and prepend a notice
linking its verified replacement. Remove only the selected releases without
reactions, after all five replacements pass the publication and validation
gates. This amendment supersedes the original instruction to remove all three.

The publication operator queried each release's reaction endpoint on
2026-09-27. The verified results at `2026-09-27T01:18:29.746876+00:00` were:

| Selected legacy release | Verified reaction count | Current planned action |
| --- | --- | --- |
| `sp11-ubuntu-concept-26.04-v23-20260905` | 2 (both `+1`) | Retain the release and its assets; prepend a supersession notice linking `sp11-ubuntu-concept-26.04-v23-20260927` after verified publication. |
| `sp11-elementary-os-8.1-v23-20260906` | 0 | Remove the release and its assets only after a fresh zero-reaction check and replacement validation. |
| `sp11-arch-linux-arm-terminal-v23-20260909` | 0 | Remove the release and its assets only after a fresh zero-reaction check and replacement validation. |

The fresh count came from the dedicated reaction endpoints. An absent
`reactions` field in a release API response is not evidence of zero reactions.
**Immediately before each removal, recheck that release's reactions.** If any
reaction has appeared, retain the release and its assets and link its verified
replacement instead. If the count cannot be established, do not delete it.
Preserve the historical body beneath any supersession notice; do not rewrite
earlier image identities or qualification claims as results for the new ISO.

These are planned actions, not completed remote mutations. The original
18-file metadata capture and its snapshot checksums remain unchanged; this
later policy amendment records the newer reaction observation separately.

The reason is an owner-requested replacement of older embedded Lexr versions
with the same `v0.5.0-rc.3` version across the five images. This audit does not
establish that the retiring images are broken, corrupt or incorrectly
identified. It preserves their distinct hardware-evidence boundaries below.

[ADR0051](../adr/adr-0051-release-and-tag-cleanup.md) normally preserves valid
historical releases and requires deleting tags when removing broken or
incorrectly identified releases. The explicit owner request here is a bounded
exception to supersession-only preservation, now limited by the reaction
retention amendment above. Only selected unreacted release entries and assets
may be removed, while all source tags remain. This is not an application of
that ADR's broken-release/tag deletion procedure. The audit and validation
requirements remain in effect.

## Replacement set and qualification

All five replacements select Lexr source
[`120941632db2d2b086983c6cd2e90320d25a0999`](https://github.com/ooaklee/lexr.sh/commit/120941632db2d2b086983c6cd2e90320d25a0999)
(`v0.5.0-rc.3`), kernel release
[`sp11-qcom-x1e-7.2.0-jg-0sp11v23`](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2.0-jg-0sp11v23),
ABI `7.2.0-jg-0sp11v23-qcom-x1e`, and the X1E/OLED profile.

| Distribution | New immutable tag selected for this refresh |
| --- | --- |
| Ubuntu Concept Resolute | `sp11-ubuntu-concept-26.04-v23-20260927` |
| elementary OS 8.1 | `sp11-elementary-os-8.1-v23-20260927` |
| Debian Live GNOME, 2024-09-02 snapshot | `sp11-debian-13-gnome-v23-20260927` |
| Fedora Workstation Live 44 | `sp11-fedora-workstation-44-v23-20260927` |
| Arch Linux ARM terminal, 2026-08-05 snapshot | `sp11-arch-linux-arm-terminal-v23-20260927` |

These are new ISO bytes. Structural and release-integrity validation do not
transfer earlier physical test results to them. No new physical boot,
installation, installed-system boot or recovery test is recorded here, and
there is no X1P/LCD qualification claim. The final README download section
will identify the completed releases and their source snapshots.

Before changing any of the three selected legacy releases, the publication operator must
verify all five replacement releases, their exact asset membership, recorded
producer and kernel identities, and reconstruction/checksum validation against
freshly downloaded assets. Preserve this committed audit, retain Ubuntu with
a supersession notice, and recheck reactions immediately before removing either
remaining candidate. Any candidate with reactions must instead be retained
with a notice. Confirm all three tag refs still have the recorded targets.
Record completion separately once observed; this pre-retirement document is
not an execution receipt.

## Provenance boundary

The captured API `target_commitish` and independently captured remote tag
records agree on this OE anchor for all three legacy releases:

[`aba8c0b65ea73422c8e15868606bb934780a066e`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/aba8c0b65ea73422c8e15868606bb934780a066e).

The generated image-release manifests do not contain an OE support-commit
field. Their Lexr companion/producer revisions identify the remaster
implementation separately from that OE tag anchor. No manifest-to-OE-commit
equality is inferred or manufactured. The captured release bodies explain
this separation; the raw metadata retains it unchanged.

| Legacy release | GitHub release ID | Published UTC | Lexr producer commit |
| --- | --- | --- | --- |
| Ubuntu `20260905` | `383331036` | `2026-09-05T18:14:05Z` | `872ecf90df03dafd3f56dfd326fe79765bb439ed` |
| elementary `20260906` | `383683964` | `2026-09-06T19:02:14Z` | `927d00e1f672bc177593c6dde1862cb348cce60b` |
| Arch `20260909` | `385144027` | `2026-09-09T00:32:29Z` | `4c8aaf5bda4c813938275633d08fed93260ede45` |

All three captured entries are published experimental prereleases using the
v23 kernel ABI. Their full release bodies, asset names, sizes, API digests,
download URLs and timestamps are retained in the evidence appendix.

## Earlier image identity and physical evidence

The image digests below are **recorded legacy provenance**. This audit did
not download the large split parts or reconstruct these ISOs again.

| Legacy image | Recorded size, bytes | Recorded ISO SHA-256 |
| --- | --- | --- |
| `sp11-ubuntu-concept-26.04-v23-20260905.iso` | 4,629,463,040 | `408ea746c472666aa86c71430de005aef916376205e65c65c5060eece4ee9607` |
| `lexr-elementary-sp11-v23-927d00e.iso` | 3,713,728,512 | `82f9b71c610a05c9b42b34e72cc36c121fe549841a55a22b7e3f808c25022884` |
| `sp11-arch-linux-arm-terminal-v23-20260909.iso` | 2,221,146,112 | `b4284b022ebe1ef662a01ba382add81f470186cf49dc9bf1031cc6d4ac15b8c8` |

- **Ubuntu:** the release was rebuilt with Lexr `872ecf9`; its notes claim
  structural and reconstructed-byte validation but no separate physical boot
  of that exact release ISO. Earlier X1E/OLED desktop, Wi-Fi, installer welcome
  and configured pen/touch results belong to Lexr `384f2c0`.
- **elementary:** the release notes identify `927d00e` and the recorded ISO
  above as the exact X1E/OLED live-desktop, Wi-Fi, browsing and installer-chooser
  test image. Completed installation and installed boot remain unqualified.
- **Arch:** the release was rebuilt with Lexr `4c8aaf5`; its notes distinguish
  structural/release validation from a physical boot or installation of those
  release bytes. Earlier candidate 4 (`2e0d384`) completed live boot,
  installation and an internal NVMe ext4 boot. Later configured-system input,
  audio, camera and power-profile results do not make those features automatic
  in a fresh installation.

Removing an unreacted release's downloads does not retract these accurately bounded
historical observations. Preserve the candidate revisions and image hashes in
the Lexr hardware test records.

## Retained evidence and verification

The [evidence appendix](image-release-refresh-20260927-evidence/README.md)
retains six files for each release: the public API `release.json`, captured
`remote-tag.txt`, original `SHA256SUMS`, generated `RELEASE-NOTES.md`,
`image-release-manifest.json`, and original ISO manifest. All 18 files are
byte-for-byte copies of the capture.

Verification of the retained bytes established:

- all nine retained small assets named by the original `SHA256SUMS` match;
- all 12 retained downloadable assets, including each `SHA256SUMS`, match the
  captured GitHub API asset digest and byte size;
- each release manifest's embedded image contract equals its ISO manifest,
  and the recorded manifest hash/size agree;
- the seven omitted split parts have agreeing hash/size metadata across the
  checksum files, release manifests and API captures, but their bytes were
  not downloaded or rehashed for this audit; and
- the captured remote refs agree with the API tag targets.

`release.json` and `remote-tag.txt` are capture records, not publisher-checksummed
release assets. The appendix's separately generated `SNAPSHOT-SHA256SUMS`
protects the retained snapshot; it does not confer publisher provenance on
those two records or validate the omitted ISO parts. Per-file results are in
the appendix's [verification.json](image-release-refresh-20260927-evidence/verification.json).

The retained text was reviewed for private host paths, credential/token
signatures, embedded URL credentials and local-only context. None was found.
Public GitHub account metadata, generic `$HOME` examples, image filesystem
paths, public source URLs and the historical release instructions remain.
Private creation journals and large binary image parts are excluded.

## Documentation availability

No retiring-tag download links were found in OE-owned documentation outside
the pinned `cli/lexr` submodule. The exact rc.3 Lexr source retains six active
links to the old releases: three in its README, elementary and Arch links in
`docs/user-guide/installation-media.md`, and one in
`docs/user-guide/arch-linux-arm-quickstart.md`.

Update maintained Lexr documentation separately when the replacements are
available; do not rewrite the immutable rc.3 producer source or relabel the
new elementary bytes as the previously tested ISO. The archived release
bodies and generated notes in this appendix are historical records, not
current download instructions. Their original links are intentionally retained.
