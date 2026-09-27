# Retained public evidence for the 2026-09-27 image refresh

See the [pre-retirement audit](../image-release-refresh-20260927.md) for the
owner-requested scope, preserved tags and qualification boundaries.

Each directory contains the original public API response, remote tag capture,
checksum file, generated release notes, image-release manifest and image
manifest for one selected legacy release:

- [Ubuntu Concept `20260905`](sp11-ubuntu-concept-26.04-v23-20260905/release.json)
- [elementary OS `20260906`](sp11-elementary-os-8.1-v23-20260906/release.json)
- [Arch Linux ARM `20260909`](sp11-arch-linux-arm-terminal-v23-20260909/release.json)

The 18 captured files are unmodified. Their text contains public metadata and
historical instructions; those instructions and links are not current download
guidance. Keep them intact so their recorded digests remain verifiable.

[verification.json](verification.json) lists measured snapshot hashes, byte
sizes, original-checksum and captured-API comparisons. It explicitly marks
omitted split ISO parts as metadata-only evidence. A null comparison means
the record was not a corresponding published asset/checksum entry, not a
successful verification.

From this directory, verify the retained snapshot with:

```sh
shasum -a 256 -c SNAPSHOT-SHA256SUMS
```

`SNAPSHOT-SHA256SUMS` is generated for this documentation snapshot. The original
per-release `SHA256SUMS` files also name large split parts not retained here;
they cannot validate a complete release from this metadata-only appendix.
No complete legacy ISO reconstruction or new hardware test is claimed.
