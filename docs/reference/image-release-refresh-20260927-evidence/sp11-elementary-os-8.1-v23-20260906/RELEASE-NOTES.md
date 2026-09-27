# Surface Pro 11 ARM64 installation image

This local release contains an experimental, unsigned `elementary-casper` hybrid ISO for the Surface Pro 11. It is not hardware-qualified merely because structural validation passed. Disable Secure Boot before using its unsigned custom kernel.

Kernel ABI: `7.2.0-jg-0sp11v23-qcom-x1e`

## Verify the release directory

```bash
lexr image release validate .
```

`SHA256SUMS` covers the copied image manifest, this note, the release manifest, and every compressed part. `image-release-manifest.json` records the path-free image, build, validation, companion-bundle, compression, and part provenance.

## Reconstruct the ISO

```bash
cat lexr-elementary-sp11-v23-927d00e.iso.zst.part-* | zstd --decompress --stdout > lexr-elementary-sp11-v23-927d00e.iso
printf '%s  %s\n' '82f9b71c610a05c9b42b34e72cc36c121fe549841a55a22b7e3f808c25022884' 'lexr-elementary-sp11-v23-927d00e.iso' | sha256sum --check -
```

Use `lexr image write lexr-elementary-sp11-v23-927d00e.iso --device <reviewed-device>` for identity-bound removable-media writing. The release preparation command performs no remote publication.
