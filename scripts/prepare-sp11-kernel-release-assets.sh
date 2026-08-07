#!/usr/bin/env bash
set -euo pipefail

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_WORK_TREE
  for variable_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
    unset "$variable_name"
  done
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_ATTR_NOSYSTEM=1
  export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

KERNEL_DEBS_DIR="payload/kernel-debs"
ARTIFACTS_DIR="build/docker-sp11-qcom-x1e-kernel/artifacts"
PATCH_DIRS=("patches/ubuntu-qcom-x1e-7.0")
PATCH_DIR_EXPLICIT="false"
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
KERNEL_SOURCE_ASSET=""
TOUCHSCREEN_SOURCE_ASSET=""
KERNEL_SOURCE_ASSET_SHA256=""
TOUCHSCREEN_SOURCE_ASSET_SHA256=""
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
SOURCE_SNAPSHOT_DIR=""
PROVENANCE_SNAPSHOT_DIR=""
OUTPUT_STAGING_DIR=""

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for optional prebuilt
Surface Pro 11 qcom-x1e kernel packages. It does not publish anything.

Options:
  --kernel-debs-dir DIR   Directory containing built qcom-x1e .debs,
                          default $KERNEL_DEBS_DIR.
  --artifacts-dir DIR     Directory containing the final schema-v2 release
                          build manifest,
                          default $ARTIFACTS_DIR.
  --patch-dir DIR         Patch directory. Repeat to record ordered patch sets;
                          default ${PATCH_DIRS[0]}.
  --release-name NAME     Release/tag name. If omitted, derived from package
                          version when possible.
  --out-dir DIR           Output directory. If omitted, defaults to
                          build/release/<release-name>.
  --source-url URL        Upstream kernel source URL recorded in the manifest.
  --source-branch NAME    Upstream kernel source branch or tag recorded in the
                          manifest.
  --docker-image IMAGE    Exact digest-pinned Docker image. If supplied, it
                          must match the schema-v2 build manifest; otherwise
                          the helper uses the manifest value.
  --source-asset PATH     XZ-compressed corresponding-source .tar.xz archive
                          to validate and copy. Can be repeated.
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

single_manifest_value() {
  local file="$1" label="$2"

  awk -v prefix="$label: " '
    index($0, prefix) == 1 {
      count++
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (count != 1 || value == "") {
        exit 1
      }
      print value
    }
  ' "$file"
}

required_manifest_value() {
  local file="$1" label="$2" value

  if ! value="$(single_manifest_value "$file" "$label")"; then
    echo "Build manifest must contain exactly one nonempty '$label:' field." >&2
    return 1
  fi
  printf '%s\n' "$value"
}

verify_final_support_state() {
  local current_head current_status
  if ! current_head="$(git rev-parse --verify 'HEAD^{commit}')"; then
    echo "Could not re-resolve the support repository commit." >&2
    return 1
  fi
  current_head="$(printf '%s' "$current_head" | tr '[:upper:]' '[:lower:]')"
  if [ "$current_head" != "$repo_commit" ]; then
    echo "Support repository HEAD changed during release preparation." >&2
    return 1
  fi
  if ! current_status="$(git status --porcelain --untracked-files=all)"; then
    echo "Could not re-inspect the support repository worktree state." >&2
    return 1
  fi
  if [ "$dirty" = "false" ] && [ -n "$current_status" ]; then
    echo "Support repository became dirty during release preparation." >&2
    return 1
  fi
}

safe_relative_path() {
  case "$1" in
    ""|/*|../*|*/../*|*/..|*//*|./*|*/./*) return 1 ;;
    *) return 0 ;;
  esac
}

public_https_url() {
  local url="$1" authority path

  case "$url" in
    https://*) ;;
    *) return 1 ;;
  esac
  [ "${#url}" -le 2048 ] || return 1
  case "$url" in
    *[[:space:]]*|*\?*|*\#*|*@*|*\'*|*\"*|*\`*|*\$*|*\\*) return 1 ;;
    *[!A-Za-z0-9._~:/%+-]*) return 1 ;;
  esac
  authority="${url#https://}"
  authority="${authority%%/*}"
  case "$authority" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
    localhost|localhost.*|*.localhost|*.local|*.internal|*.invalid|*.test|*.example|*.onion) return 1 ;;
  esac
  case "$authority" in
    *[!0-9.]*) ;;
    *) return 1 ;;
  esac
  case "$authority" in
    *.*) ;;
    *) return 1 ;;
  esac
  path="${url#https://$authority}"
  case "$path" in
    /?*) ;;
    *) return 1 ;;
  esac
  return 0
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

cleanup_source_snapshot() {
  [ -n "$SOURCE_SNAPSHOT_DIR" ] || return 0
  case "$SOURCE_SNAPSHOT_DIR" in
    "${repo_dir:-}/build/release/.source-snapshot."*) rm -rf -- "$SOURCE_SNAPSHOT_DIR" ;;
    *) echo "Warning: refusing to remove unexpected source snapshot: $SOURCE_SNAPSHOT_DIR" >&2 ;;
  esac
}
cleanup_provenance_snapshot() {
  [ -n "$PROVENANCE_SNAPSHOT_DIR" ] || return 0
  case "$PROVENANCE_SNAPSHOT_DIR" in
    "${repo_dir:-}/build/release/.provenance-snapshot."*) rm -rf -- "$PROVENANCE_SNAPSHOT_DIR" ;;
    *) echo "Warning: refusing to remove unexpected provenance snapshot: $PROVENANCE_SNAPSHOT_DIR" >&2 ;;
  esac
}
cleanup_output_staging() {
  [ -n "$OUTPUT_STAGING_DIR" ] || return 0
  case "$OUTPUT_STAGING_DIR" in
    "${repo_dir:-}/build/release/."*.staging.*) rm -rf -- "$OUTPUT_STAGING_DIR" ;;
    *) echo "Warning: refusing to remove unexpected release staging directory: $OUTPUT_STAGING_DIR" >&2 ;;
  esac
}
trap 'cleanup_output_staging; cleanup_source_snapshot; cleanup_provenance_snapshot' EXIT

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
      if [ "$PATCH_DIR_EXPLICIT" != "true" ]; then
        PATCH_DIRS=()
        PATCH_DIR_EXPLICIT="true"
      fi
      PATCH_DIRS+=("$2")
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
require_tool dpkg-deb
require_tool git
require_tool shasum
require_tool stat
require_tool tr

