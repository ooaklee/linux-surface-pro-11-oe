#!/usr/bin/env bash
set -euo pipefail

KERNEL_DEBS_DIR="payload/kernel-debs"
ARTIFACTS_DIR="build/docker-sp11-qcom-x1e-kernel/artifacts"
PATCH_DIRS=()
PATCH_DIR_COUNT=0
OUT_DIR=""
RELEASE_NAME=""
SOURCE_URL="https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute"
SOURCE_BRANCH="qcom-x1e-7.0"
SOURCE_URL_EXPLICIT="false"
SOURCE_BRANCH_EXPLICIT="false"
DOCKER_IMAGE=""
ALLOW_DIRTY="false"
ALLOW_MISSING_SOURCE="false"
SOURCE_ASSETS=()
SOURCE_ASSET_COUNT=0
TOUCHSCREEN_MODULES_DIR=""
TOUCHSCREEN_SOURCE_URL=""
TOUCHSCREEN_SOURCE_REF=""
TOUCHSCREEN_ENABLED="false"
TOUCHSCREEN_MODULE_FILES=(
  "gpi.ko"
  "spi-geni-qcom.ko"
  "mshw0485_touch.ko"
)
TOUCHSCREEN_MODULE_MANIFEST="sp11-touchscreen-modules-manifest.txt"

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
  --patch-dir DIR         Patch directory. Repeat to record ordered patch sets.
                          If omitted, records that no local patches were used.
  --release-name NAME     Release/tag name. If omitted, derived from package
                          version when possible.
  --out-dir DIR           Output directory. If omitted, defaults to
                          build/release/<release-name>.
  --source-url URL        Upstream kernel source URL recorded in the manifest.
  --source-branch NAME    Upstream kernel source branch or tag recorded in the
                          manifest.
  --docker-image IMAGE    Docker image family/digest recorded in the manifest.
                          If omitted, derived from source mode.
  --source-asset PATH     Corresponding source artifact to copy into the
                          release directory. Can be repeated.
  --touchscreen-modules-dir DIR
                          Optional directory containing gpi.ko,
                          spi-geni-qcom.ko, and mshw0485_touch.ko, plus the
                          build manifest when produced by the build helper.
  --touchscreen-source-url URL
                          Source repository URL for the touchscreen modules.
                          Required with --touchscreen-modules-dir.
  --touchscreen-source-ref COMMIT
                          Immutable 40- or 64-character source commit for the
                          touchscreen modules. Required with their directory.
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

file_size() {
  local path="$1"
  local size=""

  if size="$(stat -c '%s' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  elif size="$(stat -f '%z' "$path" 2>/dev/null)"; then
    printf '%s\n' "$size"
  else
    echo "Could not determine file size: $path" >&2
    return 1
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
      PATCH_DIRS+=("$2")
      PATCH_DIR_COUNT=$((PATCH_DIR_COUNT + 1))
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
      SOURCE_URL_EXPLICIT="true"
      shift 2
      ;;
    --source-branch)
      require_arg "$1" "${2:-}"
      SOURCE_BRANCH="$2"
      SOURCE_BRANCH_EXPLICIT="true"
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
    --touchscreen-modules-dir)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_MODULES_DIR="$2"
      shift 2
      ;;
    --touchscreen-source-url)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_SOURCE_URL="$2"
      shift 2
      ;;
    --touchscreen-source-ref)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_SOURCE_REF="$2"
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

