#!/usr/bin/env bash
set -euo pipefail

KERNEL_DEBS_DIR="payload/kernel-debs"
ARTIFACTS_DIR="build/docker-sp11-qcom-x1e-kernel/artifacts"
PATCH_DIR="patches/ubuntu-qcom-x1e-7.0"
OUT_DIR=""
RELEASE_NAME=""
SOURCE_URL="https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute"
SOURCE_BRANCH="qcom-x1e-7.0"
DOCKER_IMAGE=""
ALLOW_DIRTY="false"
ALLOW_MISSING_SOURCE="false"
SOURCE_ASSETS=()
SOURCE_ASSET_COUNT=0

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for optional prebuilt
Surface Pro 11 qcom-x1e kernel packages. It does not publish anything.

Options:
  --kernel-debs-dir DIR   Directory containing built qcom-x1e .debs,
                          default $KERNEL_DEBS_DIR.
  --artifacts-dir DIR     Directory containing local build manifests,
                          default $ARTIFACTS_DIR.
  --patch-dir DIR         Patch directory, default $PATCH_DIR.
  --release-name NAME     Release/tag name. If omitted, derived from package
                          version when possible.
  --out-dir DIR           Output directory. If omitted, defaults to
                          build/release/<release-name>.
  --source-url URL        Upstream kernel source URL recorded in the manifest.
  --source-branch NAME    Upstream kernel source branch recorded in the
                          manifest.
  --docker-image IMAGE    Docker image family/digest recorded in the manifest.
                          If omitted, derived from source mode.
  --source-asset PATH     Corresponding source artifact to copy into the
                          release directory. Can be repeated.
  --allow-dirty           Allow preparing assets when the support repository has
                          uncommitted changes. Intended for local test runs.
  --allow-missing-source  Allow a local draft without source artifacts. The
                          helper will not print a publish command in this mode.
  -h, --help              Show this help.
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel-debs-dir)
      require_arg "$1" "${2:-}"
      KERNEL_DEBS_DIR="$2"
      shift 2
      ;;
    --artifacts-dir)
      require_arg "$1" "${2:-}"
      ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --patch-dir)
      require_arg "$1" "${2:-}"
      PATCH_DIR="$2"
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
    --source-url)
      require_arg "$1" "${2:-}"
      SOURCE_URL="$2"
      shift 2
      ;;
    --source-branch)
      require_arg "$1" "${2:-}"
      SOURCE_BRANCH="$2"
      shift 2
      ;;
    --docker-image)
      require_arg "$1" "${2:-}"
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    --source-asset)
      require_arg "$1" "${2:-}"
      SOURCE_ASSETS+=("$2")
      SOURCE_ASSET_COUNT=$((SOURCE_ASSET_COUNT + 1))
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY="true"
      shift
      ;;
    --allow-missing-source)
      ALLOW_MISSING_SOURCE="true"
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
require_tool stat

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

if [ ! -d "$KERNEL_DEBS_DIR" ]; then
  echo "Kernel deb directory not found: $KERNEL_DEBS_DIR" >&2
  exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
  echo "Patch directory not found: $PATCH_DIR" >&2
  exit 1
fi

debs=()
while IFS= read -r deb; do
  debs+=("$deb")
done < <(find "$KERNEL_DEBS_DIR" -maxdepth 1 -type f -name '*.deb' | sort)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "No .deb files found under $KERNEL_DEBS_DIR." >&2
  exit 1
fi

kernel_abi=""
package_version=""
seen_headers="false"
seen_image="false"
seen_modules="false"

