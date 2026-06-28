#!/usr/bin/env bash
set -euo pipefail

IMAGE="build/sp11-ubuntu-live-direct.img"
OUT_DIR=""
RELEASE_NAME=""
VALIDATE_IMAGE="true"
ALLOW_DIRTY="false"
PART_SIZE_BYTES="2000000000"
GITHUB_ASSET_LIMIT_BYTES="2147483648"

MANIFEST_NAME="sp11-live-image-release-manifest.txt"
OUTLINE_NAME="sp11-live-image-outline.txt"

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for a Surface Pro 11 live
USB raw disk image. It does not publish anything.

Options:
  --image PATH           Raw .img file, default $IMAGE.
  --release-name NAME    Release/tag name. If omitted, derived from image name.
  --out-dir DIR          Output directory. If omitted, defaults to
                         build/release/<release-name>.
  --skip-validate        Do not run the live-image validator. Intended only for
                         local draft assets.
  --part-size-bytes N    Maximum compressed part size, default
                         $PART_SIZE_BYTES. Must be below GitHub's
                         $GITHUB_ASSET_LIMIT_BYTES byte asset limit.
  --allow-dirty          Allow preparing assets when the support repository has
                         uncommitted changes. Intended for local test runs.
  -h, --help             Show this help.

Output (under build/release/<release-name>/):
  <image>.img.zst.part-*
  $OUTLINE_NAME
  $MANIFEST_NAME
  SHA256SUMS
  RELEASE-NOTES.md
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      require_arg "$1" "${2:-}"
      IMAGE="$2"
      shift 2
      ;;
    --release-name)
      require_arg "$1" "${2:-}"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --out-dir)
      require_arg "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --skip-validate)
      VALIDATE_IMAGE="false"
      shift
      ;;
    --part-size-bytes)
      require_arg "$1" "${2:-}"
      PART_SIZE_BYTES="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_tool awk
require_tool git
require_tool shasum
require_tool split
require_tool stat
require_tool zstd
if [ "$VALIDATE_IMAGE" = "true" ]; then
  require_tool docker
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

if [ ! -f "$IMAGE" ]; then
  echo "Image not found: $IMAGE" >&2
  exit 1
fi

image_abs="$(cd "$(dirname "$IMAGE")" && pwd -P)/$(basename "$IMAGE")"
case "$image_abs" in
  "$repo_dir"/*)
    ;;
  *)
    echo "Image must be inside this repository: $IMAGE" >&2
    exit 1
    ;;
esac

image_base="$(basename "$image_abs")"
image_stem="${image_base%.img}"
compressed_base="$image_base.zst"

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="$image_stem"
fi

release_root="build/release"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$release_root/$RELEASE_NAME"
fi

case "$OUT_DIR" in
  "$release_root"/*)
    out_leaf="${OUT_DIR#"$release_root"/}"
    ;;
  *)
    echo "Refusing output outside $release_root/: $OUT_DIR" >&2
    exit 1
    ;;
esac

case "$out_leaf" in
  ""|*/*|*..*|.*)
    echo "Refusing unsafe release output name: $out_leaf" >&2
    exit 1
    ;;
esac

if [ -L "build" ] || [ -L "$release_root" ]; then
  echo "Refusing symlinked release output root: $release_root" >&2
  exit 1
fi

mkdir -p "$release_root"
release_root_abs="$(cd "$release_root" && pwd -P)"
expected_release_root="$repo_dir/$release_root"
if [ "$release_root_abs" != "$expected_release_root" ]; then
  echo "Refusing release output root outside repository: $release_root_abs" >&2
  exit 1
fi
OUT_DIR="$release_root_abs/$out_leaf"
OUT_DIR_DISPLAY="$release_root/$out_leaf"