if [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
  TOUCHSCREEN_ENABLED="true"
  require_tool grep
  require_tool modinfo

  if [ -z "$TOUCHSCREEN_SOURCE_URL" ] || [ -z "$TOUCHSCREEN_SOURCE_REF" ]; then
    echo "--touchscreen-modules-dir requires --touchscreen-source-url and --touchscreen-source-ref." >&2
    exit 2
  fi

  if [[ ! "$TOUCHSCREEN_SOURCE_REF" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
    echo "Touchscreen source ref must be an immutable 40- or 64-character hexadecimal commit." >&2
    exit 2
  fi
  TOUCHSCREEN_SOURCE_REF="${TOUCHSCREEN_SOURCE_REF,,}"
elif [ -n "$TOUCHSCREEN_SOURCE_URL" ] || [ -n "$TOUCHSCREEN_SOURCE_REF" ]; then
  echo "--touchscreen-source-url and --touchscreen-source-ref require --touchscreen-modules-dir." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

if [ ! -d "$KERNEL_DEBS_DIR" ]; then
  echo "Kernel deb directory not found: $KERNEL_DEBS_DIR" >&2
  exit 1
fi

if [ "$PATCH_DIR_COUNT" -gt 0 ]; then
  for patch_dir in "${PATCH_DIRS[@]}"; do
    if [ ! -d "$patch_dir" ]; then
      echo "Patch directory not found: $patch_dir" >&2
      exit 1
    fi
  done
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
seen_common_headers="false"
seen_image="false"
seen_modules="false"

for deb in "${debs[@]}"; do
  base="$(basename "$deb")"
  role=""
  case "$base" in
    linux-qcom-x1e-headers-*_all.deb) role="common_headers" ;;
    linux-headers-*_arm64.deb) role="headers" ;;
    linux-image-*_arm64.deb) role="image" ;;
    linux-modules-*_arm64.deb) role="modules" ;;
    *)
      echo "Unexpected kernel package filename: $base" >&2
      echo "Expected linux-{headers,image,modules}-<abi>_<version>_arm64.deb or linux-qcom-x1e-headers-<version>_<version>_all.deb." >&2
      exit 1
      ;;
  esac

  case "$role" in
    common_headers)
      without_arch="${base%_all.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-qcom-x1e-headers-}"
      deb_abi="${deb_abi%_$deb_version}-qcom-x1e"
      ;;
    *)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-$role-}"
      deb_abi="${deb_abi%_$deb_version}"
      ;;
  esac

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
    common_headers)
      if [ "$seen_common_headers" = "true" ]; then
        echo "Duplicate linux-qcom-x1e-headers package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_common_headers="true"
      ;;
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

case "$kernel_abi" in
  *sp11v3*-qcom-x1e)
    if [ "$TOUCHSCREEN_ENABLED" != "true" ]; then
      echo "Refusing an incomplete $kernel_abi release without its three touchscreen modules." >&2
      echo "Pass --touchscreen-modules-dir and immutable touchscreen source provenance." >&2
      exit 1
    fi
    ;;
esac

