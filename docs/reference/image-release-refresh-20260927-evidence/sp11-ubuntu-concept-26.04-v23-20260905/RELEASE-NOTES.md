# Surface Pro 11 ARM64 installation image

This local release contains an experimental, unsigned `ubuntu-casper` hybrid ISO for the Surface Pro 11. It is not hardware-qualified merely because structural validation passed. Disable Secure Boot before using its unsigned custom kernel.

Kernel ABI: `7.2.0-jg-0sp11v23-qcom-x1e`

## Verify the release directory

```bash
lexr image release validate .
```

`SHA256SUMS` covers the copied image manifest, this note, the release manifest, and every compressed part. `image-release-manifest.json` records the path-free image, build, validation, companion-bundle, compression, and part provenance.

## Reconstruct the ISO

```bash
cat sp11-ubuntu-concept-26.04-v23-20260905.iso.zst.part-* | zstd --decompress --stdout > sp11-ubuntu-concept-26.04-v23-20260905.iso
printf '%s  %s\n' '408ea746c472666aa86c71430de005aef916376205e65c65c5060eece4ee9607' 'sp11-ubuntu-concept-26.04-v23-20260905.iso' | sha256sum --check -
```

Use `lexr image write sp11-ubuntu-concept-26.04-v23-20260905.iso --device <reviewed-device>` for identity-bound removable-media writing. The release preparation command performs no remote publication.