if [ -n "$TOUCHSCREEN_MODULES_DIR" ]; then
  TOUCHSCREEN_ENABLED="true"
  require_tool grep
  require_tool modinfo

  if [ -z "$TOUCHSCREEN_SOURCE_URL" ] || [ -z "$TOUCHSCREEN_SOURCE_REF" ]; then
    echo "--touchscreen-modules-dir requires --touchscreen-source-url and --touchscreen-source-ref." >&2
    exit 2
  fi
  if ! public_https_url "$TOUCHSCREEN_SOURCE_URL"; then
    echo "Touchscreen source URL must be public HTTPS without credentials, query, or fragment." >&2
    exit 2
  fi

  if [[ ! "$TOUCHSCREEN_SOURCE_REF" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
    echo "Touchscreen source ref must be an immutable 40- or 64-character hexadecimal commit." >&2
    exit 2
  fi
  TOUCHSCREEN_SOURCE_REF="$(printf '%s' "$TOUCHSCREEN_SOURCE_REF" | tr '[:upper:]' '[:lower:]')"
elif [ -n "$TOUCHSCREEN_SOURCE_URL" ] || [ -n "$TOUCHSCREEN_SOURCE_REF" ]; then
  echo "--touchscreen-source-url and --touchscreen-source-ref require --touchscreen-modules-dir." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"
public_content_validator="$repo_dir/scripts/validate-sp11-public-content.sh"

if [ ! -d "$KERNEL_DEBS_DIR" ] || [ -L "$KERNEL_DEBS_DIR" ]; then
  echo "Kernel deb directory not found or is a symlink: $KERNEL_DEBS_DIR" >&2
  exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ] || [ -L "$ARTIFACTS_DIR" ]; then
  echo "Build artifacts directory not found or is a symlink: $ARTIFACTS_DIR" >&2
  exit 1
fi

for patch_dir in "${PATCH_DIRS[@]}"; do
  if [ ! -d "$patch_dir" ]; then
    echo "Patch directory not found: $patch_dir" >&2
    exit 1
  fi
done

debs=()
deb_roles=()
if find "$KERNEL_DEBS_DIR" -maxdepth 1 -type l -name '*.deb' -print | grep -q .; then
  echo "Kernel deb directory must not contain symlinked .deb entries." >&2
  exit 1
fi
while IFS= read -r deb; do
  debs+=("$deb")
done < <(find "$KERNEL_DEBS_DIR" -maxdepth 1 -type f -name '*.deb' | LC_ALL=C sort)
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
seen_modules_extra="false"

for deb in "${debs[@]}"; do
  base="$(basename "$deb")"
  role=""
  case "$base" in
    linux-qcom-x1e-headers-*_all.deb) role="common_headers" ;;
    linux-headers-*_arm64.deb) role="headers" ;;
    linux-image-unsigned-*_arm64.deb|linux-image-*_arm64.deb) role="image" ;;
    linux-modules-extra-*_arm64.deb) role="modules_extra" ;;
    linux-modules-*_arm64.deb) role="modules" ;;
    *)
      echo "Unexpected kernel package filename: $base" >&2
      echo "Expected linux-{headers,image,modules,modules-extra}-<abi>_<version>_arm64.deb or linux-qcom-x1e-headers-<version>_<version>_all.deb." >&2
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
    modules_extra)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      deb_abi="${without_arch#linux-modules-extra-}"
      deb_abi="${deb_abi%_$deb_version}"
      ;;
    image)
      without_arch="${base%_arm64.deb}"
      deb_version="${without_arch##*_}"
      case "$without_arch" in
        linux-image-unsigned-*) deb_abi="${without_arch#linux-image-unsigned-}" ;;
        *) deb_abi="${without_arch#linux-image-}" ;;
      esac
      deb_abi="${deb_abi%_$deb_version}"
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
    modules_extra)
      if [ "$seen_modules_extra" = "true" ]; then
        echo "Duplicate linux-modules-extra package in $KERNEL_DEBS_DIR." >&2
        exit 1
      fi
      seen_modules_extra="true"
      ;;
  esac
  deb_roles+=("$role")
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