declare -A touchscreen_module_names=()
declare -A touchscreen_module_vermagic=()
declare -A touchscreen_module_srcversions=()
declare -A touchscreen_module_sizes=()
declare -A touchscreen_module_shas=()

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  if [ ! -d "$TOUCHSCREEN_MODULES_DIR" ] || [ -L "$TOUCHSCREEN_MODULES_DIR" ]; then
    echo "Touchscreen modules directory not found or is a symlink: $TOUCHSCREEN_MODULES_DIR" >&2
    exit 1
  fi

  touchscreen_entries=()
  while IFS= read -r entry; do
    [ "$entry" = "$TOUCHSCREEN_MODULE_MANIFEST" ] && continue
    touchscreen_entries+=("$entry")
  done < <(find "$TOUCHSCREEN_MODULES_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)

  expected_touchscreen_entries="$(printf '%s\n' "${TOUCHSCREEN_MODULE_FILES[@]}" | sort)"
  actual_touchscreen_entries="$(printf '%s\n' "${touchscreen_entries[@]}" | sort)"
  if [ "${#touchscreen_entries[@]}" -ne "${#TOUCHSCREEN_MODULE_FILES[@]}" ] || \
     [ "$actual_touchscreen_entries" != "$expected_touchscreen_entries" ]; then
    echo "Touchscreen modules directory must contain exactly: ${TOUCHSCREEN_MODULE_FILES[*]}" >&2
    exit 1
  fi

  input_touchscreen_manifest="$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_MODULE_MANIFEST"
  if [ -f "$input_touchscreen_manifest" ]; then
    input_source_url="$(awk -F': ' '$1 == "Source URL" { print $2; exit }' "$input_touchscreen_manifest")"
    input_source_commit="$(awk -F': ' '$1 == "Source commit" { print $2; exit }' "$input_touchscreen_manifest")"
    input_target_release="$(awk -F': ' '$1 == "Target release" { print $2; exit }' "$input_touchscreen_manifest")"
    [ "$input_source_url" = "$TOUCHSCREEN_SOURCE_URL" ] || {
      echo "Touchscreen build manifest source URL does not match --touchscreen-source-url." >&2
      exit 1
    }
    [ "$input_source_commit" = "$TOUCHSCREEN_SOURCE_REF" ] || {
      echo "Touchscreen build manifest source commit does not match --touchscreen-source-ref." >&2
      exit 1
    }
    [ "$input_target_release" = "$kernel_abi" ] || {
      echo "Touchscreen build manifest targets $input_target_release, expected $kernel_abi." >&2
      exit 1
    }
  elif [ -e "$input_touchscreen_manifest" ]; then
    echo "Touchscreen build manifest is not a regular file: $input_touchscreen_manifest" >&2
    exit 1
  fi

  common_touchscreen_vermagic_abi=""
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    module_path="$TOUCHSCREEN_MODULES_DIR/$module_file"
    if [ ! -f "$module_path" ] || [ -L "$module_path" ]; then
      echo "Touchscreen module must be a regular, non-symlinked file: $module_path" >&2
      exit 1
    fi

    case "$module_file" in
      gpi.ko) expected_module_name="gpi" ;;
      spi-geni-qcom.ko) expected_module_name="spi_geni_qcom" ;;
      mshw0485_touch.ko) expected_module_name="mshw0485_touch" ;;
    esac

    if ! module_name="$(modinfo -F name "$module_path")"; then
      echo "Could not read module name from $module_path." >&2
      exit 1
    fi
    if [ "$module_name" != "$expected_module_name" ]; then
      echo "Unexpected module name in $module_file: $module_name (expected $expected_module_name)." >&2
      exit 1
    fi

    if ! module_vermagic="$(modinfo -F vermagic "$module_path")"; then
      echo "Could not read vermagic from $module_path." >&2
      exit 1
    fi
    module_vermagic_abi="${module_vermagic%% *}"
    if [ -z "$module_vermagic" ] || [ "$module_vermagic_abi" != "$kernel_abi" ]; then
      echo "Module $module_file targets ${module_vermagic_abi:-unknown}, expected kernel ABI $kernel_abi." >&2
      exit 1
    fi
    if [ -z "$common_touchscreen_vermagic_abi" ]; then
      common_touchscreen_vermagic_abi="$module_vermagic_abi"
    elif [ "$module_vermagic_abi" != "$common_touchscreen_vermagic_abi" ]; then
      echo "Touchscreen modules do not share a common vermagic ABI." >&2
      exit 1
    fi

    if ! module_srcversion="$(modinfo -F srcversion "$module_path")"; then
      echo "Could not read srcversion from $module_path." >&2
      exit 1
    fi
    if [[ ! "$module_srcversion" =~ ^[0-9A-Fa-f]+$ ]]; then
      echo "Module $module_file has a missing or invalid srcversion." >&2
      exit 1
    fi

    touchscreen_module_names["$module_file"]="$module_name"
    touchscreen_module_vermagic["$module_file"]="$module_vermagic"
    touchscreen_module_srcversions["$module_file"]="$module_srcversion"
    touchscreen_module_sizes["$module_file"]="$(file_size "$module_path")"
    touchscreen_module_shas["$module_file"]="$(shasum -a 256 "$module_path" | awk '{print $1}')"
  done

  if ! spi_parameters="$(modinfo -p "$TOUCHSCREEN_MODULES_DIR/spi-geni-qcom.ko")"; then
    echo "Could not read parameters from spi-geni-qcom.ko." >&2
    exit 1
  fi
  if ! grep -q '^sp11_windows_se_init:' <<<"$spi_parameters"; then
    echo "spi-geni-qcom.ko is missing the required sp11_windows_se_init parameter." >&2
    exit 1
  fi

  if ! modinfo -F alias "$TOUCHSCREEN_MODULES_DIR/mshw0485_touch.ko" |
       grep -q 'microsoft,mshw0485'; then
    echo "mshw0485_touch.ko is missing the microsoft,mshw0485 device-tree alias." >&2
    exit 1
  fi
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
  if [ "$PATCH_DIR_COUNT" -eq 0 ]; then
    RELEASE_NAME="sp11-qcom-x1e-${version}-baseline1"
  else
    RELEASE_NAME="sp11-qcom-x1e-${version}-rfkill1"
  fi
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
manifest_source_url=""
manifest_source_ref=""
apt_source_spec=""
manifest_patch_dirs=""
manifest_patch_dir_records="0"
manifest_local_patches=""
manifest_local_patch_records="0"
build_target=""
jobs=""
rules_runner=""

