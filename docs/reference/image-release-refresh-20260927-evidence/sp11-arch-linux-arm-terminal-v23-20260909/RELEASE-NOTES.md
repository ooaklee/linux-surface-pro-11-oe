# Surface Pro 11 ARM64 installation image

This local release contains an experimental, unsigned `archlinux-arm-live` hybrid ISO for the Surface Pro 11. It is not hardware-qualified merely because structural validation passed. Disable Secure Boot before using its unsigned custom kernel.

Kernel ABI: `7.2.0-jg-0sp11v23-qcom-x1e`

## Verify the release directory

```bash
lexr image release validate .
```

`SHA256SUMS` covers the copied image manifest, this note, the release manifest, and every compressed part. `image-release-manifest.json` records the path-free image, build, validation, companion-bundle, compression, and part provenance.

## Reconstruct the ISO

```bash
cat sp11-arch-linux-arm-terminal-v23-20260909.iso.zst.part-* | zstd --decompress --stdout > sp11-arch-linux-arm-terminal-v23-20260909.iso
printf '%s  %s\n' 'b4284b022ebe1ef662a01ba382add81f470186cf49dc9bf1031cc6d4ac15b8c8' 'sp11-arch-linux-arm-terminal-v23-20260909.iso' | sha256sum --check -
```

Use `lexr image write sp11-arch-linux-arm-terminal-v23-20260909.iso --device <reviewed-device>` for identity-bound removable-media writing. The release preparation command performs no remote publication.