for deb in "${debs[@]}"; do
  base="$(basename "$deb")"
  role=""
  case "$base" in
    linux-headers-*_arm64.deb) role="headers" ;;
    linux-image-*_arm64.deb) role="image" ;;
    linux-modules-*_arm64.deb) role="modules" ;;
    *)
      echo "Unexpected kernel package filename: $base" >&2
      echo "Expected linux-{headers,image,modules}-<abi>_<version>_arm64.deb." >&2
      exit 1
      ;;
  esac

  without_arch="${base%_arm64.deb}"
  deb_version="${without_arch##*_}"
  deb_abi="${without_arch#linux-$role-}"
  deb_abi="${deb_abi%_$deb_version}"

  if [ -z "$deb_abi" ] || [ -z "$deb_version" ]; then
    echo "Could not parse kernel ABI/version from $base." >&2
    exit 1
  fi

  if [ -z "$kernel_abi" ]; then
    kernel_abi="$deb_abi"
  elif [ "$kernel_abi" != "$deb_abi" ]; then
    echo "Mixed kernel ABIs in $KERNEL_DEBS_DIR: $kernel_abi and $deb_abi." >&2
    exit 1
  fi

  if [ -z "$package_version" ]; then
    package_version="$deb_version"
  elif [ "$package_version" != "$deb_version" ]; then
    echo "Mixed package versions in $KERNEL_DEBS_DIR: $package_version and $deb_version." >&2
    exit 1
  fi

  case "$role" in
    headers)
      if [ "$seen_headers" = "true" ]; then
        echo "Duplicate linux-headers package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_headers="true"
      ;;
    image)
      if [ "$seen_image" = "true" ]; then
        echo "Duplicate linux-image package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_image="true"
      ;;
    modules)
      if [ "$seen_modules" = "true" ]; then
        echo "Duplicate linux-modules package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_modules="true"
      ;;
  esac
done

if [ "$seen_headers" != "true" ] || [ "$seen_image" != "true" ] || [ "$seen_modules" != "true" ]; then
  echo "Expected exactly one linux-headers, linux-image, and linux-modules package." >&2
  exit 1
fi

version_deb="${debs[0]}"
for deb in "${debs[@]}"; do
  case "$(basename "$deb")" in
    linux-image-*)
      version_deb="$deb"
      break
      ;;
  esac
done

version="$(
  basename "$version_deb" |
    sed -n 's/^linux-[^-]*-\(.*\)_\([^_]*\)_arm64\.deb$/\1-\2/p' |
    head -n 1
)"
if [ -z "$version" ]; then
  version="kernel"
fi

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="sp11-qcom-x1e-${version}-rfkill1"
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="build/release/$RELEASE_NAME"
fi

release_root="build/release"
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

build_manifest="$ARTIFACTS_DIR/sp11-kernel-build-manifest.txt"
source_mode=""
source_head=""
build_target=""
jobs=""
rules_runner=""

if [ -f "$build_manifest" ]; then
  source_mode="$(awk -F': ' '$1 == "Source mode" { print $2; exit }' "$build_manifest")"
  source_head="$(awk -F': ' '$1 == "Source HEAD" { print $2; exit }' "$build_manifest")"
  build_target="$(awk -F': ' '$1 == "Build target" { print $2; exit }' "$build_manifest")"
  jobs="$(awk -F': ' '$1 == "Jobs" { print $2; exit }' "$build_manifest")"
  rules_runner="$(awk -F': ' '$1 == "Rules runner" { print $2; exit }' "$build_manifest")"
fi

repo_commit="$(git rev-parse HEAD)"
dirty="false"
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  dirty="true"
fi

if [ "$dirty" = "true" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "Refusing to prepare public release assets from a dirty support repository." >&2
  echo "Commit or stash changes first, or pass --allow-dirty for a local test run." >&2
  exit 1
fi

if [ -z "$DOCKER_IMAGE" ]; then
  case "$source_mode" in
    git) DOCKER_IMAGE="ubuntu:25.10" ;;
    *) DOCKER_IMAGE="ubuntu:26.04" ;;
  esac
fi

if [ "$SOURCE_ASSET_COUNT" -eq 0 ] && [ "$ALLOW_MISSING_SOURCE" != "true" ]; then
  echo "Refusing to prepare publishable kernel assets without corresponding source." >&2
  echo "Pass --source-asset PATH for source package artifacts or a patched source archive." >&2
  echo "For a local draft only, pass --allow-missing-source." >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    if [ ! -f "$source_asset" ]; then
      echo "Source asset not found: $source_asset" >&2
      exit 1
    fi
  done
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

for deb in "${debs[@]}"; do
  cp "$deb" "$OUT_DIR/"