if [ -f "$build_manifest" ]; then
  source_mode="$(awk -F': ' '$1 == "Source mode" { print $2; exit }' "$build_manifest")"
  source_head="$(awk -F': ' '$1 == "Source HEAD" { print $2; exit }' "$build_manifest")"
  manifest_source_url="$(awk -F': ' '$1 == "Source URL" { print $2; exit }' "$build_manifest")"
  manifest_source_ref="$(awk -F': ' '$1 == "Source ref" { print $2; exit }' "$build_manifest")"
  apt_source_spec="$(awk -F': ' '$1 == "Apt source spec" { print $2; exit }' "$build_manifest")"
  manifest_patch_dirs="$(awk -F': ' '$1 == "Patch directories" || $1 == "Patch directory" { print $2; exit }' "$build_manifest")"
  manifest_patch_dir_records="$(awk -F': ' '$1 == "Patch directories" || $1 == "Patch directory" { count++ } END { print count + 0 }' "$build_manifest")"
  manifest_local_patches="$(awk -F': ' '$1 == "Local patches" { print $2; exit }' "$build_manifest")"
  manifest_local_patch_records="$(awk -F': ' '$1 == "Local patches" { count++ } END { print count + 0 }' "$build_manifest")"
  build_target="$(awk -F': ' '$1 == "Build target" { print $2; exit }' "$build_manifest")"
  jobs="$(awk -F': ' '$1 == "Jobs" { print $2; exit }' "$build_manifest")"
  rules_runner="$(awk -F': ' '$1 == "Rules runner" { print $2; exit }' "$build_manifest")"
fi

if [ "$SOURCE_URL_EXPLICIT" != "true" ] && [ -n "$manifest_source_url" ]; then
  SOURCE_URL="$manifest_source_url"
fi
if [ "$SOURCE_BRANCH_EXPLICIT" != "true" ] && [ -n "$manifest_source_ref" ]; then
  SOURCE_BRANCH="$manifest_source_ref"
fi

if [ -n "$manifest_source_url" ] && [ "$SOURCE_URL" != "$manifest_source_url" ]; then
  echo "--source-url does not match the URL recorded by the build manifest." >&2
  exit 1
fi
if [ -n "$manifest_source_ref" ] && [ "$SOURCE_BRANCH" != "$manifest_source_ref" ]; then
  echo "--source-branch does not match the ref recorded by the build manifest." >&2
  exit 1
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