touchscreen_module_names=()
touchscreen_module_vermagic=()
touchscreen_module_srcversions=()
touchscreen_module_sizes=()
touchscreen_module_shas=()
touchscreen_source_contract=""
touchscreen_source_object_format=""
touchscreen_source_modules_path=""
touchscreen_source_modules_tree_id=""
touchscreen_source_license_path=""
touchscreen_source_license_mode=""
touchscreen_source_license_blob_id=""
touchscreen_kernel_config_sha256=""
touchscreen_kernel_module_symvers_sha256=""
touchscreen_kernel_headers_input_mode=""
touchscreen_kernel_common_headers_deb=""
touchscreen_kernel_common_headers_deb_sha256=""
touchscreen_kernel_headers_deb=""
touchscreen_kernel_headers_deb_sha256=""
touchscreen_module_compiler_identity=""
touchscreen_module_linker_identity=""
touchscreen_module_make_identity=""
input_touchscreen_module_shas=()

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  if [ ! -d "$TOUCHSCREEN_MODULES_DIR" ] || [ -L "$TOUCHSCREEN_MODULES_DIR" ]; then
    echo "Touchscreen modules directory not found or is a symlink: $TOUCHSCREEN_MODULES_DIR" >&2
    exit 1
  fi

  touchscreen_entries=()
  while IFS= read -r entry_path; do
    entry="$(basename "$entry_path")"
    [ "$entry" = "$TOUCHSCREEN_MODULE_MANIFEST" ] && continue
    touchscreen_entries+=("$entry")
  done < <(find "$TOUCHSCREEN_MODULES_DIR" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)

  expected_touchscreen_entries="$(printf '%s\n' "${TOUCHSCREEN_MODULE_FILES[@]}" | sort)"
  actual_touchscreen_entries="$(printf '%s\n' "${touchscreen_entries[@]}" | sort)"
  if [ "${#touchscreen_entries[@]}" -ne "${#TOUCHSCREEN_MODULE_FILES[@]}" ] || \
     [ "$actual_touchscreen_entries" != "$expected_touchscreen_entries" ]; then
    echo "Touchscreen modules directory must contain exactly: ${TOUCHSCREEN_MODULE_FILES[*]}" >&2
    exit 1
  fi

  input_touchscreen_manifest="$TOUCHSCREEN_MODULES_DIR/$TOUCHSCREEN_MODULE_MANIFEST"
  if [ -f "$input_touchscreen_manifest" ] && [ ! -L "$input_touchscreen_manifest" ]; then
    input_source_url="$(required_manifest_value "$input_touchscreen_manifest" "Source URL")"
    input_source_commit="$(required_manifest_value "$input_touchscreen_manifest" "Source commit")"
    input_target_release="$(required_manifest_value "$input_touchscreen_manifest" "Target release")"
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
    if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
      touchscreen_source_contract="$(required_manifest_value "$input_touchscreen_manifest" "Source archive contract")"
      touchscreen_source_object_format="$(required_manifest_value "$input_touchscreen_manifest" "Source object format")"
      touchscreen_source_modules_path="$(required_manifest_value "$input_touchscreen_manifest" "Source modules path")"
      touchscreen_source_modules_tree_id="$(required_manifest_value "$input_touchscreen_manifest" "Source modules tree ID")"
      touchscreen_source_license_path="$(required_manifest_value "$input_touchscreen_manifest" "Source license path")"
      touchscreen_source_license_mode="$(required_manifest_value "$input_touchscreen_manifest" "Source license mode")"
      touchscreen_source_license_blob_id="$(required_manifest_value "$input_touchscreen_manifest" "Source license blob ID")"
      touchscreen_kernel_config_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel config SHA256")"
      touchscreen_kernel_module_symvers_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel Module.symvers SHA256")"
      touchscreen_kernel_headers_input_mode="$(required_manifest_value "$input_touchscreen_manifest" "Kernel headers input mode")"
      touchscreen_kernel_common_headers_deb="$(required_manifest_value "$input_touchscreen_manifest" "Kernel common headers Deb")"
      touchscreen_kernel_common_headers_deb_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel common headers Deb SHA256")"
      touchscreen_kernel_headers_deb="$(required_manifest_value "$input_touchscreen_manifest" "Kernel architecture headers Deb")"
      touchscreen_kernel_headers_deb_sha256="$(required_manifest_value "$input_touchscreen_manifest" "Kernel architecture headers Deb SHA256")"
      touchscreen_module_compiler_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module compiler identity")"
      touchscreen_module_linker_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module linker identity")"
      touchscreen_module_make_identity="$(required_manifest_value "$input_touchscreen_manifest" "Module make identity")"
      if [ "$touchscreen_source_contract" != "sp11-touchscreen-source-v1" ] ||
         { [ "$touchscreen_source_object_format" != "sha1" ] && [ "$touchscreen_source_object_format" != "sha256" ]; } ||
         [ "$touchscreen_source_modules_path" != "phase55/modules" ] ||
         [ "$touchscreen_source_license_path" != "LICENSE" ] ||
         [ "$touchscreen_source_license_mode" != "100644" ] ||
         ! [[ "$touchscreen_source_modules_tree_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
         ! [[ "$touchscreen_source_license_blob_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
         ! [[ "$touchscreen_kernel_config_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         ! [[ "$touchscreen_kernel_module_symvers_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         [ "$touchscreen_kernel_headers_input_mode" != "extracted-debs-v1" ] ||
         ! [[ "$touchscreen_kernel_common_headers_deb" =~ ^[A-Za-z0-9._+-]+\.deb$ ]] ||
         ! [[ "$touchscreen_kernel_common_headers_deb_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         ! [[ "$touchscreen_kernel_headers_deb" =~ ^[A-Za-z0-9._+-]+\.deb$ ]] ||
         ! [[ "$touchscreen_kernel_headers_deb_sha256" =~ ^[0-9a-f]{64}$ ]] ||
         [ -z "$touchscreen_module_compiler_identity" ] ||
         [ -z "$touchscreen_module_linker_identity" ] ||
         [ -z "$touchscreen_module_make_identity" ]; then
        echo "Touchscreen build manifest has an incomplete source-archive identity contract." >&2
        exit 1
      fi
      case "$touchscreen_source_object_format" in
        sha1)
          [ "${#touchscreen_source_modules_tree_id}" -eq 40 ] &&
            [ "${#touchscreen_source_license_blob_id}" -eq 40 ] || {
              echo "Touchscreen source object format and object ID lengths disagree." >&2
              exit 1
            }
          ;;
        sha256)
          [ "${#touchscreen_source_modules_tree_id}" -eq 64 ] &&
            [ "${#touchscreen_source_license_blob_id}" -eq 64 ] || {
              echo "Touchscreen source object format and object ID lengths disagree." >&2
              exit 1
            }
          ;;
      esac
      for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
        input_touchscreen_module_shas+=(
          "$(required_manifest_value "$input_touchscreen_manifest" "Module $module_file SHA256")"
        )
      done
    fi
  elif [ -e "$input_touchscreen_manifest" ]; then
    echo "Touchscreen build manifest is not a regular file: $input_touchscreen_manifest" >&2
    exit 1
  elif [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
    echo "Publishable touchscreen assets require $input_touchscreen_manifest." >&2
    exit 1
  fi

  common_touchscreen_vermagic_abi=""
  module_index=0
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

    touchscreen_module_names[$module_index]="$module_name"
    touchscreen_module_vermagic[$module_index]="$module_vermagic"
    touchscreen_module_srcversions[$module_index]="$module_srcversion"
    touchscreen_module_sizes[$module_index]="$(file_size "$module_path")"
    touchscreen_module_shas[$module_index]="$(shasum -a 256 "$module_path" | awk '{print $1}')"
    module_index=$((module_index + 1))
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
  if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
    module_index=0
    while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
      if ! [[ "${input_touchscreen_module_shas[$module_index]}" =~ ^[0-9a-f]{64}$ ]] ||
         [ "${input_touchscreen_module_shas[$module_index]}" != "${touchscreen_module_shas[$module_index]}" ]; then
        echo "Touchscreen module does not match its build manifest: ${TOUCHSCREEN_MODULE_FILES[$module_index]}" >&2
        exit 1
      fi
      module_index=$((module_index + 1))
    done
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
if [ ! -f "$build_manifest" ] || [ -L "$build_manifest" ]; then
  echo "Refusing assets without a regular, non-symlinked kernel build manifest: $build_manifest" >&2
  exit 1
fi
PROVENANCE_SNAPSHOT_DIR="$(mktemp -d "$release_root_abs/.provenance-snapshot.XXXXXX")"
build_manifest_before_sha="$(shasum -a 256 "$build_manifest" | awk '{print $1}')"
cp -p "$build_manifest" "$PROVENANCE_SNAPSHOT_DIR/sp11-kernel-build-manifest.txt"
build_manifest_after_sha="$(shasum -a 256 "$build_manifest" | awk '{print $1}')"
build_manifest="$PROVENANCE_SNAPSHOT_DIR/sp11-kernel-build-manifest.txt"
build_manifest_snapshot_sha="$(shasum -a 256 "$build_manifest" | awk '{print $1}')"
if [ "$build_manifest_before_sha" != "$build_manifest_after_sha" ] ||
   [ "$build_manifest_before_sha" != "$build_manifest_snapshot_sha" ]; then
  echo "Kernel build manifest changed while its immutable validation snapshot was created." >&2
  exit 1
fi
if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  [ -x "$public_content_validator" ] && [ ! -L "$public_content_validator" ] || {
    echo "Missing executable public-content validator." >&2
    exit 1
  }
  public_input_args=(--file "$build_manifest")
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    public_input_args+=(--file "$input_touchscreen_manifest")
  fi
  "$public_content_validator" "${public_input_args[@]}"
fi

provenance_schema="$(required_manifest_value "$build_manifest" "Provenance schema")"
release_build="$(required_manifest_value "$build_manifest" "Release build")"
build_completed="$(required_manifest_value "$build_manifest" "Build completed")"
support_start_head="$(required_manifest_value "$build_manifest" "Support start HEAD")"
support_start_dirty="$(required_manifest_value "$build_manifest" "Support start dirty")"
support_end_head="$(required_manifest_value "$build_manifest" "Support end HEAD")"
support_end_dirty="$(required_manifest_value "$build_manifest" "Support end dirty")"
source_mode="$(required_manifest_value "$build_manifest" "Source mode")"
source_head="$(required_manifest_value "$build_manifest" "Source HEAD")"
expected_source_commit="$(required_manifest_value "$build_manifest" "Expected source commit")"
manifest_source_url="$(required_manifest_value "$build_manifest" "Source URL")"
manifest_source_ref="$(required_manifest_value "$build_manifest" "Source ref")"
manifest_container_image="$(required_manifest_value "$build_manifest" "Container image")"
manifest_container_digest="$(required_manifest_value "$build_manifest" "Container digest")"
manifest_container_platform="$(required_manifest_value "$build_manifest" "Container platform")"
build_target="$(required_manifest_value "$build_manifest" "Build target")"
jobs="$(required_manifest_value "$build_manifest" "Jobs")"
rules_runner="$(required_manifest_value "$build_manifest" "Rules runner")"
patch_count="$(required_manifest_value "$build_manifest" "Patch count")"
patched_diff_format="$(required_manifest_value "$build_manifest" "Patched diff format")"
patched_diff_git_version="$(required_manifest_value "$build_manifest" "Patched diff Git version")"
patched_diff_sha256="$(required_manifest_value "$build_manifest" "Patched diff SHA256")"
patched_tree_id="$(required_manifest_value "$build_manifest" "Patched tree ID")"
required_output_role_set="$(required_manifest_value "$build_manifest" "Required output roles")"
optional_output_role_set="$(required_manifest_value "$build_manifest" "Optional output roles")"
output_count="$(required_manifest_value "$build_manifest" "Output count")"
signing_certificate_sha256="$(required_manifest_value "$build_manifest" "Signing certificate SHA256")"
signing_certificate_fingerprint="$(required_manifest_value "$build_manifest" "Signing certificate fingerprint")"
signing_certificate_serial="$(required_manifest_value "$build_manifest" "Signing certificate serial")"
required_deb_role_set="$(required_manifest_value "$build_manifest" "Required Deb roles")"
optional_deb_role_set="$(required_manifest_value "$build_manifest" "Optional Deb roles")"
manifest_deb_count="$(required_manifest_value "$build_manifest" "Deb count")"

if [ "$provenance_schema" != "sp11-kernel-build-v2" ]; then
  echo "Refusing non-v2 kernel build provenance: $provenance_schema" >&2
  exit 1
fi
if [ "$release_build" != "true" ]; then
  echo "Refusing a kernel build manifest that is not marked as a release build." >&2
  exit 1
fi
if [ "$build_completed" != "true" ]; then
  echo "Refusing incomplete kernel build provenance." >&2
  exit 1
fi
if [ "$support_start_dirty" != "false" ] || [ "$support_end_dirty" != "false" ] ||
   [ "$support_start_head" != "$support_end_head" ] ||
   ! [[ "$support_start_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  echo "Build manifest does not prove a clean, stable support repository commit." >&2
  exit 1
fi
if [ "$source_mode" != "git" ] ||
   ! [[ "$source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
   [ "$source_head" != "$expected_source_commit" ]; then
  echo "Build manifest does not bind the kernel source to its exact expected Git commit." >&2
  exit 1
fi
if ! public_https_url "$manifest_source_url"; then
  echo "Build manifest kernel source URL is not public HTTPS provenance without credentials, query, or fragment." >&2
  exit 1
fi
if ! [[ "$manifest_source_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
   ! git check-ref-format "refs/heads/$manifest_source_ref" >/dev/null 2>&1; then
  echo "Build manifest kernel source ref is not a safe full ref name." >&2
  exit 1
fi
if ! [[ "$manifest_container_image" =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]] ||
   [ "${manifest_container_image##*@}" != "$manifest_container_digest" ]; then
  echo "Build manifest does not contain a consistent digest-pinned container image." >&2
  exit 1
fi
case "$manifest_container_platform" in
  linux/arm64|linux/arm64/v8) ;;
  *)
    echo "Build manifest has an unsupported container platform: $manifest_container_platform" >&2
    exit 1
    ;;
esac
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]] ||
   [ "$build_target" != "binary-indep binary-qcom-x1e" ]; then
  echo "Build manifest has incomplete target, jobs, or rules-runner provenance." >&2
  exit 1
fi
case "$rules_runner" in
  direct-root|fakeroot) ;;
  *)
    echo "Build manifest has an unsupported rules runner: $rules_runner" >&2
    exit 1
    ;;
esac
if [ "$patched_diff_format" != "git-diff-full-index-binary-v1" ] ||
   [[ "$patched_diff_git_version" != git\ version\ * ]] ||
   ! [[ "$patched_diff_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$patched_tree_id" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  echo "Build manifest has incomplete canonical patched-tree provenance." >&2
  exit 1
fi
if ! [[ "$patch_count" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$output_count" =~ ^[1-9][0-9]*$ ]] ||
   ! [[ "$manifest_deb_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build manifest has invalid patch, output, or package counts." >&2
  exit 1
fi
if [ "$required_output_role_set" != "kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate" ] ||
   [ "$optional_output_role_set" != "none" ] ||
   [ "$required_deb_role_set" != "common-headers headers image modules" ] ||
   [ "$optional_deb_role_set" != "modules-extra" ]; then
  echo "Build manifest does not declare the schema-v2 required and optional role sets." >&2
  exit 1
fi
if [ "$output_count" -ne 7 ] ||
   { [ "$manifest_deb_count" -ne 4 ] && [ "$manifest_deb_count" -ne 5 ]; }; then
  echo "Build manifest has an unexpected required-output or optional-package cardinality." >&2
  exit 1
fi
if ! [[ "$signing_certificate_sha256" =~ ^[0-9a-f]{64}$ ]] ||
   ! [[ "$signing_certificate_fingerprint" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] ||
   ! [[ "$signing_certificate_serial" =~ ^[0-9A-F]+$ ]]; then
  echo "Build manifest has incomplete public X.509 signing-certificate identity." >&2
  exit 1
fi

manifest_patch_paths=()
manifest_patch_sha256s=()
manifest_patch_dispositions=()
index=1
while [ "$index" -le "$patch_count" ]; do
  manifest_patch_path="$(required_manifest_value "$build_manifest" "Patch $index path")"
  manifest_patch_sha="$(required_manifest_value "$build_manifest" "Patch $index SHA256")"
  manifest_patch_disposition="$(required_manifest_value "$build_manifest" "Patch $index disposition")"
  if ! safe_relative_path "$manifest_patch_path" ||
     ! [[ "$manifest_patch_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest patch $index has an unsafe path or invalid SHA-256." >&2
    exit 1
  fi
  case "$manifest_patch_disposition" in
    applied|already-applied|already-satisfied) ;;
    *)
      echo "Build manifest patch $index has an invalid disposition: $manifest_patch_disposition" >&2
      exit 1
      ;;
  esac
  manifest_patch_paths+=("$manifest_patch_path")
  manifest_patch_sha256s+=("$manifest_patch_sha")
  manifest_patch_dispositions+=("$manifest_patch_disposition")
  index=$((index + 1))
done

manifest_output_roles=()
manifest_output_paths=()
manifest_output_sizes=()
manifest_output_sha256s=()
index=1
while [ "$index" -le "$output_count" ]; do
  manifest_output_role="$(required_manifest_value "$build_manifest" "Output $index role")"
  manifest_output_required="$(required_manifest_value "$build_manifest" "Output $index required")"
  manifest_output_path="$(required_manifest_value "$build_manifest" "Output $index path")"
  manifest_output_size="$(required_manifest_value "$build_manifest" "Output $index size")"
  manifest_output_sha="$(required_manifest_value "$build_manifest" "Output $index SHA256")"
  if [ -z "$manifest_output_role" ] || [ "$manifest_output_required" != "true" ] ||
     ! safe_relative_path "$manifest_output_path" ||
     ! [[ "$manifest_output_size" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$manifest_output_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest output $index is incomplete or unsafe." >&2
    exit 1
  fi
  previous=0
  while [ "$previous" -lt "${#manifest_output_roles[@]}" ]; do
    if [ "${manifest_output_roles[$previous]}" = "$manifest_output_role" ] ||
       [ "${manifest_output_paths[$previous]}" = "$manifest_output_path" ]; then
      echo "Build manifest contains a duplicate output role or path." >&2
      exit 1
    fi
    previous=$((previous + 1))
  done
  manifest_output_roles+=("$manifest_output_role")
  manifest_output_paths+=("$manifest_output_path")
  manifest_output_sizes+=("$manifest_output_size")
  manifest_output_sha256s+=("$manifest_output_sha")
  index=$((index + 1))
done

required_output_roles=(
  kernel-config
  module-symvers
  system-map
  kernel-efi-stubble
  denali-oled-dtb
  denali-oled-el2-dtb
  module-signing-certificate
)
required_output_paths=(
  debian/build/build-qcom-x1e/.config
  debian/build/build-qcom-x1e/Module.symvers
  debian/build/build-qcom-x1e/System.map
  debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble
  debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb
  debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb
  debian/build/build-qcom-x1e/certs/signing_key.x509
)
required_index=0
certificate_output_sha=""
kernel_config_output_sha=""
kernel_module_symvers_output_sha=""
while [ "$required_index" -lt "${#required_output_roles[@]}" ]; do
  found="false"
  output_index=0
  while [ "$output_index" -lt "${#manifest_output_roles[@]}" ]; do
    if [ "${manifest_output_roles[$output_index]}" = "${required_output_roles[$required_index]}" ] &&
       [ "${manifest_output_paths[$output_index]}" = "${required_output_paths[$required_index]}" ]; then
      found="true"
      if [ "${required_output_roles[$required_index]}" = "module-signing-certificate" ]; then
        certificate_output_sha="${manifest_output_sha256s[$output_index]}"
      elif [ "${required_output_roles[$required_index]}" = "kernel-config" ]; then
        kernel_config_output_sha="${manifest_output_sha256s[$output_index]}"
      elif [ "${required_output_roles[$required_index]}" = "module-symvers" ]; then
        kernel_module_symvers_output_sha="${manifest_output_sha256s[$output_index]}"
      fi
      break
    fi
    output_index=$((output_index + 1))
  done
  if [ "$found" != "true" ]; then
    echo "Build manifest is missing required output ${required_output_roles[$required_index]}." >&2
    exit 1
  fi
  required_index=$((required_index + 1))
done
if [ "$certificate_output_sha" != "$signing_certificate_sha256" ]; then
  echo "Build manifest signing-certificate hashes disagree." >&2
  exit 1
fi
if [ "$TOUCHSCREEN_ENABLED" = "true" ] && [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if [ "$touchscreen_kernel_config_sha256" != "$kernel_config_output_sha" ]; then
    echo "Touchscreen module build config does not match the release kernel build config." >&2
    exit 1
  fi
  if [ "$touchscreen_kernel_module_symvers_sha256" != "$kernel_module_symvers_output_sha" ]; then
    echo "Touchscreen module build Module.symvers does not match the release kernel build." >&2
    exit 1
  fi
fi

manifest_deb_roles=()
manifest_deb_paths=()
manifest_deb_packages=()
manifest_deb_versions=()
manifest_deb_architectures=()
manifest_deb_sizes=()
manifest_deb_sha256s=()
index=1
while [ "$index" -le "$manifest_deb_count" ]; do
  manifest_deb_role="$(required_manifest_value "$build_manifest" "Deb $index role")"
  manifest_deb_required="$(required_manifest_value "$build_manifest" "Deb $index required")"
  manifest_deb_path="$(required_manifest_value "$build_manifest" "Deb $index path")"
  manifest_deb_package="$(required_manifest_value "$build_manifest" "Deb $index package")"
  manifest_deb_version="$(required_manifest_value "$build_manifest" "Deb $index version")"
  manifest_deb_architecture="$(required_manifest_value "$build_manifest" "Deb $index architecture")"
  manifest_deb_size="$(required_manifest_value "$build_manifest" "Deb $index size")"
  manifest_deb_sha="$(required_manifest_value "$build_manifest" "Deb $index SHA256")"
  case "$manifest_deb_role" in
    common-headers|headers|image|modules|modules-extra) ;;
    *)
      echo "Build manifest package $index has an invalid role: $manifest_deb_role" >&2
      exit 1
      ;;
  esac
  case "$manifest_deb_role:$manifest_deb_required" in
    common-headers:true|headers:true|image:true|modules:true|modules-extra:false) ;;
    *)
      echo "Build manifest package $index has inconsistent required/optional classification." >&2
      exit 1
      ;;
  esac
  if ! safe_relative_path "$manifest_deb_path" || [[ "$manifest_deb_path" == */* ]] ||
     [ -z "$manifest_deb_package" ] || [ -z "$manifest_deb_version" ] ||
     [ -z "$manifest_deb_architecture" ] ||
     ! [[ "$manifest_deb_size" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$manifest_deb_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Build manifest package $index is incomplete or unsafe." >&2
    exit 1
  fi
  if ! [[ "$manifest_deb_package" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] ||
     ! [[ "$manifest_deb_version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
     ! [[ "$manifest_deb_architecture" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Build manifest package $index has unsafe identity fields." >&2
    exit 1
  fi
  manifest_deb_roles+=("$manifest_deb_role")
  manifest_deb_paths+=("$manifest_deb_path")
  manifest_deb_packages+=("$manifest_deb_package")
  manifest_deb_versions+=("$manifest_deb_version")
  manifest_deb_architectures+=("$manifest_deb_architecture")
  manifest_deb_sizes+=("$manifest_deb_size")
  manifest_deb_sha256s+=("$manifest_deb_sha")
  index=$((index + 1))
done

if [ "$manifest_deb_count" -ne "${#debs[@]}" ]; then
  echo "Build manifest package count does not match the release package directory." >&2
  exit 1
fi
actual_index=0
while [ "$actual_index" -lt "${#debs[@]}" ]; do
  actual_deb="${debs[$actual_index]}"
  actual_base="$(basename "$actual_deb")"
  case "${deb_roles[$actual_index]}" in
    common_headers) actual_role="common-headers" ;;
    modules_extra) actual_role="modules-extra" ;;
    *) actual_role="${deb_roles[$actual_index]}" ;;
  esac
  actual_package="$(dpkg-deb -f "$actual_deb" Package)"
  actual_version="$(dpkg-deb -f "$actual_deb" Version)"
  actual_architecture="$(dpkg-deb -f "$actual_deb" Architecture)"
  actual_size="$(file_size "$actual_deb")"
  actual_sha="$(shasum -a 256 "$actual_deb" | awk '{ print $1 }')"
  if [ "$actual_package" != "${actual_base%%_*}" ]; then
    echo "Package field $actual_package does not match release filename $actual_base." >&2
    exit 1
  fi
  actual_filename_without_arch="${actual_base%_${actual_architecture}.deb}"
  if [ "$actual_version" != "${actual_filename_without_arch##*_}" ]; then
    echo "Version field $actual_version does not match release filename $actual_base." >&2
    exit 1
  fi
  matched="false"
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_paths[@]}" ]; do
    if [ "${manifest_deb_paths[$manifest_index]}" = "$actual_base" ]; then
      if [ "$matched" = "true" ]; then
        echo "Build manifest lists package $actual_base more than once." >&2
        exit 1
      fi
      matched="true"
      if [ "${manifest_deb_roles[$manifest_index]}" != "$actual_role" ] ||
         [ "${manifest_deb_packages[$manifest_index]}" != "$actual_package" ] ||
         [ "${manifest_deb_versions[$manifest_index]}" != "$actual_version" ] ||
         [ "${manifest_deb_architectures[$manifest_index]}" != "$actual_architecture" ] ||
         [ "${manifest_deb_sizes[$manifest_index]}" != "$actual_size" ] ||
         [ "${manifest_deb_sha256s[$manifest_index]}" != "$actual_sha" ]; then
        echo "Release package does not match its build provenance: $actual_base" >&2
        exit 1
      fi
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ "$matched" != "true" ]; then
    echo "Release package is absent from the build manifest: $actual_base" >&2
    exit 1
  fi
  actual_index=$((actual_index + 1))
done

for required_deb_role in common-headers headers image modules; do
  found="false"
  for manifest_deb_role in "${manifest_deb_roles[@]}"; do
    [ "$manifest_deb_role" = "$required_deb_role" ] && found="true"
  done
  if [ "$found" != "true" ]; then
    echo "Build manifest is missing required package role $required_deb_role." >&2
    exit 1
  fi
done

if [ "$TOUCHSCREEN_ENABLED" = "true" ] && [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  matched_common_headers="false"
  matched_architecture_headers="false"
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_roles[@]}" ]; do
    if [ "${manifest_deb_roles[$manifest_index]}" = "common-headers" ] &&
       [ "${manifest_deb_paths[$manifest_index]}" = "$touchscreen_kernel_common_headers_deb" ] &&
       [ "${manifest_deb_sha256s[$manifest_index]}" = "$touchscreen_kernel_common_headers_deb_sha256" ]; then
      matched_common_headers="true"
    fi
    if [ "${manifest_deb_roles[$manifest_index]}" = "headers" ] &&
       [ "${manifest_deb_paths[$manifest_index]}" = "$touchscreen_kernel_headers_deb" ] &&
       [ "${manifest_deb_sha256s[$manifest_index]}" = "$touchscreen_kernel_headers_deb_sha256" ]; then
      matched_architecture_headers="true"
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ "$matched_common_headers" != "true" ] || [ "$matched_architecture_headers" != "true" ]; then
    echo "Touchscreen module build header Debs do not match kernel build provenance." >&2
    exit 1
  fi
fi

repo_commit="$(git rev-parse 'HEAD^{commit}')"
repo_commit="$(printf '%s' "$repo_commit" | tr '[:upper:]' '[:lower:]')"
dirty="false"
if ! support_status="$(git status --porcelain --untracked-files=all)"; then
  echo "Could not inspect the support repository worktree state." >&2
  exit 1
fi
if [ -n "$support_status" ]; then
  dirty="true"
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  require_tool python3
  build_manifest_validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
  if [ ! -f "$build_manifest_validator" ] || [ -L "$build_manifest_validator" ]; then
    echo "Missing regular schema-v2 build-manifest validator." >&2
    exit 1
  fi
  python3 "$build_manifest_validator" \
    --build-only \
    --require-current-head \
    --repo-dir "$repo_dir" \
    --support-commit "$repo_commit" \
    --kernel-build-manifest "$build_manifest"
fi

if [ "$dirty" = "true" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "Refusing to prepare public release assets from a dirty support repository." >&2
  echo "Commit or stash changes first, or pass --allow-dirty for a local test run." >&2
  exit 1
fi

if [ "$support_start_head" != "$repo_commit" ]; then
  echo "Build provenance support commit does not match the current support repository HEAD." >&2
  exit 1
fi

actual_patch_paths=()
actual_patch_sha256s=()
for patch_dir in "${PATCH_DIRS[@]}"; do
  if [ -L "$patch_dir" ]; then
    echo "Release patch directory must not be a symlink: $patch_dir" >&2
    exit 1
  fi
  canonical_patch_dir="$(cd "$patch_dir" && pwd -P)"
  case "$canonical_patch_dir" in
    "$repo_dir"/*) ;;
    *)
      echo "Release patch directory resolves outside the support repository: $patch_dir" >&2
      exit 1
      ;;
  esac
  if find "$canonical_patch_dir" -maxdepth 1 -type l -name '*.patch' -print | grep -q .; then
    echo "Release patch directory contains a symlinked .patch entry: $patch_dir" >&2
    exit 1
  fi
  while IFS= read -r actual_patch; do
    [ -n "$actual_patch" ] || continue
    if [ ! -s "$actual_patch" ] || [ -L "$actual_patch" ]; then
      echo "Release patch must be a nonempty regular, non-symlinked file: $actual_patch" >&2
      exit 1
    fi
    actual_patch_path="${actual_patch#"$repo_dir"/}"
    if ! git ls-files --error-unmatch -- "$actual_patch_path" >/dev/null 2>&1; then
      echo "Release patch is not tracked by the support commit: $actual_patch_path" >&2
      exit 1
    fi
    actual_patch_paths+=("$actual_patch_path")
    actual_patch_sha256s+=("$(shasum -a 256 "$actual_patch" | awk '{ print $1 }')")
  done < <(find "$canonical_patch_dir" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)
done
if [ "${#actual_patch_paths[@]}" -ne "$patch_count" ]; then
  echo "Release patch count does not match the build manifest." >&2
  exit 1
fi
index=0
while [ "$index" -lt "${#actual_patch_paths[@]}" ]; do
  if [ "${actual_patch_paths[$index]}" != "${manifest_patch_paths[$index]}" ] ||
     [ "${actual_patch_sha256s[$index]}" != "${manifest_patch_sha256s[$index]}" ]; then
    echo "Release patch order or SHA-256 does not match build provenance at entry $((index + 1))." >&2
    exit 1
  fi
  index=$((index + 1))
done

if [ "$SOURCE_URL_EXPLICIT" != "true" ]; then
  SOURCE_URL="$manifest_source_url"
elif [ "$SOURCE_URL" != "$manifest_source_url" ]; then
  echo "--source-url does not match the URL recorded by the build manifest." >&2
  exit 1
fi
if [ "$SOURCE_BRANCH_EXPLICIT" != "true" ]; then
  SOURCE_BRANCH="$manifest_source_ref"
elif [ "$SOURCE_BRANCH" != "$manifest_source_ref" ]; then
  echo "--source-branch does not match the ref recorded by the build manifest." >&2
  exit 1
fi
if [ -z "$DOCKER_IMAGE" ]; then
  DOCKER_IMAGE="$manifest_container_image"
elif [ "$DOCKER_IMAGE" != "$manifest_container_image" ]; then
  echo "--docker-image does not match the digest-pinned image recorded by the build manifest." >&2
  exit 1
fi

if ! git check-ref-format "refs/tags/$RELEASE_NAME" >/dev/null 2>&1; then
  echo "Release name is not a valid Git tag: $RELEASE_NAME" >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -eq 0 ] && [ "$ALLOW_MISSING_SOURCE" != "true" ]; then
  echo "Refusing to prepare publishable kernel assets without corresponding source." >&2
  echo "Pass the exact patched-source archive with --source-asset PATH." >&2
  echo "For a local draft only, pass --allow-missing-source." >&2
  exit 1
fi

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  require_tool python3
  source_archive_validator="$repo_dir/scripts/validate-sp11-source-archive.py"
  if [ ! -f "$source_archive_validator" ] || [ -L "$source_archive_validator" ]; then
    echo "Missing regular source-archive validator: scripts/validate-sp11-source-archive.py" >&2
    exit 1
  fi

  canonical_source_assets=()
  for source_asset_input in "${SOURCE_ASSETS[@]}"; do
    if [ ! -s "$source_asset_input" ] || [ -L "$source_asset_input" ]; then
      echo "Source asset must be a non-empty regular, non-symlinked file: $source_asset_input" >&2
      exit 1
    fi
    source_asset_dir="$(cd "$(dirname "$source_asset_input")" && pwd -P)"
    source_asset="$source_asset_dir/$(basename "$source_asset_input")"
    case "$source_asset" in
      "$repo_dir"/*) ;;
      *)
        echo "Source asset must resolve inside the support repository: $source_asset_input" >&2
        exit 1
        ;;
    esac
    source_asset_base="$(basename "$source_asset")"
    case "$source_asset_base" in
      ""|*[!A-Za-z0-9._+-]*)
        echo "Source asset has an unsafe release basename: $source_asset_base" >&2
        exit 1
        ;;
    esac
    case "$source_asset_base" in
      sp11-touchscreen-modules-source-*.tar.xz)
        if [ -n "$TOUCHSCREEN_SOURCE_ASSET" ]; then
          echo "Supply exactly one touchscreen corresponding-source archive." >&2
          exit 1
        fi
        TOUCHSCREEN_SOURCE_ASSET="$source_asset"
        ;;
      *patched-source*.tar.xz)
        if [ -n "$KERNEL_SOURCE_ASSET" ]; then
          echo "Supply exactly one patched-kernel corresponding-source archive." >&2
          exit 1
        fi
        KERNEL_SOURCE_ASSET="$source_asset"
        ;;
      *)
        echo "Unexpected corresponding-source archive name: $source_asset_base" >&2
        exit 1
        ;;
    esac
    canonical_source_assets+=("$source_asset")
  done
  SOURCE_ASSETS=("${canonical_source_assets[@]}")

  if [ -z "$KERNEL_SOURCE_ASSET" ]; then
    echo "Publishable kernel assets require exactly one patched-source .tar.xz archive." >&2
    exit 1
  fi
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    if [ -z "$TOUCHSCREEN_SOURCE_ASSET" ] || [ "$SOURCE_ASSET_COUNT" -ne 2 ]; then
      echo "Publishable sp11v3 assets require one kernel and one touchscreen source archive." >&2
      exit 1
    fi
  elif [ -n "$TOUCHSCREEN_SOURCE_ASSET" ] || [ "$SOURCE_ASSET_COUNT" -ne 1 ]; then
    echo "A non-touchscreen kernel release accepts exactly one patched-source archive." >&2
    exit 1
  fi

  SOURCE_SNAPSHOT_DIR="$(mktemp -d "$release_root_abs/.source-snapshot.XXXXXX")"
  snapshot_source_assets=()
  source_snapshot_inputs=("$KERNEL_SOURCE_ASSET")
  if [ -n "$TOUCHSCREEN_SOURCE_ASSET" ]; then
    source_snapshot_inputs+=("$TOUCHSCREEN_SOURCE_ASSET")
  fi
  for source_asset in "${source_snapshot_inputs[@]}"; do
    source_asset_base="$(basename "$source_asset")"
    source_before_sha="$(shasum -a 256 "$source_asset" | awk '{print $1}')"
    cp -p "$source_asset" "$SOURCE_SNAPSHOT_DIR/$source_asset_base"
    source_after_sha="$(shasum -a 256 "$source_asset" | awk '{print $1}')"
    snapshot_sha="$(shasum -a 256 "$SOURCE_SNAPSHOT_DIR/$source_asset_base" | awk '{print $1}')"
    if [ "$source_before_sha" != "$source_after_sha" ] || [ "$source_before_sha" != "$snapshot_sha" ]; then
      echo "Source asset changed while its immutable validation snapshot was created: $source_asset_base" >&2
      exit 1
    fi
    snapshot_source_assets+=("$SOURCE_SNAPSHOT_DIR/$source_asset_base")
    if [ "$source_asset" = "$KERNEL_SOURCE_ASSET" ]; then
      KERNEL_SOURCE_ASSET="$SOURCE_SNAPSHOT_DIR/$source_asset_base"
    else
      TOUCHSCREEN_SOURCE_ASSET="$SOURCE_SNAPSHOT_DIR/$source_asset_base"
    fi
  done
  SOURCE_ASSETS=("${snapshot_source_assets[@]}")

  if ! python3 "$source_archive_validator" kernel \
      --archive "$KERNEL_SOURCE_ASSET" \
      --expected-tree "$patched_tree_id"; then
    echo "Patched-kernel corresponding-source archive does not match build provenance." >&2
    exit 1
  fi
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    if ! python3 "$source_archive_validator" touchscreen \
        --archive "$TOUCHSCREEN_SOURCE_ASSET" \
        --expected-modules-tree "$touchscreen_source_modules_tree_id" \
        --expected-license-blob "$touchscreen_source_license_blob_id" \
        --license-mode "$touchscreen_source_license_mode" \
        --expected-archive-comment "$TOUCHSCREEN_SOURCE_REF"; then
      echo "Touchscreen corresponding-source archive does not match module build provenance." >&2
      exit 1
    fi
  fi
  KERNEL_SOURCE_ASSET_SHA256="$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')"
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    TOUCHSCREEN_SOURCE_ASSET_SHA256="$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')"
  fi

  for source_asset in "${SOURCE_ASSETS[@]}"; do
    if [ ! -f "$source_asset" ] || [ -L "$source_asset" ]; then
      echo "Source asset must be a regular, non-symlinked file: $source_asset" >&2
      exit 1
    fi
  done
fi


if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  if git show-ref --verify --quiet "refs/tags/$RELEASE_NAME"; then
    local_tag_commit="$(git rev-parse "refs/tags/$RELEASE_NAME^{commit}")"
    if [ "$local_tag_commit" != "$repo_commit" ]; then
      echo "Refusing release: local tag $RELEASE_NAME points to $local_tag_commit, not support repo HEAD $repo_commit." >&2
      exit 1
    fi
  fi

  if [ "$dirty" = "false" ] && git remote get-url origin >/dev/null 2>&1; then
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
  elif [ "$dirty" = "false" ]; then
    echo "Refusing a publishable release because the support repository has no origin remote." >&2
    echo "Configure the public release remote and rerun so an existing tag cannot be missed." >&2
    exit 1
  fi
fi

upload_assets=()
claimed_output_names=()
claimed_output_origins=()

claim_output_name() {
  local name="$1"
  local origin="$2"
  local index=0

  while [ "$index" -lt "${#claimed_output_names[@]}" ]; do
    if [ "${claimed_output_names[$index]}" = "$name" ]; then
      echo "Refusing colliding release asset name $name from $origin; already used by ${claimed_output_origins[$index]}." >&2
      exit 1
    fi
    index=$((index + 1))
  done
  claimed_output_names+=("$name")
  claimed_output_origins+=("$origin")
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

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    append_upload_asset "$(basename "$source_asset")" "$source_asset"
  done
fi

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    append_upload_asset "$module_file" "$TOUCHSCREEN_MODULES_DIR/$module_file"
  done
  append_upload_asset "$TOUCHSCREEN_MODULE_MANIFEST" "generated touchscreen module manifest"
fi

append_upload_asset "sp11-kernel-release-manifest.txt" "generated kernel release manifest"
append_upload_asset "sp11-kernel-debs.txt" "generated kernel package list"
append_upload_asset "sp11-kernel-build-manifest.txt" "schema-v2 kernel build provenance"

FINAL_OUT_DIR="$OUT_DIR"
OUTPUT_STAGING_DIR="$(mktemp -d "$release_root_abs/.${out_leaf}.staging.XXXXXX")"
OUT_DIR="$OUTPUT_STAGING_DIR"

mv "$build_manifest" "$OUT_DIR/sp11-kernel-build-manifest.txt"
build_manifest="$OUT_DIR/sp11-kernel-build-manifest.txt"
if [ "$(shasum -a 256 "$build_manifest" | awk '{print $1}')" != "$build_manifest_snapshot_sha" ]; then
  echo "Staged kernel build manifest changed after provenance validation." >&2
  exit 1
fi

for deb in "${debs[@]}"; do
  cp "$deb" "$OUT_DIR/"
done

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  staged_source_assets=()
  for source_asset in "${SOURCE_ASSETS[@]}"; do
    staged_source="$OUT_DIR/$(basename "$source_asset")"
    mv "$source_asset" "$staged_source"
    staged_source_assets+=("$staged_source")
  done
  SOURCE_ASSETS=("${staged_source_assets[@]}")
  KERNEL_SOURCE_ASSET="$OUT_DIR/$(basename "$KERNEL_SOURCE_ASSET")"
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    TOUCHSCREEN_SOURCE_ASSET="$OUT_DIR/$(basename "$TOUCHSCREEN_SOURCE_ASSET")"
  fi
fi

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
    cp "$TOUCHSCREEN_MODULES_DIR/$module_file" "$OUT_DIR/"
  done
fi

actual_index=0
while [ "$actual_index" -lt "${#debs[@]}" ]; do
  staged_deb="$OUT_DIR/$(basename "${debs[$actual_index]}")"
  staged_deb_sha="$(shasum -a 256 "$staged_deb" | awk '{print $1}')"
  expected_staged_deb_sha=""
  manifest_index=0
  while [ "$manifest_index" -lt "${#manifest_deb_paths[@]}" ]; do
    if [ "${manifest_deb_paths[$manifest_index]}" = "$(basename "$staged_deb")" ]; then
      expected_staged_deb_sha="${manifest_deb_sha256s[$manifest_index]}"
      break
    fi
    manifest_index=$((manifest_index + 1))
  done
  if [ -z "$expected_staged_deb_sha" ] || [ "$staged_deb_sha" != "$expected_staged_deb_sha" ]; then
    echo "Staged kernel package changed after provenance validation: $(basename "$staged_deb")" >&2
    exit 1
  fi
  actual_index=$((actual_index + 1))
done
if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  [ "$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')" = "$KERNEL_SOURCE_ASSET_SHA256" ] || {
    echo "Staged patched-kernel source archive changed after validation." >&2
    exit 1
  }
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    [ "$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')" = "$TOUCHSCREEN_SOURCE_ASSET_SHA256" ] || {
      echo "Staged touchscreen source archive changed after validation." >&2
      exit 1
    }
  fi
fi
if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  module_index=0
  while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
    staged_module="$OUT_DIR/${TOUCHSCREEN_MODULE_FILES[$module_index]}"
    if [ "$(shasum -a 256 "$staged_module" | awk '{print $1}')" != "${touchscreen_module_shas[$module_index]}" ]; then
      echo "Staged touchscreen module changed after provenance validation: ${TOUCHSCREEN_MODULE_FILES[$module_index]}" >&2
      exit 1
    fi
    module_index=$((module_index + 1))
  done
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
  {
    echo "Generated: $generated_at"
    echo "Release: $RELEASE_NAME"
    echo "Kernel ABI: $kernel_abi"
    echo "Touchscreen source URL: $TOUCHSCREEN_SOURCE_URL"
    echo "Touchscreen source commit: $TOUCHSCREEN_SOURCE_REF"
    echo "Source archive contract: $touchscreen_source_contract"
    echo "Source object format: $touchscreen_source_object_format"
    echo "Source modules path: $touchscreen_source_modules_path"
    echo "Source modules tree ID: $touchscreen_source_modules_tree_id"
    echo "Source license path: $touchscreen_source_license_path"
    echo "Source license mode: $touchscreen_source_license_mode"
    echo "Source license blob ID: $touchscreen_source_license_blob_id"
    echo "Kernel config SHA256: $touchscreen_kernel_config_sha256"
    echo "Kernel Module.symvers SHA256: $touchscreen_kernel_module_symvers_sha256"
    echo "Kernel headers input mode: $touchscreen_kernel_headers_input_mode"
    echo "Kernel common headers Deb: $touchscreen_kernel_common_headers_deb"
    echo "Kernel common headers Deb SHA256: $touchscreen_kernel_common_headers_deb_sha256"
    echo "Kernel architecture headers Deb: $touchscreen_kernel_headers_deb"
    echo "Kernel architecture headers Deb SHA256: $touchscreen_kernel_headers_deb_sha256"
    echo "Module compiler identity: $touchscreen_module_compiler_identity"
    echo "Module linker identity: $touchscreen_module_linker_identity"
    echo "Module make identity: $touchscreen_module_make_identity"
    echo "Support repo commit: $repo_commit"
    echo "Support repo dirty: $dirty"
    echo "Required SPI parameter: sp11_windows_se_init"
    module_index=0
    for module_file in "${TOUCHSCREEN_MODULE_FILES[@]}"; do
      echo "Module $module_file name: ${touchscreen_module_names[$module_index]}"
      echo "Module $module_file size: ${touchscreen_module_sizes[$module_index]}"
      echo "Module $module_file SHA256: ${touchscreen_module_shas[$module_index]}"
      echo "Module $module_file vermagic: ${touchscreen_module_vermagic[$module_index]}"
      echo "Module $module_file srcversion: ${touchscreen_module_srcversions[$module_index]}"
      module_index=$((module_index + 1))
    done
  } > "$OUT_DIR/$TOUCHSCREEN_MODULE_MANIFEST"
fi

{
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Build provenance schema: $provenance_schema"
  echo "Release build: $release_build"
  echo "Build completed: $build_completed"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Source mode: ${source_mode:-unknown}"
  echo "Source URL: ${SOURCE_URL:-unknown}"
  echo "Source branch: ${SOURCE_BRANCH:-unknown}"
  echo "Source HEAD: ${source_head:-unknown}"
  echo "Docker image: $DOCKER_IMAGE"
  echo "Container digest: $manifest_container_digest"
  echo "Container platform: $manifest_container_platform"
  echo "Build target: ${build_target:-unknown}"
  echo "Jobs: ${jobs:-unknown}"
  echo "Rules runner: ${rules_runner:-unknown}"
  echo "Patched diff format: $patched_diff_format"
  echo "Patched diff Git version: $patched_diff_git_version"
  echo "Patched diff SHA256: $patched_diff_sha256"
  echo "Patched tree ID: $patched_tree_id"
  echo "Required output roles: $required_output_role_set"
  echo "Optional output roles: $optional_output_role_set"
  echo "Required package roles: $required_deb_role_set"
  echo "Optional package roles: $optional_deb_role_set"
  echo "Signing certificate SHA256: $signing_certificate_sha256"
  echo "Signing certificate fingerprint: $signing_certificate_fingerprint"
  echo "Signing certificate serial: $signing_certificate_serial"
  echo "Package count: ${#debs[@]}"
  package_index=0
  while [ "$package_index" -lt "${#debs[@]}" ]; do
    echo "Package $((package_index + 1)) file: $(basename "${debs[$package_index]}")"
    echo "Package $((package_index + 1)) SHA256: $(shasum -a 256 "$OUT_DIR/$(basename "${debs[$package_index]}")" | awk '{print $1}')"
    package_index=$((package_index + 1))
  done
  if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
    echo "Kernel source archive: $(basename "$KERNEL_SOURCE_ASSET")"
    echo "Kernel source archive SHA256: $KERNEL_SOURCE_ASSET_SHA256"
    echo "Kernel source tree ID: $patched_tree_id"
    if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
      echo "Touchscreen source archive: $(basename "$TOUCHSCREEN_SOURCE_ASSET")"
      echo "Touchscreen source archive SHA256: $TOUCHSCREEN_SOURCE_ASSET_SHA256"
      echo "Touchscreen source commit: $TOUCHSCREEN_SOURCE_REF"
      echo "Touchscreen source modules tree ID: $touchscreen_source_modules_tree_id"
      echo "Touchscreen source license blob ID: $touchscreen_source_license_blob_id"
      echo "Touchscreen kernel config SHA256: $touchscreen_kernel_config_sha256"
      echo "Touchscreen kernel Module.symvers SHA256: $touchscreen_kernel_module_symvers_sha256"
      echo "Touchscreen kernel headers input mode: $touchscreen_kernel_headers_input_mode"
      echo "Touchscreen kernel common headers Deb: $touchscreen_kernel_common_headers_deb"
      echo "Touchscreen kernel common headers Deb SHA256: $touchscreen_kernel_common_headers_deb_sha256"
      echo "Touchscreen kernel architecture headers Deb: $touchscreen_kernel_headers_deb"
      echo "Touchscreen kernel architecture headers Deb SHA256: $touchscreen_kernel_headers_deb_sha256"
      module_index=0
      while [ "$module_index" -lt "${#TOUCHSCREEN_MODULE_FILES[@]}" ]; do
        echo "Touchscreen module ${TOUCHSCREEN_MODULE_FILES[$module_index]} SHA256: ${touchscreen_module_shas[$module_index]}"
        module_index=$((module_index + 1))
      done
    fi
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
support repository commit, and patch checksums.

Recorded source:

- Source URL: \`${SOURCE_URL:-unknown}\`
- Source ref: \`${SOURCE_BRANCH:-unknown}\`
- Source HEAD: \`${source_head:-unknown}\`
EOF

echo "- Docker image: \`$DOCKER_IMAGE\`" >> "$OUT_DIR/RELEASE-NOTES.md"
echo "- Container platform: \`$manifest_container_platform\`" >> "$OUT_DIR/RELEASE-NOTES.md"
echo "- Patched tree ID: \`$patched_tree_id\`" >> "$OUT_DIR/RELEASE-NOTES.md"
echo "- Patched diff SHA256: \`$patched_diff_sha256\`" >> "$OUT_DIR/RELEASE-NOTES.md"

echo "- Ordered patch count: \`$patch_count\`" >> "$OUT_DIR/RELEASE-NOTES.md"

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

if [ "$SOURCE_ASSET_COUNT" -gt 0 ]; then
  public_output_args=(
    --file "$OUT_DIR/sp11-kernel-build-manifest.txt"
    --file "$OUT_DIR/sp11-kernel-release-manifest.txt"
    --file "$OUT_DIR/sp11-kernel-debs.txt"
    --file "$OUT_DIR/RELEASE-NOTES.md"
  )
  if [ "$TOUCHSCREEN_ENABLED" = "true" ]; then
    public_output_args+=(--file "$OUT_DIR/$TOUCHSCREEN_MODULE_MANIFEST")
  fi
  "$public_content_validator" "${public_output_args[@]}"
fi

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

verify_final_support_state
previous_output=""
if [ -e "$FINAL_OUT_DIR" ]; then
  previous_output="$(mktemp -d "$release_root_abs/.${out_leaf}.previous.XXXXXX")"
  rmdir "$previous_output"
  mv "$FINAL_OUT_DIR" "$previous_output"
fi
if ! mv "$OUTPUT_STAGING_DIR" "$FINAL_OUT_DIR"; then
  if [ -n "$previous_output" ] && [ ! -e "$FINAL_OUT_DIR" ]; then
    mv "$previous_output" "$FINAL_OUT_DIR"
  fi
  echo "Could not atomically install the prepared release directory." >&2
  exit 1
fi
OUTPUT_STAGING_DIR=""
OUT_DIR="$FINAL_OUT_DIR"
if [ -n "$previous_output" ]; then
  rm -rf -- "$previous_output"
fi
verify_final_support_state

echo "Prepared release assets in $OUT_DIR_DISPLAY"
echo
if [ "$SOURCE_ASSET_COUNT" -eq 0 ] || [ "$dirty" = "true" ]; then
  echo "This is a local draft only."
  if [ "$SOURCE_ASSET_COUNT" -eq 0 ]; then
    echo "Rerun with --source-asset before publishing binaries."
  fi
  if [ "$dirty" = "true" ]; then
    echo "Rerun from a clean support repository before publishing binaries."
  fi
else
  echo "Review $OUT_DIR_DISPLAY/RELEASE-NOTES.md, then publish with a command like:"
  printf '  (cd %q && gh release create %q --target %q --prerelease --title %q --notes-file RELEASE-NOTES.md' \
    "$OUT_DIR_DISPLAY" "$RELEASE_NAME" "$repo_commit" "$RELEASE_NAME"
  for asset in "${upload_assets[@]}"; do
    printf ' %q' "$asset"
  done
  printf ')\n'
fi