done

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    cp "$source_asset" "$OUT_DIR/"
  done
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
  echo "# Surface Pro 11 qcom-x1e Kernel Release Manifest"
  echo
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Source mode: ${source_mode:-unknown}"
  echo "Source URL: ${SOURCE_URL:-unknown}"
  echo "Source branch: ${SOURCE_BRANCH:-unknown}"
  echo "Source HEAD: ${source_head:-unknown}"
  echo "Docker image: $DOCKER_IMAGE"
  echo "Build target: ${build_target:-unknown}"
  echo "Jobs: ${jobs:-unknown}"
  echo "Rules runner: ${rules_runner:-unknown}"
  echo
  echo "## Packages"
  echo
  for deb in "${debs[@]}"; do
    base="$(basename "$deb")"
    size="$(stat -f '%z' "$deb" 2>/dev/null || stat -c '%s' "$deb")"
    sha="$(shasum -a 256 "$deb" | awk '{print $1}')"
    echo "- $base"
    echo "  - Size: $size bytes"
    echo "  - SHA256: $sha"
  done
  echo
  echo "## Source Assets"
  echo
  if [ "$SOURCE_ASSET_COUNT" -eq 0 ]; then
    echo "No source assets included. This manifest is for a local draft only."
  else
    for source_asset in "${SOURCE_ASSETS[@]}"; do
      base="$(basename "$source_asset")"
      size="$(stat -f '%z' "$source_asset" 2>/dev/null || stat -c '%s' "$source_asset")"
      sha="$(shasum -a 256 "$source_asset" | awk '{print $1}')"
      echo "- $base"
      echo "  - Size: $size bytes"
      echo "  - SHA256: $sha"
    done
  fi
  echo
  echo "## Patches"
  echo
  find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort | while IFS= read -r patch; do
    base="$(basename "$patch")"
    sha="$(shasum -a 256 "$patch" | awk '{print $1}')"
    echo "- $base"
    echo "  - SHA256: $sha"
  done
} > "$OUT_DIR/sp11-kernel-release-manifest.txt"

for deb in "${debs[@]}"; do
  basename "$deb"
done > "$OUT_DIR/sp11-kernel-debs.txt"

(
  cd "$OUT_DIR"
  shasum -a 256 ./* > SHA256SUMS
)

cat > "$OUT_DIR/RELEASE-NOTES.md" <<EOF
# Surface Pro 11 qcom-x1e Kernel Packages

Experimental prebuilt qcom-x1e kernel packages for Surface Pro 11 Wi-Fi rfkill
bring-up.

These packages are optional convenience artifacts. They are unsigned, are not
an apt repository, and should be used only with a known-good fallback qcom-x1e
kernel still installed.

## Verify

\`\`\`bash
shasum -a 256 -c SHA256SUMS
\`\`\`

## Install Flow

1. Download the \`.deb\` files and \`SHA256SUMS\`.
2. Verify checksums.
3. Copy the \`.deb\` files into local \`payload/kernel-debs/\`.
4. Rebuild and write the Surface Pro 11 USB image.
5. On the Surface, install using:

\`\`\`bash
sudo ./scripts/build-sp11-qcom-x1e-kernel.sh \\
  --work-dir "\$SP11DATA/payload/kernel-debs" \\
  --install-only
\`\`\`

## Provenance

See \`sp11-kernel-release-manifest.txt\` for package hashes, source metadata,
support repository commit, and patch checksums.

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible.
EOF

echo "Prepared release assets in $OUT_DIR_DISPLAY"
echo
if [ "$SOURCE_ASSET_COUNT" -eq 0 ]; then
  echo "No source assets were included, so this is a local draft only."
  echo "Rerun with --source-asset before publishing binaries."
else
  release_assets=()
  for deb in "${debs[@]}"; do
    release_assets+=("$(basename "$deb")")
  done
  release_assets+=(
    "SHA256SUMS"
    "sp11-kernel-release-manifest.txt"
    "sp11-kernel-debs.txt"
  )
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    release_assets+=("$(basename "$source_asset")")
  done

  echo "Review $OUT_DIR_DISPLAY/RELEASE-NOTES.md, then publish with a command like:"
  printf '  (cd %q && gh release create %q --prerelease --title %q --notes-file RELEASE-NOTES.md' \
    "$OUT_DIR_DISPLAY" "$RELEASE_NAME" "$RELEASE_NAME"
  for asset in "${release_assets[@]}"; do
    printf ' %q' "$asset"
  done
  printf ')\n'
fi