if ! git check-ref-format "refs/tags/$RELEASE_NAME" >/dev/null 2>&1; then
  echo "Release name is not a valid Git tag: $RELEASE_NAME" >&2
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
  echo "Pass --source-asset PATH for source package artifacts or a corresponding source archive." >&2
  echo "For a local draft only, pass --allow-missing-source." >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    if [ ! -f "$source_asset" ] || [ -L "$source_asset" ]; then
      echo "Source asset must be a regular, non-symlinked file: $source_asset" >&2
      exit 1
    fi
  done
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if [ ! -f "$build_manifest" ] || [ -L "$build_manifest" ]; then
    echo "Refusing publishable assets without a kernel build manifest: $build_manifest" >&2
    echo "Pass --artifacts-dir for the exact build being released." >&2
    exit 1
  fi

  case "$source_mode" in
    git)
      if [[ ! "$source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
        echo "Git build manifest has a missing or invalid immutable Source HEAD." >&2
        exit 1
      fi
      if [ -z "$manifest_source_url" ] && [ "$SOURCE_URL_EXPLICIT" != "true" ]; then
        echo "Git build manifest has no Source URL; pass --source-url explicitly." >&2
        exit 1
      fi
      if [ -z "$manifest_source_ref" ] && [ "$SOURCE_BRANCH_EXPLICIT" != "true" ]; then
        echo "Git build manifest has no Source ref; pass --source-branch explicitly." >&2
        exit 1
      fi
      ;;
    apt)
      if [ -z "$apt_source_spec" ]; then
        echo "Apt build manifest has no exact Apt source spec." >&2
        exit 1
      fi
      ;;
    *)
      echo "Build manifest has a missing or unsupported Source mode: ${source_mode:-unknown}" >&2
      exit 1
      ;;
  esac

  for required_build_field in "$build_target" "$jobs" "$rules_runner"; do
    if [ -z "$required_build_field" ] || [ "$required_build_field" = "unknown" ]; then
      echo "Build manifest is missing target, jobs, or rules-runner provenance." >&2
      exit 1
    fi
  done

  if [ "$manifest_patch_dir_records" -gt 1 ] || [ "$manifest_local_patch_records" -gt 1 ]; then
    echo "Build manifest contains duplicate local-patch provenance records." >&2
    exit 1
  fi

  if [ "$manifest_patch_dir_records" -gt 0 ] && [ "$manifest_local_patch_records" -gt 0 ]; then
    echo "Build manifest contradicts itself by recording both patch directories and Local patches." >&2
    exit 1
  fi

  if [ "$manifest_patch_dir_records" -gt 0 ]; then
    if [ -z "$manifest_patch_dirs" ]; then
      echo "Build manifest records an empty patch directory list." >&2
      exit 1
    fi
    if [ "$PATCH_DIR_COUNT" -eq 0 ]; then
      echo "Build manifest records patch directories, but no --patch-dir was supplied for the release." >&2
      exit 1
    fi

    manifest_patch_basenames=()
    for manifest_patch_dir in $manifest_patch_dirs; do
      manifest_patch_basenames+=("$(basename "$manifest_patch_dir")")
    done
    release_patch_basenames=()
    for patch_dir in "${PATCH_DIRS[@]}"; do
      release_patch_basenames+=("$(basename "$patch_dir")")
    done
    if [ "${manifest_patch_basenames[*]}" != "${release_patch_basenames[*]}" ]; then
      echo "Release patch directories do not match the ordered build manifest patch directories." >&2
      echo "Build: ${manifest_patch_basenames[*]}" >&2
      echo "Release: ${release_patch_basenames[*]}" >&2
      exit 1
    fi
  elif [ "$manifest_local_patch_records" -gt 0 ]; then
    if [ "$manifest_local_patches" != "none" ]; then
      echo "Build manifest has an unsupported Local patches value: ${manifest_local_patches:-empty}." >&2
      exit 1
    fi
    if [ "$PATCH_DIR_COUNT" -ne 0 ]; then
      echo "Build manifest records no local patches, but --patch-dir was supplied for the release." >&2
      exit 1
    fi
  else
    echo "Build manifest does not record patch directories or exact 'Local patches: none' provenance." >&2
    exit 1
  fi
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if git show-ref --verify --quiet "refs/tags/$RELEASE_NAME"; then
    local_tag_commit="$(git rev-parse "refs/tags/$RELEASE_NAME^{commit}")"
    if [ "$local_tag_commit" != "$repo_commit" ]; then
      echo "Refusing release: local tag $RELEASE_NAME points to $local_tag_commit, not support repo HEAD $repo_commit." >&2
      exit 1
    fi
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    remote_tag_output=""
    remote_tag_status=0
    remote_tag_output="$(
      git ls-remote --exit-code --tags origin \
        "refs/tags/$RELEASE_NAME" "refs/tags/$RELEASE_NAME^{}" 2>/dev/null
    )" || remote_tag_status=$?

    if [ "$remote_tag_status" -eq 0 ]; then
      remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
      if [ -z "$remote_tag_commit" ]; then
        remote_tag_commit="$(printf '%s\n' "$remote_tag_output" | awk 'NF >= 2 { print $1; exit }')"
      fi
      if [ -n "$remote_tag_commit" ] && [ "$remote_tag_commit" != "$repo_commit" ]; then
        echo "Refusing release: remote tag $RELEASE_NAME points to $remote_tag_commit, not support repo HEAD $repo_commit." >&2
        exit 1
      fi
    elif [ "$remote_tag_status" -ne 2 ]; then
      echo "Refusing a publishable release because remote tag $RELEASE_NAME could not be checked on origin." >&2
      echo "Restore remote access and rerun so an existing tag cannot be reused accidentally." >&2
      exit 1
    fi
  fi