case "$image_abs" in
  "$OUT_DIR"/*)
    echo "Refusing output directory that contains the source image: $OUT_DIR_DISPLAY" >&2
    exit 1
    ;;
esac

repo_commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
dirty="false"
if [ -n "$(git status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  dirty="true"
fi

if [ "$dirty" = "true" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "Refusing to prepare public release assets from a dirty support repository." >&2
  echo "Commit or stash changes first, or pass --allow-dirty for a local test run." >&2
  exit 1
fi

case "$PART_SIZE_BYTES" in
  ''|*[!0-9]*)
    echo "Invalid --part-size-bytes: $PART_SIZE_BYTES" >&2
    exit 2
    ;;
esac
if [ "$PART_SIZE_BYTES" -le 0 ] || [ "$PART_SIZE_BYTES" -ge "$GITHUB_ASSET_LIMIT_BYTES" ]; then
  echo "--part-size-bytes must be greater than 0 and less than $GITHUB_ASSET_LIMIT_BYTES." >&2
  exit 2
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

outline="$OUT_DIR/$OUTLINE_NAME"
if [ "$VALIDATE_IMAGE" = "true" ]; then
  if ! ./scripts/build-sp11-live-usb-image.sh \
    --validate-image "${image_abs#"$repo_dir"/}" >"$outline" 2>&1; then
    echo "Image validation failed. See $OUT_DIR_DISPLAY/$OUTLINE_NAME." >&2
    exit 1
  fi
else
  {
    echo "Image validation was skipped."
    echo "Run:"
    echo "  ./scripts/build-sp11-live-usb-image.sh --validate-image ${image_abs#"$repo_dir"/}"
  } > "$outline"
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
image_size="$(file_size "$image_abs")"
image_sha="$(shasum -a 256 "$image_abs" | awk '{print $1}')"
outline_sha="$(shasum -a 256 "$outline" | awk '{print $1}')"
compressed_tmp="$OUT_DIR/$compressed_base"

zstd -T0 -6 --force -o "$compressed_tmp" "$image_abs"
compressed_size="$(file_size "$compressed_tmp")"
compressed_sha="$(shasum -a 256 "$compressed_tmp" | awk '{print $1}')"

split -b "$PART_SIZE_BYTES" "$compressed_tmp" "$OUT_DIR/$compressed_base.part-"
rm -f "$compressed_tmp"

parts=()
while IFS= read -r part; do
  parts+=("$part")
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "$compressed_base.part-*" | sort)

if [ "${#parts[@]}" -eq 0 ]; then
  echo "No compressed image parts were generated." >&2
  exit 1
fi

for part in "${parts[@]}"; do
  part_size="$(file_size "$part")"
  if [ "$part_size" -ge "$GITHUB_ASSET_LIMIT_BYTES" ]; then
    echo "Compressed part exceeds GitHub asset limit: $(basename "$part") ($part_size bytes)" >&2
    exit 1
  fi
done

{
  echo "# Surface Pro 11 Live Image Release Manifest"
  echo
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Image source: ${image_abs#"$repo_dir"/}"
  echo "Image validation: $VALIDATE_IMAGE"
  echo "Compression: zstd -6"
  echo "Compressed image: $compressed_base"
  echo "Compressed image size: $compressed_size bytes"
  echo "Compressed image SHA256: $compressed_sha"
  echo "Part size limit: $PART_SIZE_BYTES bytes"
  echo
  echo "## Image"
  echo
  echo "- $image_base"
  echo "  - Size: $image_size bytes"
  echo "  - SHA256: $image_sha"
  echo
  echo "## Compressed Parts"
  echo
  for part in "${parts[@]}"; do
    part_base="$(basename "$part")"
    part_size="$(file_size "$part")"
    part_sha="$(shasum -a 256 "$part" | awk '{print $1}')"
    echo "- $part_base"
    echo "  - Size: $part_size bytes"
    echo "  - SHA256: $part_sha"
  done
  echo
  echo "## Image Outline"
  echo
  echo "- $OUTLINE_NAME"
  echo "  - SHA256: $outline_sha"
} > "$OUT_DIR/$MANIFEST_NAME"

(
  cd "$OUT_DIR"
  shasum -a 256 "$compressed_base".part-* "$OUTLINE_NAME" "$MANIFEST_NAME" > SHA256SUMS
)

cat > "$OUT_DIR/RELEASE-NOTES.md" <<RELEASE_NOTES_END
# Surface Pro 11 Live USB Image

Experimental direct-boot Ubuntu live USB raw disk image for Surface Pro 11.

This image is an optional convenience artifact. It is not signed, is not an
installer ISO, and should be written only to the intended removable device.

## Verify

\`\`\`bash
shasum -a 256 -c SHA256SUMS
zstd --version
\`\`\`

The manifest records the expected SHA256 for the reconstructed compressed
archive and the decompressed raw image.

## Reconstruct

\`\`\`bash
cat $compressed_base.part-* > $compressed_base
printf '%s  %s\n' '$compressed_sha' '$compressed_base' | shasum -a 256 -c -
zstd -d --force $compressed_base
printf '%s  %s\n' '$image_sha' '$image_base' | shasum -a 256 -c -
\`\`\`

## Write

\`\`\`bash
sudo dd if=$image_base of=/dev/diskX bs=16M conv=fsync status=progress
\`\`\`

Replace \`/dev/diskX\` with the correct removable disk. Double-check the target
before writing; this command overwrites the destination disk.

## Image Outline

The release includes \`$OUTLINE_NAME\`, generated by:

\`\`\`bash
./scripts/build-sp11-live-usb-image.sh --validate-image $image_base
\`\`\`

\`\`\`text
$(cat "$outline")
\`\`\`

## Provenance

See \`$MANIFEST_NAME\` for image size, checksum, support repository commit, and
validation status. The raw image is intentionally split into compressed parts
because GitHub release assets must be smaller than $GITHUB_ASSET_LIMIT_BYTES
bytes each.

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible.
RELEASE_NOTES_END

release_assets=(
  "$OUTLINE_NAME"
  "$MANIFEST_NAME"
  "SHA256SUMS"
)
for part in "${parts[@]}"; do
  release_assets+=("$(basename "$part")")
done

echo "Prepared release assets in $OUT_DIR_DISPLAY"
echo
echo "Review $OUT_DIR_DISPLAY/RELEASE-NOTES.md, then publish with a command like:"
printf '  (cd %q && gh release create %q --prerelease --title %q --notes-file RELEASE-NOTES.md' \
  "$OUT_DIR_DISPLAY" "$RELEASE_NAME" "$RELEASE_NAME"
for asset in "${release_assets[@]}"; do
  printf ' %q' "$asset"
done
printf ')\n'