fi

upload_assets=()
declare -A claimed_output_names=()

claim_output_name() {
  local name="$1"
  local origin="$2"

  if [ -n "${claimed_output_names[$name]+x}" ]; then
    echo "Refusing colliding release asset name $name from $origin; already used by ${claimed_output_names[$name]}." >&2
    exit 1
  fi
  claimed_output_names["$name"]="$origin"
}

append_upload_asset() {
  local name="$1"
  local origin="$2"

  claim_output_name "$name" "$origin"
  upload_assets+=("$name")
}

claim_output_name "SHA256SUMS" "generated checksum file"
claim_output_name "RELEASE-NOTES.md" "generated release notes"

for deb in "${debs[@]}"; do
  append_upload_asset "$(basename "$deb")" "$deb"
done

for source_asset in "${SOURCE_ASSETS[@]}"; do
  append_upload_asset "$(basename "$source_asset")" "$source_asset"
done

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    append_upload_asset "$module_file" "$TOUCHSCREEN_MODULES_DIR/$module_file"
  done
  append_upload_asset "$TOUCHSCREEN_MODULE_MANIFEST" "generated touchscreen module manifest"
fi

append_upload_asset "sp11-kernel-release-manifest.txt" "generated kernel release manifest"
append_upload_asset "sp11-kernel-debs.txt" "generated kernel package list"

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

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    cp "$TOUCHSCREEN_MODULES_DIR/$module_file" "$OUT_DIR/"
  done
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  {
    echo "# Surface Pro 11 Touchscreen Module Provenance"
    echo
    echo "Generated: $generated_at"
    echo "Release: $RELEASE_NAME"
    echo "Kernel ABI: $kernel_abi"
    echo "Touchscreen source URL: $TOUCHSCREEN_SOURCE_URL"
    echo "Touchscreen source commit: $TOUCHSCREEN_SOURCE_REF"
    echo "Support repo commit: $repo_commit"
    echo "Support repo dirty: $dirty"
    echo "Required SPI parameter: sp11_windows_se_init"
    echo
    echo "## Modules"
    echo
    for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
      echo "- $module_file"
      echo "  - Module name: ${touchscreen_module_names[$module_file]}"
      echo "  - Size: ${touchscreen_module_sizes[$module_file]} bytes"
      echo "  - SHA256: ${touchscreen_module_shas[$module_file]}"
      echo "  - Vermagic: ${touchscreen_module_vermagic[$module_file]}"
      echo "  - Srcversion: ${touchscreen_module_srcversions[$module_file]}"
    done
  } > "$OUT_DIR/$TOUCHSCREEN_MODULE_MANIFEST"
fi

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
  if [ "$source_mode" = "apt" ]; then
    echo "Apt source spec: ${apt_source_spec:-unknown}"
  fi
  echo "Docker image: $DOCKER_IMAGE"
  echo "Build target: ${build_target:-unknown}"
  echo "Jobs: ${jobs:-unknown}"
  echo "Rules runner: ${rules_runner:-unknown}"
  echo
  echo "## Packages"
  echo
  for deb in "${debs[@]}"; do
    base="$(basename "$deb")"
    size="$(file_size "$deb")"
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
      size="$(file_size "$source_asset")"
      sha="$(shasum -a 256 "$source_asset" | awk '{print $1}')"
      echo "- $base"
      echo "  - Size: $size bytes"
      echo "  - SHA256: $sha"
    done
  fi
  echo
  echo "## Touchscreen Modules"
  echo
  if [ "$TOUCHSCREEN_ENABLED" != "true" ]; then
    echo "No touchscreen module bundle included."
  else
    echo "- Provenance manifest: $TOUCHSCREEN_MODULE_MANIFEST"
    echo "- Kernel ABI: $kernel_abi"
    echo "- Source URL: $TOUCHSCREEN_SOURCE_URL"
    echo "- Source commit: $TOUCHSCREEN_SOURCE_REF"
    echo "- Required SPI parameter: sp11_windows_se_init"
    echo
    for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
      echo "- $module_file"
      echo "  - Module name: ${touchscreen_module_names[$module_file]}"
      echo "  - Size: ${touchscreen_module_sizes[$module_file]} bytes"
      echo "  - SHA256: ${touchscreen_module_shas[$module_file]}"
      echo "  - Vermagic: ${touchscreen_module_vermagic[$module_file]}"
      echo "  - Srcversion: ${touchscreen_module_srcversions[$module_file]}"
    done
  fi
  echo
  echo "## Patches"
  echo
  if [ "$PATCH_DIR_COUNT" -eq 0 ]; then
    echo "Local patches: none"
  else
    for patch_dir in "${PATCH_DIRS[@]}"; do
      find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort | while IFS= read -r patch; do
        base="$(basename "$patch")"
        sha="$(shasum -a 256 "$patch" | awk '{print $1}')"
        echo "- $patch_dir/$base"
        echo "  - SHA256: $sha"
      done
    done
  fi
} > "$OUT_DIR/sp11-kernel-release-manifest.txt"

for deb in "${debs[@]}"; do
  basename "$deb"
done > "$OUT_DIR/sp11-kernel-debs.txt"

cat > "$OUT_DIR/RELEASE-NOTES.md" <<EOF
# Surface Pro 11 qcom-x1e Kernel Packages

Experimental prebuilt qcom-x1e kernel packages for Surface Pro 11.

These artifacts are optional conveniences. They are unsigned, are not an apt
repository, and should be used only with a known-good fallback qcom-x1e kernel
still installed.

## Verify

Download \`SHA256SUMS\` and every asset named in it, then run:

\`\`\`bash
(cd /path/to/downloaded-release-assets && shasum -a 256 -c SHA256SUMS)
\`\`\`

EOF

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  cat >> "$OUT_DIR/RELEASE-NOTES.md" <<EOF
## Install Flow

The kernel packages and touchscreen modules are one ABI-matched set. Install
both from the same downloaded asset directory, and keep the fallback kernel
until the new kernel and touchscreen have both been tested.

\`\`\`bash
ASSET_DIR=/absolute/path/to/downloaded-release-assets
cd /path/to/linux-surface-pro-11-oe

sudo ./scripts/build-sp11-qcom-x1e-kernel.sh \\
  --work-dir "\$ASSET_DIR" \\
  --install-only
\`\`\`

The unified installer finds the three modules beside the packages and installs
them for \`$kernel_abi\`. It refuses an incomplete sp11v3 transaction rather
than silently installing a kernel whose touchscreen cannot initialize. Reboot
after it completes, then test both the new kernel and touchscreen.

EOF
else
  cat >> "$OUT_DIR/RELEASE-NOTES.md" <<EOF
## Install Flow

1. Copy the verified \`.deb\` files into local \`payload/kernel-debs/\`.
2. Rebuild and write the Surface Pro 11 USB image.
3. On the Surface, install using:

\`\`\`bash
sudo ./scripts/build-sp11-qcom-x1e-kernel.sh \\
  --work-dir "\$SP11DATA/payload/kernel-debs" \\
  --install-only
\`\`\`

EOF
fi

cat >> "$OUT_DIR/RELEASE-NOTES.md" <<EOF
## Provenance

See \`sp11-kernel-release-manifest.txt\` for package hashes, source metadata,
support repository commit, and local-patch provenance.

Recorded source:

- Source URL: \`${SOURCE_URL:-unknown}\`
- Source ref: \`${SOURCE_BRANCH:-unknown}\`
- Source HEAD: \`${source_head:-unknown}\`
EOF

if [ "$source_mode" = "apt" ]; then
  echo "- Apt source spec: \`${apt_source_spec:-unknown}\`" >> "$OUT_DIR/RELEASE-NOTES.md"
fi

echo "- Docker image: \`$DOCKER_IMAGE\`" >> "$OUT_DIR/RELEASE-NOTES.md"

if [ "$PATCH_DIR_COUNT" -eq 0 ]; then
  echo "- Local patches: none" >> "$OUT_DIR/RELEASE-NOTES.md"
else
  for patch_dir in "${PATCH_DIRS[@]}"; do
    echo "- Patch directory: \`$patch_dir\`" >> "$OUT_DIR/RELEASE-NOTES.md"
  done
fi

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  cat >> "$OUT_DIR/RELEASE-NOTES.md" <<EOF
- Touchscreen source URL: \`$TOUCHSCREEN_SOURCE_URL\`
- Touchscreen source commit: \`$TOUCHSCREEN_SOURCE_REF\`
- Touchscreen manifest: \`$TOUCHSCREEN_MODULE_MANIFEST\`
EOF
fi

cat >> "$OUT_DIR/RELEASE-NOTES.md" <<EOF

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible.
EOF

for asset in "${upload_assets[@]}"; do
  if [ ! -f "$OUT_DIR/$asset" ]; then
    echo "Expected upload asset was not generated: $asset" >&2
    exit 1
  fi
done

(
  cd "$OUT_DIR"
  shasum -a 256 "${upload_assets[@]}" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
upload_assets+=("SHA256SUMS")

echo "Prepared release assets in $OUT_DIR_DISPLAY"
echo
if [ "$SOURCE_ASSET_COUNT" -eq 0 ]; then
  echo "No source assets were included, so this is a local draft only."
  echo "Rerun with --source-asset before publishing binaries."
else
  echo "Review $OUT_DIR_DISPLAY/RELEASE-NOTES.md, then publish with a command like:"
  printf '  (cd %q && gh release create %q --target %q --prerelease --title %q --notes-file RELEASE-NOTES.md' \
    "$OUT_DIR_DISPLAY" "$RELEASE_NAME" "$repo_commit" "$RELEASE_NAME"
  for asset in "${upload_assets[@]}"; do
    printf ' %q' "$asset"
  done
  printf ')\n'
fi
