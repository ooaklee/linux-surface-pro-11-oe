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

IMAGE="build/sp11-ubuntu-live-direct.img"
OUT_DIR=""
RELEASE_NAME=""
VALIDATE_IMAGE="true"
ALLOW_DIRTY="false"
PART_SIZE_BYTES="2000000000"
GITHUB_ASSET_LIMIT_BYTES="2147483648"
KERNEL_SOURCE_ASSET=""
TOUCHSCREEN_SOURCE_ASSET=""
SOURCE_NOTICE=""
KERNEL_BUILD_MANIFEST=""
KERNEL_RELEASE_MANIFEST=""
TOUCHSCREEN_MODULE_MANIFEST=""
IMAGE_BUILD_MANIFEST=""
SOURCE_SNAPSHOT_DIR=""
OUTPUT_STAGING_DIR=""
SOURCE_BINDING_IMAGE="ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03"

MANIFEST_NAME="sp11-live-image-release-manifest.txt"
OUTLINE_NAME="sp11-live-image-outline.txt"
SOURCE_NOTICE_NAME="SOURCE-NOTICE.md"
SOURCE_CHECKSUM_NAME="SOURCE-SHA256SUMS"
IMAGE_BUILD_MANIFEST_NAME="sp11-live-image-build-manifest.txt"

usage() {
  cat <<EOF
Usage: $0 [options]

Prepares a sanitized GitHub Release asset directory for a Surface Pro 11 live
USB raw disk image. It does not publish anything.

Options:
  --image PATH           Raw .img file directly under repository build/,
                         default $IMAGE.
  --release-name NAME    Release/tag name. If omitted, derived from image name.
  --out-dir DIR          Output directory. If omitted, defaults to
                         build/release/<release-name>.
  --skip-validate        Do not run the live-image validator. Intended only for
                         local draft assets.
  --part-size-bytes N    Maximum compressed part size, default
                         $PART_SIZE_BYTES. Must be below GitHub's
                         $GITHUB_ASSET_LIMIT_BYTES byte asset limit.
  --kernel-source-asset PATH
                         Patched kernel corresponding-source .tar.xz archive.
  --touchscreen-source-asset PATH
                         Exact touchscreen-module corresponding-source .tar.xz
                         archive.
  --source-notice PATH   Reviewed source relationship/licence notice. Its
                         basename must be $SOURCE_NOTICE_NAME.
  --kernel-build-manifest PATH
                         Exact schema-v2 release-build manifest.
  --kernel-release-manifest PATH
                         Kernel release manifest matching the image payload.
  --touchscreen-module-manifest PATH
                         Module release manifest matching the image payload.
  --image-build-manifest PATH
                         Exact $IMAGE_BUILD_MANIFEST_NAME generated with the
                         raw image and binding its ISO, DTB, builder, support
                         tree, and output identity.
  --allow-dirty          Allow preparing assets when the support repository has
                         uncommitted changes. Intended for local test runs.
  -h, --help             Show this help.

Output (under build/release/<release-name>/):
  <image>.img.zst.part-*
  $OUTLINE_NAME
  $MANIFEST_NAME
  corresponding-source archives and source checksums for publishable output
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
  local value
  if value="$(stat -f '%z' "$1" 2>/dev/null)"; then
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  fi
  if value="$(stat -c '%s' "$1" 2>/dev/null)"; then
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  fi
  echo "Could not determine a numeric file size: $1" >&2
  return 1
}

single_manifest_value() {
  local file="$1" label="$2"
  awk -v prefix="$label: " '
    index($0, prefix) == 1 {
      count++
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$file"
}

required_manifest_value() {
  local file="$1" label="$2" value
  if ! value="$(single_manifest_value "$file" "$label")"; then
    echo "Manifest must contain exactly one nonempty '$label:' field: $(basename "$file")" >&2
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
  if [ "$current_head" != "$repo_commit" ]; then
    echo "Support repository HEAD changed during image release preparation." >&2
    return 1
  fi
  if ! current_status="$(git status --porcelain --untracked-files=all)"; then
    echo "Could not re-inspect the support repository worktree state." >&2
    return 1
  fi
  if [ "$dirty" = "false" ] && [ -n "$current_status" ]; then
    echo "Support repository became dirty during image release preparation." >&2
    return 1
  fi
}

cleanup_source_snapshot() {
  [ -n "$SOURCE_SNAPSHOT_DIR" ] || return 0
  case "$SOURCE_SNAPSHOT_DIR" in
    "${repo_dir:-}/build/release/.image-source-snapshot."*) rm -rf -- "$SOURCE_SNAPSHOT_DIR" ;;
    *) echo "Warning: refusing to remove unexpected image source snapshot: $SOURCE_SNAPSHOT_DIR" >&2 ;;
  esac
}

cleanup_output_staging() {
  [ -n "$OUTPUT_STAGING_DIR" ] || return 0
  case "$OUTPUT_STAGING_DIR" in
    "${repo_dir:-}/build/release/."*.staging.*) rm -rf -- "$OUTPUT_STAGING_DIR" ;;
    *) echo "Warning: refusing to remove unexpected image release staging directory: $OUTPUT_STAGING_DIR" >&2 ;;
  esac
}
trap 'cleanup_output_staging; cleanup_source_snapshot' EXIT

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
    --kernel-source-asset)
      require_arg "$1" "${2:-}"
      KERNEL_SOURCE_ASSET="$2"
      shift 2
      ;;
    --touchscreen-source-asset)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_SOURCE_ASSET="$2"
      shift 2
      ;;
    --source-notice)
      require_arg "$1" "${2:-}"
      SOURCE_NOTICE="$2"
      shift 2
      ;;
    --kernel-build-manifest)
      require_arg "$1" "${2:-}"
      KERNEL_BUILD_MANIFEST="$2"
      shift 2
      ;;
    --kernel-release-manifest)
      require_arg "$1" "${2:-}"
      KERNEL_RELEASE_MANIFEST="$2"
      shift 2
      ;;
    --touchscreen-module-manifest)
      require_arg "$1" "${2:-}"
      TOUCHSCREEN_MODULE_MANIFEST="$2"
      shift 2
      ;;
    --image-build-manifest)
      require_arg "$1" "${2:-}"
      IMAGE_BUILD_MANIFEST="$2"
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

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"
public_content_validator="$repo_dir/scripts/validate-sp11-public-content.sh"

source_complete="false"
if [ -n "$KERNEL_SOURCE_ASSET" ] || [ -n "$TOUCHSCREEN_SOURCE_ASSET" ] ||
  [ -n "$SOURCE_NOTICE" ]; then
  if [ -z "$KERNEL_SOURCE_ASSET" ] || [ -z "$TOUCHSCREEN_SOURCE_ASSET" ] ||
    [ -z "$SOURCE_NOTICE" ]; then
    echo "Supply --kernel-source-asset, --touchscreen-source-asset, and --source-notice together." >&2
    exit 2
  fi
  source_complete="true"
fi

binding_complete="false"
if [ -n "$KERNEL_BUILD_MANIFEST" ] || [ -n "$KERNEL_RELEASE_MANIFEST" ] ||
  [ -n "$TOUCHSCREEN_MODULE_MANIFEST" ] || [ -n "$IMAGE_BUILD_MANIFEST" ]; then
  if [ -z "$KERNEL_BUILD_MANIFEST" ] || [ -z "$KERNEL_RELEASE_MANIFEST" ] ||
    [ -z "$TOUCHSCREEN_MODULE_MANIFEST" ] || [ -z "$IMAGE_BUILD_MANIFEST" ]; then
    echo "Supply --kernel-build-manifest, --kernel-release-manifest, --touchscreen-module-manifest, and --image-build-manifest together." >&2
    exit 2
  fi
  binding_complete="true"
fi

if [ "$VALIDATE_IMAGE" = "true" ] &&
  { [ "$source_complete" != "true" ] || [ "$binding_complete" != "true" ]; }; then
  echo "Refusing publishable live-image assets without bound corresponding source and payload manifests." >&2
  echo "Pass both source archives, $SOURCE_NOTICE_NAME, and all four manifest inputs; or use --skip-validate for a local draft." >&2
  exit 1
fi
if [ "$VALIDATE_IMAGE" = "true" ]; then
  require_tool cmp
  require_tool docker
  require_tool python3
fi

canonical_source_file() {
  local input_path="$1"
  local input_dir input_base input_abs

  if [ ! -s "$input_path" ] || [ -L "$input_path" ]; then
    echo "Source input must be a non-empty, regular, non-symlinked file: $input_path" >&2
    return 1
  fi
  input_dir="$(cd "$(dirname "$input_path")" && pwd -P)"
  input_base="$(basename "$input_path")"
  input_abs="$input_dir/$input_base"
  case "$input_abs" in
    "$repo_dir"/*) printf '%s\n' "$input_abs" ;;
    *)
      echo "Source input must be inside this repository: $input_path" >&2
      return 1
      ;;
  esac
}

validate_source_basename() {
  case "$1" in
    ""|*[!A-Za-z0-9._+-]*)
      echo "Source input has an unsafe asset basename: $1" >&2
      return 1
      ;;
  esac
}

if [ "$source_complete" = "true" ]; then
  KERNEL_SOURCE_ASSET="$(canonical_source_file "$KERNEL_SOURCE_ASSET")"
  TOUCHSCREEN_SOURCE_ASSET="$(canonical_source_file "$TOUCHSCREEN_SOURCE_ASSET")"
  SOURCE_NOTICE="$(canonical_source_file "$SOURCE_NOTICE")"
  kernel_source_base="$(basename "$KERNEL_SOURCE_ASSET")"
  touchscreen_source_base="$(basename "$TOUCHSCREEN_SOURCE_ASSET")"
  source_notice_base="$(basename "$SOURCE_NOTICE")"

  validate_source_basename "$kernel_source_base"
  validate_source_basename "$touchscreen_source_base"
  validate_source_basename "$source_notice_base"

  [ "$source_notice_base" = "$SOURCE_NOTICE_NAME" ] || {
    echo "Source notice basename must be $SOURCE_NOTICE_NAME, got $source_notice_base." >&2
    exit 2
  }
  case "$kernel_source_base" in
    *patched-source*.tar.xz) ;;
    *)
      echo "Kernel source asset must be a patched-source .tar.xz archive: $kernel_source_base" >&2
      exit 2
      ;;
  esac
  case "$touchscreen_source_base" in
    sp11-touchscreen-modules-source-*.tar.xz) ;;
    *)
      echo "Unexpected touchscreen source archive name: $touchscreen_source_base" >&2
      exit 2
      ;;
  esac
  if [ "$KERNEL_SOURCE_ASSET" = "$TOUCHSCREEN_SOURCE_ASSET" ] ||
    [ "$kernel_source_base" = "$touchscreen_source_base" ]; then
    echo "Kernel and touchscreen source assets must be distinct." >&2
    exit 2
  fi
fi

if [ "$binding_complete" = "true" ]; then
  KERNEL_BUILD_MANIFEST="$(canonical_source_file "$KERNEL_BUILD_MANIFEST")"
  KERNEL_RELEASE_MANIFEST="$(canonical_source_file "$KERNEL_RELEASE_MANIFEST")"
  TOUCHSCREEN_MODULE_MANIFEST="$(canonical_source_file "$TOUCHSCREEN_MODULE_MANIFEST")"
  IMAGE_BUILD_MANIFEST="$(canonical_source_file "$IMAGE_BUILD_MANIFEST")"
  kernel_build_manifest_base="$(basename "$KERNEL_BUILD_MANIFEST")"
  kernel_release_manifest_base="$(basename "$KERNEL_RELEASE_MANIFEST")"
  touchscreen_module_manifest_base="$(basename "$TOUCHSCREEN_MODULE_MANIFEST")"
  image_build_manifest_base="$(basename "$IMAGE_BUILD_MANIFEST")"
  [ "$kernel_build_manifest_base" = "sp11-kernel-build-manifest.txt" ] || {
    echo "Kernel build manifest basename must be sp11-kernel-build-manifest.txt." >&2
    exit 2
  }
  [ "$kernel_release_manifest_base" = "sp11-kernel-release-manifest.txt" ] || {
    echo "Kernel release manifest basename must be sp11-kernel-release-manifest.txt." >&2
    exit 2
  }
  [ "$touchscreen_module_manifest_base" = "sp11-touchscreen-modules-manifest.txt" ] || {
    echo "Touchscreen module manifest basename must be sp11-touchscreen-modules-manifest.txt." >&2
    exit 2
  }
  [ "$image_build_manifest_base" = "$IMAGE_BUILD_MANIFEST_NAME" ] || {
    echo "Image build manifest basename must be $IMAGE_BUILD_MANIFEST_NAME." >&2
    exit 2
  }
  if [ "$KERNEL_BUILD_MANIFEST" = "$KERNEL_RELEASE_MANIFEST" ] ||
    [ "$KERNEL_BUILD_MANIFEST" = "$TOUCHSCREEN_MODULE_MANIFEST" ] ||
    [ "$KERNEL_RELEASE_MANIFEST" = "$TOUCHSCREEN_MODULE_MANIFEST" ] ||
    [ "$IMAGE_BUILD_MANIFEST" = "$KERNEL_BUILD_MANIFEST" ] ||
    [ "$IMAGE_BUILD_MANIFEST" = "$KERNEL_RELEASE_MANIFEST" ] ||
    [ "$IMAGE_BUILD_MANIFEST" = "$TOUCHSCREEN_MODULE_MANIFEST" ]; then
    echo "Image, build, release, and module manifests must be distinct files." >&2
    exit 2
  fi
fi

if [ ! -s "$IMAGE" ] || [ ! -f "$IMAGE" ] || [ -L "$IMAGE" ]; then
  echo "Image must be a non-empty, regular, non-symlinked file: $IMAGE" >&2
  exit 1
fi

image_dir="$(cd "$(dirname "$IMAGE")" && pwd -P)"
image_base="$(basename "$IMAGE")"
case "$image_base" in
  ""|*[!A-Za-z0-9._+-]*)
    echo "Image has an unsafe basename: $image_base" >&2
    exit 1
    ;;
esac
image_abs="$image_dir/$image_base"
if [ ! -s "$image_abs" ] || [ ! -f "$image_abs" ] || [ -L "$image_abs" ]; then
  echo "Image changed while its canonical path was resolved: $IMAGE" >&2
  exit 1
fi
case "$image_abs" in
  "$repo_dir"/*)
    ;;
  *)
    echo "Image must be inside this repository: $IMAGE" >&2
    exit 1
    ;;
esac
build_image_dir="$repo_dir/build"
[ -d "$build_image_dir" ] && [ ! -L "$build_image_dir" ] || {
  echo "Repository build directory must be a regular, non-symlinked directory." >&2
  exit 1
}
build_image_dir="$(cd "$build_image_dir" && pwd -P)"
[ "$image_dir" = "$build_image_dir" ] || {
  echo "Image must be a direct child of the repository build directory." >&2
  exit 1
}
case "$image_base" in
  *.img) ;;
  *) echo "Image must use a .img basename: $image_base" >&2; exit 1 ;;
esac
image_relative="build/$image_base"
case "$image_relative" in
  *[!A-Za-z0-9._+/-]*|*//*|*/../*|../*|*/..|*/./*|./*|*/.)
    echo "Image has an unsafe repository-relative path." >&2
    exit 1
    ;;
esac

if ! repo_commit="$(git rev-parse --verify 'HEAD^{commit}')"; then
  echo "Could not resolve the support repository commit." >&2
  exit 1
fi
dirty="false"
if ! support_status="$(git status --porcelain --untracked-files=all)"; then
  echo "Could not inspect the support repository worktree state." >&2
  exit 1
fi
if [ -n "$support_status" ]; then
  dirty="true"
fi
if [ "$dirty" = "true" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "Refusing to prepare public release assets from a dirty support repository." >&2
  echo "Commit or stash changes first, or pass --allow-dirty for a local test run." >&2
  exit 1
fi

image_stem="${image_base%.img}"
compressed_base="$image_base.zst"

if [ -z "$RELEASE_NAME" ]; then
  RELEASE_NAME="$image_stem"
fi
if ! git check-ref-format "refs/tags/$RELEASE_NAME" >/dev/null 2>&1; then
  echo "Release name is not a valid Git tag: $RELEASE_NAME" >&2
  exit 1
fi
if [ "$VALIDATE_IMAGE" = "true" ] && [ "$source_complete" = "true" ] &&
   [ "$binding_complete" = "true" ] && [ "$dirty" = "false" ]; then
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
      echo "Refusing a publishable image because remote tag $RELEASE_NAME could not be checked on origin." >&2
      echo "Restore remote access and rerun so an existing tag cannot be reused accidentally." >&2
      exit 1
    fi
  else
    echo "Refusing a publishable image because the support repository has no origin remote." >&2
    echo "Configure the public release remote and rerun so an existing tag cannot be missed." >&2
    exit 1
  fi
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

if [ "$source_complete" = "true" ] || [ "$binding_complete" = "true" ]; then
  SOURCE_SNAPSHOT_DIR="$(mktemp -d "$release_root_abs/.image-source-snapshot.XXXXXX")"
  snapshot_inputs=()
  if [ "$source_complete" = "true" ]; then
    snapshot_inputs+=("$KERNEL_SOURCE_ASSET" "$TOUCHSCREEN_SOURCE_ASSET" "$SOURCE_NOTICE")
  fi
  if [ "$binding_complete" = "true" ]; then
    snapshot_inputs+=(
      "$KERNEL_BUILD_MANIFEST"
      "$KERNEL_RELEASE_MANIFEST"
      "$TOUCHSCREEN_MODULE_MANIFEST"
      "$IMAGE_BUILD_MANIFEST"
    )
  fi
  for snapshot_input in "${snapshot_inputs[@]}"; do
    snapshot_base="$(basename "$snapshot_input")"
    if [ -e "$SOURCE_SNAPSHOT_DIR/$snapshot_base" ]; then
      echo "Source or manifest inputs have a colliding basename: $snapshot_base" >&2
      exit 1
    fi
    snapshot_before_sha="$(shasum -a 256 "$snapshot_input" | awk '{print $1}')"
    cp -p "$snapshot_input" "$SOURCE_SNAPSHOT_DIR/$snapshot_base"
    snapshot_after_sha="$(shasum -a 256 "$snapshot_input" | awk '{print $1}')"
    snapshot_copy_sha="$(shasum -a 256 "$SOURCE_SNAPSHOT_DIR/$snapshot_base" | awk '{print $1}')"
    if [ "$snapshot_before_sha" != "$snapshot_after_sha" ] ||
      [ "$snapshot_before_sha" != "$snapshot_copy_sha" ]; then
      echo "Source or manifest input changed while its validation snapshot was created: $snapshot_base" >&2
      exit 1
    fi
  done
  if [ "$source_complete" = "true" ]; then
    KERNEL_SOURCE_ASSET="$SOURCE_SNAPSHOT_DIR/$kernel_source_base"
    TOUCHSCREEN_SOURCE_ASSET="$SOURCE_SNAPSHOT_DIR/$touchscreen_source_base"
    SOURCE_NOTICE="$SOURCE_SNAPSHOT_DIR/$SOURCE_NOTICE_NAME"
  fi
  if [ "$binding_complete" = "true" ]; then
    KERNEL_BUILD_MANIFEST="$SOURCE_SNAPSHOT_DIR/$kernel_build_manifest_base"
    KERNEL_RELEASE_MANIFEST="$SOURCE_SNAPSHOT_DIR/$kernel_release_manifest_base"
    TOUCHSCREEN_MODULE_MANIFEST="$SOURCE_SNAPSHOT_DIR/$touchscreen_module_manifest_base"
    IMAGE_BUILD_MANIFEST="$SOURCE_SNAPSHOT_DIR/$image_build_manifest_base"
  fi
fi

if [ "$source_complete" = "true" ]; then
  kernel_source_snapshot_sha="$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')"
  touchscreen_source_snapshot_sha="$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')"
  source_notice_snapshot_sha="$(shasum -a 256 "$SOURCE_NOTICE" | awk '{print $1}')"
fi
if [ "$binding_complete" = "true" ]; then
  kernel_build_manifest_snapshot_sha="$(shasum -a 256 "$KERNEL_BUILD_MANIFEST" | awk '{print $1}')"
  kernel_release_manifest_snapshot_sha="$(shasum -a 256 "$KERNEL_RELEASE_MANIFEST" | awk '{print $1}')"
  touchscreen_module_manifest_snapshot_sha="$(shasum -a 256 "$TOUCHSCREEN_MODULE_MANIFEST" | awk '{print $1}')"
  image_build_manifest_snapshot_sha="$(shasum -a 256 "$IMAGE_BUILD_MANIFEST" | awk '{print $1}')"
fi

if [ "$VALIDATE_IMAGE" = "true" ]; then
  [ -x "$public_content_validator" ] && [ ! -L "$public_content_validator" ] || {
    echo "Missing executable public-content validator." >&2
    exit 1
  }
  "$public_content_validator" \
    --file "$SOURCE_NOTICE" \
    --file "$KERNEL_BUILD_MANIFEST" \
    --file "$KERNEL_RELEASE_MANIFEST" \
    --file "$TOUCHSCREEN_MODULE_MANIFEST" \
    --file "$IMAGE_BUILD_MANIFEST"
  source_archive_validator="$repo_dir/scripts/validate-sp11-source-archive.py"
  [ -f "$source_archive_validator" ] && [ ! -L "$source_archive_validator" ] || {
    echo "Missing regular source-archive validator: scripts/validate-sp11-source-archive.py" >&2
    exit 1
  }
  release_manifest_validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
  [ -f "$release_manifest_validator" ] && [ ! -L "$release_manifest_validator" ] || {
    echo "Missing regular image release manifest validator." >&2
    exit 1
  }
  support_manifest_helper="$repo_dir/scripts/sp11-support-tree-manifest.py"
  [ -f "$support_manifest_helper" ] && [ ! -L "$support_manifest_helper" ] || {
    echo "Missing regular committed-support manifest helper." >&2
    exit 1
  }
  image_build_manifest_validator="$repo_dir/scripts/validate-sp11-image-build-manifest.py"
  [ -f "$image_build_manifest_validator" ] && [ ! -L "$image_build_manifest_validator" ] || {
    echo "Missing regular image-build manifest validator." >&2
    exit 1
  }
  expected_support_manifest="$SOURCE_SNAPSHOT_DIR/.sp11-support-tree-v1"
  if ! python3 "$support_manifest_helper" \
      --repo-dir "$repo_dir" \
      --commit "$repo_commit" \
      --output "$expected_support_manifest" >/dev/null; then
    echo "Could not derive the exact committed support-tree manifest." >&2
    exit 1
  fi
  expected_embedded_iso_sha="$(required_manifest_value "$IMAGE_BUILD_MANIFEST" "Embedded ISO SHA256")"
  expected_embedded_dtb_sha="$(required_manifest_value "$IMAGE_BUILD_MANIFEST" "Embedded DTB SHA256")"
  manifest_expected_payload="$SOURCE_SNAPSHOT_DIR/manifest-expected-payload-sha256"
  if ! python3 "$release_manifest_validator" \
      --require-current-head \
      --repo-dir "$repo_dir" \
      --support-commit "$repo_commit" \
      --release-name "$RELEASE_NAME" \
      --kernel-build-manifest "$KERNEL_BUILD_MANIFEST" \
      --kernel-release-manifest "$KERNEL_RELEASE_MANIFEST" \
      --touchscreen-module-manifest "$TOUCHSCREEN_MODULE_MANIFEST" \
      --kernel-source "$KERNEL_SOURCE_ASSET" \
      --touchscreen-source "$TOUCHSCREEN_SOURCE_ASSET" \
      --expected-payload-out "$manifest_expected_payload"; then
    echo "Release manifests failed the complete schema-v2 image binding contract." >&2
    exit 1
  fi

  build_schema="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Provenance schema")"
  build_release="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Release build")"
  build_completed="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Build completed")"
  build_support_start="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Support start HEAD")"
  build_support_end="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Support end HEAD")"
  build_source_head="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Source HEAD")"
  build_patched_tree="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Patched tree ID")"
  build_output_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Output count")"
  build_deb_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Deb count")"
  if [ "$build_schema" != "sp11-kernel-build-v2" ] || [ "$build_release" != "true" ] ||
    [ "$build_completed" != "true" ] || [ "$build_support_start" != "$build_support_end" ] ||
    ! [[ "$build_support_start" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$build_source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$build_patched_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$build_output_count" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$build_deb_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Kernel build manifest is not complete schema-v2 release provenance." >&2
    exit 1
  fi
  if [ "$build_support_start" != "$repo_commit" ]; then
    echo "Kernel build provenance support commit does not match current support HEAD." >&2
    exit 1
  fi
  build_kernel_config_sha=""
  build_kernel_symvers_sha=""
  build_kernel_dtb_sha=""
  binding_index=1
  while [ "$binding_index" -le "$build_output_count" ]; do
    build_output_role="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Output $binding_index role")"
    build_output_sha="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Output $binding_index SHA256")"
    [[ "$build_output_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Kernel build manifest output $binding_index has an invalid SHA-256." >&2
      exit 1
    }
    if [ "$build_output_role" = "kernel-config" ]; then
      [ -z "$build_kernel_config_sha" ] || {
        echo "Kernel build manifest contains duplicate kernel-config outputs." >&2
        exit 1
      }
      build_kernel_config_sha="$build_output_sha"
    elif [ "$build_output_role" = "module-symvers" ]; then
      [ -z "$build_kernel_symvers_sha" ] || {
        echo "Kernel build manifest contains duplicate module-symvers outputs." >&2
        exit 1
      }
      build_kernel_symvers_sha="$build_output_sha"
    elif [ "$build_output_role" = "denali-oled-dtb" ]; then
      [ -z "$build_kernel_dtb_sha" ] || {
        echo "Kernel build manifest contains duplicate denali-oled-dtb outputs." >&2
        exit 1
      }
      build_kernel_dtb_sha="$build_output_sha"
    fi
    binding_index=$((binding_index + 1))
  done
  [ -n "$build_kernel_config_sha" ] || {
    echo "Kernel build manifest is missing its kernel-config output identity." >&2
    exit 1
  }
  [ -n "$build_kernel_symvers_sha" ] || {
    echo "Kernel build manifest is missing its Module.symvers output identity." >&2
    exit 1
  }
  [ -n "$build_kernel_dtb_sha" ] || {
    echo "Kernel build manifest is missing its denali-oled-dtb output identity." >&2
    exit 1
  }
  if ! python3 "$image_build_manifest_validator" \
      --manifest "$IMAGE_BUILD_MANIFEST" \
      --image "$image_abs" \
      --support-commit "$repo_commit" \
      --support-manifest "$expected_support_manifest" \
      --expected-kernel-dtb-sha256 "$build_kernel_dtb_sha"; then
    echo "Image-build provenance does not bind the raw image to its committed inputs." >&2
    exit 1
  fi
  build_deb_names=()
  build_deb_shas=()
  build_deb_seen_count=0
  binding_index=1
  while [ "$binding_index" -le "$build_deb_count" ]; do
    build_deb_name="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Deb $binding_index path")"
    build_deb_sha="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Deb $binding_index SHA256")"
    case "$build_deb_name" in
      linux-*.deb) ;;
      *) echo "Kernel build manifest has an unsafe package path: $build_deb_name" >&2; exit 1 ;;
    esac
    case "$build_deb_name" in
      */*|*[!A-Za-z0-9._+-]*) echo "Kernel build manifest has an unsafe package path: $build_deb_name" >&2; exit 1 ;;
    esac
    [[ "$build_deb_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Kernel build manifest package has an invalid SHA-256: $build_deb_name" >&2
      exit 1
    }
    existing_deb_index=0
    while [ "$existing_deb_index" -lt "$build_deb_seen_count" ]; do
      [ "${build_deb_names[$existing_deb_index]}" != "$build_deb_name" ] || {
        echo "Kernel build manifest repeats package $build_deb_name." >&2
        exit 1
      }
      existing_deb_index=$((existing_deb_index + 1))
    done
    build_deb_names[$build_deb_seen_count]="$build_deb_name"
    build_deb_shas[$build_deb_seen_count]="$build_deb_sha"
    build_deb_seen_count=$((build_deb_seen_count + 1))
    binding_index=$((binding_index + 1))
  done

  release_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build provenance schema")"
  bound_kernel_release_name="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Release")"
  release_build="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Release build")"
  release_completed="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build completed")"
  release_support="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Support repo commit")"
  release_source_head="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Source HEAD")"
  release_patched_tree="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Patched tree ID")"
  release_kernel_source="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel source archive")"
  release_kernel_source_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel source archive SHA256")"
  release_kernel_source_tree="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel source tree ID")"
  release_touch_source="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen source archive")"
  release_touch_source_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen source archive SHA256")"
  release_touch_commit="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen source commit")"
  release_touch_tree="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen source modules tree ID")"
  release_touch_license="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen source license blob ID")"
  release_touch_headers_mode="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen kernel headers input mode")"
  release_package_count="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Package count")"
  if [ "$release_schema" != "$build_schema" ] || [ "$release_build" != "true" ] ||
    [ "$release_completed" != "true" ] || [ "$release_support" != "$build_support_start" ] ||
    [ "$release_source_head" != "$build_source_head" ] ||
    [ "$release_patched_tree" != "$build_patched_tree" ] ||
    [ "$release_kernel_source_tree" != "$build_patched_tree" ] ||
    [ "$release_kernel_source" != "$kernel_source_base" ] ||
    [ "$release_touch_source" != "$touchscreen_source_base" ] ||
    [ "$release_touch_headers_mode" != "extracted-debs-v1" ] ||
    ! [[ "$release_kernel_source_sha" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$release_touch_source_sha" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$release_touch_commit" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$release_touch_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$release_touch_license" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$release_package_count" =~ ^[1-9][0-9]*$ ]] ||
    [ "$release_package_count" -ne "$build_deb_count" ]; then
    echo "Kernel release manifest does not match its schema-v2 build/source identities." >&2
    exit 1
  fi
  actual_kernel_source_sha="$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')"
  actual_touch_source_sha="$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')"
  if [ "$actual_kernel_source_sha" != "$release_kernel_source_sha" ] ||
    [ "$actual_touch_source_sha" != "$release_touch_source_sha" ]; then
    echo "Corresponding-source archive SHA-256 does not match the kernel release manifest." >&2
    exit 1
  fi

  module_contract="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source archive contract")"
  bound_module_release_name="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Release")"
  module_object_format="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source object format")"
  module_source_commit="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Touchscreen source commit")"
  module_source_path="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source modules path")"
  module_source_tree="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source modules tree ID")"
  module_license_path="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source license path")"
  module_license_mode="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source license mode")"
  module_license_blob="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Source license blob ID")"
  module_kernel_config_sha="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Kernel config SHA256")"
  module_kernel_symvers_sha="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Kernel Module.symvers SHA256")"
  module_kernel_headers_mode="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Kernel headers input mode")"
  if [ "$module_contract" != "sp11-touchscreen-source-v1" ] ||
    [ "$bound_module_release_name" != "$bound_kernel_release_name" ] ||
    { [ "$module_object_format" != "sha1" ] && [ "$module_object_format" != "sha256" ]; } ||
    [ "$module_source_commit" != "$release_touch_commit" ] ||
    [ "$module_source_path" != "phase55/modules" ] ||
    [ "$module_source_tree" != "$release_touch_tree" ] ||
    [ "$module_license_path" != "LICENSE" ] || [ "$module_license_mode" != "100644" ] ||
    [ "$module_license_blob" != "$release_touch_license" ] ||
    [ "$module_kernel_config_sha" != "$build_kernel_config_sha" ] ||
    [ "$module_kernel_symvers_sha" != "$build_kernel_symvers_sha" ] ||
    [ "$module_kernel_headers_mode" != "extracted-debs-v1" ] ||
    [ "$module_kernel_headers_mode" != "$release_touch_headers_mode" ]; then
    echo "Touchscreen module manifest does not match the kernel/source identity contract." >&2
    exit 1
  fi

  if ! python3 "$source_archive_validator" kernel \
      --archive "$KERNEL_SOURCE_ASSET" --expected-tree "$build_patched_tree"; then
    echo "Kernel source archive failed exact-tree validation." >&2
    exit 1
  fi
  if ! python3 "$source_archive_validator" touchscreen \
      --archive "$TOUCHSCREEN_SOURCE_ASSET" \
      --expected-modules-tree "$module_source_tree" \
      --expected-license-blob "$module_license_blob" \
      --license-mode "$module_license_mode" \
      --expected-archive-comment "$module_source_commit"; then
    echo "Touchscreen source archive failed exact-subtree validation." >&2
    exit 1
  fi

  shell_expected_payload="$SOURCE_SNAPSHOT_DIR/shell-expected-payload-sha256"
  : > "$shell_expected_payload"
  expected_payload_names=""
  binding_index=1
  while [ "$binding_index" -le "$release_package_count" ]; do
    payload_name="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Package $binding_index file")"
    payload_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Package $binding_index SHA256")"
    case "$payload_name" in
      linux-*.deb) ;;
      *) echo "Kernel release manifest has an unsafe package filename: $payload_name" >&2; exit 1 ;;
    esac
    case "$payload_name" in
      *[!A-Za-z0-9._+-]*) echo "Kernel release manifest has an unsafe package filename: $payload_name" >&2; exit 1 ;;
    esac
    [[ "$payload_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Kernel release package has an invalid SHA-256: $payload_name" >&2
      exit 1
    }
    matched_build_deb="false"
    build_deb_index=0
    while [ "$build_deb_index" -lt "$build_deb_seen_count" ]; do
      if [ "${build_deb_names[$build_deb_index]}" = "$payload_name" ] &&
        [ "${build_deb_shas[$build_deb_index]}" = "$payload_sha" ]; then
        matched_build_deb="true"
        break
      fi
      build_deb_index=$((build_deb_index + 1))
    done
    [ "$matched_build_deb" = "true" ] || {
      echo "Kernel release package does not match schema-v2 build provenance: $payload_name" >&2
      exit 1
    }
    case " $expected_payload_names " in
      *" $payload_name "*) echo "Kernel release manifest repeats package $payload_name." >&2; exit 1 ;;
    esac
    expected_payload_names="$expected_payload_names $payload_name"
    printf '%s  %s\n' "$payload_sha" "$payload_name" >> "$shell_expected_payload"
    binding_index=$((binding_index + 1))
  done
  for payload_name in gpi.ko spi-geni-qcom.ko mshw0485_touch.ko; do
    payload_sha="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $payload_name SHA256")"
    release_payload_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Touchscreen module $payload_name SHA256")"
    [[ "$payload_sha" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Touchscreen module manifest has an invalid SHA-256: $payload_name" >&2
      exit 1
    }
    [ "$payload_sha" = "$release_payload_sha" ] || {
      echo "Touchscreen module hash differs between kernel and module release manifests: $payload_name" >&2
      exit 1
    }
    printf '%s  %s\n' "$payload_sha" "$payload_name" >> "$shell_expected_payload"
  done
  printf '%s  %s\n' \
    "$touchscreen_module_manifest_snapshot_sha" \
    "$touchscreen_module_manifest_base" >> "$shell_expected_payload"
  if ! cmp -s "$manifest_expected_payload" "$shell_expected_payload"; then
    echo "Independent image payload identity derivations disagree." >&2
    exit 1
  fi
  expected_payload="$manifest_expected_payload"

  image_binding_log="$SOURCE_SNAPSHOT_DIR/image-payload-binding.log"
  payload_output_dir="$SOURCE_SNAPSHOT_DIR/payload-output"
  mkdir "$payload_output_dir"
  payload_identity_validator="$repo_dir/scripts/validate-sp11-payload-identity-list.sh"
  [ -x "$payload_identity_validator" ] && [ ! -L "$payload_identity_validator" ] || {
    echo "Missing executable payload-identity validator." >&2
    exit 1
  }
  bound_image_sha="$(shasum -a 256 "$image_abs" | awk '{print $1}')"
  image_binding_extractor="$repo_dir/scripts/extract-sp11-image-bindings.sh"
  [ -f "$image_binding_extractor" ] && [ ! -L "$image_binding_extractor" ] || {
    echo "Missing regular raw-image binding extractor." >&2
    exit 1
  }
  if ! docker run --rm -i --platform linux/arm64/v8 \
      -v "$image_abs:/image/source.img:ro" \
      -v "$payload_output_dir:/payload-output" \
      -v "$image_binding_extractor:/validator/extract-sp11-image-bindings.sh:ro" \
      "$SOURCE_BINDING_IMAGE" bash -s >"$image_binding_log" 2>&1 <<'IMAGE_BINDING_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends coreutils gdisk parted sleuthkit >/dev/null
bash /validator/extract-sp11-image-bindings.sh \
  --image /image/source.img --output-dir /payload-output
binding_output_count=0
for binding_output_name in \
  actual-payload-sha256 \
  embedded-support-manifest \
  actual-support-identities \
  actual-image-layout \
  actual-embedded-iso-sha256 \
  actual-embedded-dtb-sha256 \
  actual-esp-boot-size \
  actual-esp-boot-sha256 \
  actual-esp-readme-size \
  actual-esp-readme-sha256; do
  binding_output="/payload-output/$binding_output_name"
  [ -f "$binding_output" ] && [ ! -L "$binding_output" ] || {
    echo "Image binding extractor produced an unsafe output: $binding_output_name" >&2
    exit 1
  }
  chmod 0644 "$binding_output"
  binding_output_count=$((binding_output_count + 1))
done
[ "$(find /payload-output -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" = \
  "$binding_output_count" ] || {
    echo 'Image binding extractor produced an unexpected output.' >&2
    exit 1
  }
IMAGE_BINDING_EOF
  then
    cat "$image_binding_log" >&2
    echo "Could not extract actual image payload identities." >&2
    exit 1
  fi
  if ! "$payload_identity_validator" \
      --expected "$expected_payload" \
      --actual "$payload_output_dir/actual-payload-sha256" \
      >> "$image_binding_log" 2>&1; then
    cat "$image_binding_log" >&2
    echo "Could not prove that the image payload matches the supplied release manifests." >&2
    exit 1
  fi
  if ! python3 "$support_manifest_helper" \
      --repo-dir "$repo_dir" \
      --commit "$repo_commit" \
      --verify-manifest "$payload_output_dir/embedded-support-manifest" \
      --actual-identities "$payload_output_dir/actual-support-identities" \
      >> "$image_binding_log" 2>&1; then
    cat "$image_binding_log" >&2
    echo "Could not prove that the embedded /support tree matches the release commit." >&2
    exit 1
  fi
  if ! python3 "$image_build_manifest_validator" \
      --manifest "$IMAGE_BUILD_MANIFEST" \
      --image "$image_abs" \
      --support-commit "$repo_commit" \
      --support-manifest "$expected_support_manifest" \
      --expected-kernel-dtb-sha256 "$build_kernel_dtb_sha" \
      --actual-layout "$payload_output_dir/actual-image-layout" \
      >> "$image_binding_log" 2>&1; then
    cat "$image_binding_log" >&2
    echo "Raw GPT/ESP identities differ from the image-build manifest." >&2
    exit 1
  fi
  actual_embedded_iso_sha="$(sed -n '1p' "$payload_output_dir/actual-embedded-iso-sha256")"
  actual_embedded_dtb_sha="$(sed -n '1p' "$payload_output_dir/actual-embedded-dtb-sha256")"
  if [ "$actual_embedded_iso_sha" != "$expected_embedded_iso_sha" ] ||
    [ "$actual_embedded_dtb_sha" != "$expected_embedded_dtb_sha" ]; then
    echo "Raw image ISO or DTB identity differs from the image-build manifest." >&2
    exit 1
  fi
  if [ "$(shasum -a 256 "$image_abs" | awk '{print $1}')" != "$bound_image_sha" ]; then
    echo "Image changed while its embedded payload identities were validated." >&2
    exit 1
  fi
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

FINAL_OUT_DIR="$OUT_DIR"
OUTPUT_STAGING_DIR="$(mktemp -d "$release_root_abs/.${out_leaf}.staging.XXXXXX")"
OUT_DIR="$OUTPUT_STAGING_DIR"

outline="$OUT_DIR/$OUTLINE_NAME"
if [ "$VALIDATE_IMAGE" = "true" ]; then
  outline_raw="$OUT_DIR/$OUTLINE_NAME.raw"
  if ! ./scripts/build-sp11-live-usb-image.sh \
    --validate-image "$image_relative" >"$outline_raw" 2>&1; then
    echo "Image validation failed. See $OUT_DIR_DISPLAY/$OUTLINE_NAME.raw." >&2
    exit 1
  fi
  sed_image_base="${image_base//./\\.}"
  sed -E \
    -e "s#/image/$sed_image_base#$image_base#g" \
    -e 's#/tmp/tmp\.[[:alnum:]_.-]+#<validation-temp-file>#g' \
    "$outline_raw" > "$outline"
  rm -f "$outline_raw"
else
  {
    echo "Image validation was skipped."
    echo "Run:"
    echo "  ./scripts/build-sp11-live-usb-image.sh --validate-image $image_relative"
  } > "$outline"
fi

generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
image_size="$(file_size "$image_abs")"
image_sha="$(shasum -a 256 "$image_abs" | awk '{print $1}')"
if [ "$VALIDATE_IMAGE" = "true" ] && [ "$image_sha" != "$bound_image_sha" ]; then
  echo "Image changed after embedded payload validation." >&2
  exit 1
fi
outline_sha="$(shasum -a 256 "$outline" | awk '{print $1}')"
compressed_tmp="$OUT_DIR/$compressed_base"

zstd -T0 -6 --force -o "$compressed_tmp" "$image_abs"
if [ "$(shasum -a 256 "$image_abs" | awk '{print $1}')" != "$image_sha" ]; then
  echo "Image changed while the release archive was compressed." >&2
  exit 1
fi
decompressed_sha="$(zstd -dc "$compressed_tmp" | shasum -a 256 | awk '{print $1}')"
if [ "$decompressed_sha" != "$image_sha" ]; then
  echo "Compressed release archive does not reconstruct the validated image bytes." >&2
  exit 1
fi
compressed_size="$(file_size "$compressed_tmp")"
compressed_sha="$(shasum -a 256 "$compressed_tmp" | awk '{print $1}')"

split -b "$PART_SIZE_BYTES" "$compressed_tmp" "$OUT_DIR/$compressed_base.part-"
rm -f "$compressed_tmp"

parts=()
parts_count=0
while IFS= read -r part; do
  parts[$parts_count]="$part"
  parts_count=$((parts_count + 1))
done < <(find "$OUT_DIR" -maxdepth 1 -type f -name "$compressed_base.part-*" | sort)

if [ "$parts_count" -eq 0 ]; then
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

if [ "$source_complete" = "true" ]; then
  mv "$KERNEL_SOURCE_ASSET" "$OUT_DIR/$kernel_source_base"
  mv "$TOUCHSCREEN_SOURCE_ASSET" "$OUT_DIR/$touchscreen_source_base"
  mv "$SOURCE_NOTICE" "$OUT_DIR/$SOURCE_NOTICE_NAME"
  KERNEL_SOURCE_ASSET="$OUT_DIR/$kernel_source_base"
  TOUCHSCREEN_SOURCE_ASSET="$OUT_DIR/$touchscreen_source_base"
  SOURCE_NOTICE="$OUT_DIR/$SOURCE_NOTICE_NAME"
  if [ "$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')" != "$kernel_source_snapshot_sha" ] ||
    [ "$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')" != "$touchscreen_source_snapshot_sha" ] ||
    [ "$(shasum -a 256 "$SOURCE_NOTICE" | awk '{print $1}')" != "$source_notice_snapshot_sha" ]; then
    echo "Staged corresponding-source inputs changed after validation." >&2
    exit 1
  fi
  source_checksum_inputs=("$kernel_source_base" "$touchscreen_source_base" "$SOURCE_NOTICE_NAME")
  if [ "$binding_complete" = "true" ]; then
    mv "$KERNEL_BUILD_MANIFEST" "$OUT_DIR/$kernel_build_manifest_base"
    mv "$KERNEL_RELEASE_MANIFEST" "$OUT_DIR/$kernel_release_manifest_base"
    mv "$TOUCHSCREEN_MODULE_MANIFEST" "$OUT_DIR/$touchscreen_module_manifest_base"
    mv "$IMAGE_BUILD_MANIFEST" "$OUT_DIR/$image_build_manifest_base"
    KERNEL_BUILD_MANIFEST="$OUT_DIR/$kernel_build_manifest_base"
    KERNEL_RELEASE_MANIFEST="$OUT_DIR/$kernel_release_manifest_base"
    TOUCHSCREEN_MODULE_MANIFEST="$OUT_DIR/$touchscreen_module_manifest_base"
    IMAGE_BUILD_MANIFEST="$OUT_DIR/$image_build_manifest_base"
    if [ "$(shasum -a 256 "$KERNEL_BUILD_MANIFEST" | awk '{print $1}')" != "$kernel_build_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$KERNEL_RELEASE_MANIFEST" | awk '{print $1}')" != "$kernel_release_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$TOUCHSCREEN_MODULE_MANIFEST" | awk '{print $1}')" != "$touchscreen_module_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$IMAGE_BUILD_MANIFEST" | awk '{print $1}')" != "$image_build_manifest_snapshot_sha" ]; then
      echo "Staged source-binding manifests changed after validation." >&2
      exit 1
    fi
    source_checksum_inputs+=(
      "$kernel_build_manifest_base"
      "$kernel_release_manifest_base"
      "$touchscreen_module_manifest_base"
      "$image_build_manifest_base"
    )
  fi
  (
    cd "$OUT_DIR"
    shasum -a 256 "${source_checksum_inputs[@]}" > "$SOURCE_CHECKSUM_NAME"
  )
fi

{
  echo "# Surface Pro 11 Live Image Release Manifest"
  echo
  echo "Generated: $generated_at"
  echo "Release: $RELEASE_NAME"
  echo "Support repo commit: $repo_commit"
  echo "Support repo dirty: $dirty"
  echo "Image source: $image_relative"
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
  echo
  echo "## Corresponding Source"
  echo
  if [ "$source_complete" = "true" ]; then
    for source_file in "$kernel_source_base" "$touchscreen_source_base"; do
      echo "- $source_file"
      echo "  - Size: $(file_size "$OUT_DIR/$source_file") bytes"
      echo "  - SHA256: $(shasum -a 256 "$OUT_DIR/$source_file" | awk '{print $1}')"
    done
    echo "- $SOURCE_NOTICE_NAME"
    echo "  - SHA256: $(shasum -a 256 "$OUT_DIR/$SOURCE_NOTICE_NAME" | awk '{print $1}')"
    if [ "$binding_complete" = "true" ]; then
      for binding_file in \
        "$kernel_build_manifest_base" \
        "$kernel_release_manifest_base" \
        "$touchscreen_module_manifest_base" \
        "$image_build_manifest_base"; do
        echo "- $binding_file"
        echo "  - SHA256: $(shasum -a 256 "$OUT_DIR/$binding_file" | awk '{print $1}')"
      done
    fi
  else
    echo "- Not included; this output is a local draft and cannot be published."
  fi
} > "$OUT_DIR/$MANIFEST_NAME"

(
  cd "$OUT_DIR"
  checksum_inputs=("$compressed_base".part-* "$OUTLINE_NAME" "$MANIFEST_NAME")
  if [ "$source_complete" = "true" ]; then
    checksum_inputs+=(
      "$SOURCE_NOTICE_NAME"
      "$SOURCE_CHECKSUM_NAME"
      "$kernel_source_base"
      "$touchscreen_source_base"
    )
    if [ "$binding_complete" = "true" ]; then
      checksum_inputs+=(
        "$kernel_build_manifest_base"
        "$kernel_release_manifest_base"
        "$touchscreen_module_manifest_base"
        "$image_build_manifest_base"
      )
    fi
  fi
  shasum -a 256 "${checksum_inputs[@]}" > SHA256SUMS
)

cat > "$OUT_DIR/RELEASE-NOTES.md" <<RELEASE_NOTES_END
# Surface Pro 11 Live USB Image

Experimental direct-boot Ubuntu live USB raw disk image for Surface Pro 11.

This image is an optional convenience artifact. It is not signed, is not an
installer ISO, and should be written only to the intended removable device.

## Installed-system payloads

The live environment boots the concept ISO's casper kernel. A custom kernel or
module bundle stored under \`SP11DATA/payload/kernel-debs\` is available only to
the guarded installed-system flow; it does not replace the live-session kernel.
Check \`$OUTLINE_NAME\` for the exact payload carried by this image.

## Verify

\`\`\`bash
shasum -a 256 -c SHA256SUMS
$(if [ "$source_complete" = "true" ]; then printf 'shasum -a 256 -c %s\n' "$SOURCE_CHECKSUM_NAME"; fi)
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
TARGET_DEVICE=/dev/REPLACE_WITH_REMOVABLE_DEVICE
sudo dd if=$image_base of="\$TARGET_DEVICE" bs=16M conv=fsync status=progress
\`\`\`

Resolve and double-check the removable-device path before writing. This command
overwrites the destination disk.

## Image Outline

The release includes \`$OUTLINE_NAME\`, generated by:

\`\`\`bash
./scripts/build-sp11-live-usb-image.sh --validate-image $image_base
\`\`\`

Paths shown by the outline belong to its disposable validation environment;
they are not host setup instructions.

## Corresponding Source

$(if [ "$source_complete" = "true" ]; then
  printf '%s\n' \
    "The release includes \`$kernel_source_base\`," \
    "\`$touchscreen_source_base\`, \`$SOURCE_NOTICE_NAME\`, and" \
    "\`$SOURCE_CHECKSUM_NAME\`. The supplied image-build, kernel-build," \
    "kernel-release, and module manifests cryptographically bind those archives," \
    "the embedded ISO/DTB/support tree, and the image payload." \
    "Together they cover the patched kernel and exact" \
    "source/build-control files for the three touchscreen modules embedded in the" \
    "image."
else
  printf '%s\n' "Corresponding source is not included. This output is a local draft only."
fi)

## Provenance

See \`$MANIFEST_NAME\` for image size, checksum, support repository commit, and
validation status. The raw image is intentionally split into compressed parts
because GitHub release assets must be smaller than $GITHUB_ASSET_LIMIT_BYTES
bytes each.

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible.
RELEASE_NOTES_END

if [ "$VALIDATE_IMAGE" = "true" ]; then
  public_output_args=(
    --file "$OUT_DIR/$OUTLINE_NAME"
    --file "$OUT_DIR/$MANIFEST_NAME"
    --file "$OUT_DIR/$SOURCE_NOTICE_NAME"
    --file "$OUT_DIR/$SOURCE_CHECKSUM_NAME"
    --file "$OUT_DIR/$kernel_build_manifest_base"
    --file "$OUT_DIR/$kernel_release_manifest_base"
    --file "$OUT_DIR/$touchscreen_module_manifest_base"
    --file "$OUT_DIR/$image_build_manifest_base"
    --file "$OUT_DIR/SHA256SUMS"
    --file "$OUT_DIR/RELEASE-NOTES.md"
  )
  "$public_content_validator" "${public_output_args[@]}"
fi

release_assets=(
  "$OUTLINE_NAME"
  "$MANIFEST_NAME"
  "SHA256SUMS"
)
if [ "$source_complete" = "true" ]; then
  release_assets+=(
    "$SOURCE_NOTICE_NAME"
    "$SOURCE_CHECKSUM_NAME"
    "$kernel_source_base"
    "$touchscreen_source_base"
  )
  if [ "$binding_complete" = "true" ]; then
    release_assets+=(
      "$kernel_build_manifest_base"
      "$kernel_release_manifest_base"
      "$touchscreen_module_manifest_base"
      "$image_build_manifest_base"
    )
  fi
fi
for part in "${parts[@]}"; do
  release_assets+=("$(basename "$part")")
done

if ! (cd "$OUT_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null); then
  echo "Prepared image release assets do not match their final SHA256SUMS." >&2
  exit 1
fi
if [ "$source_complete" = "true" ] &&
   ! (cd "$OUT_DIR" && shasum -a 256 -c "$SOURCE_CHECKSUM_NAME" >/dev/null); then
  echo "Prepared image source assets do not match their final $SOURCE_CHECKSUM_NAME." >&2
  exit 1
fi

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
  echo "Could not atomically install the prepared image release directory." >&2
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
if [ "$VALIDATE_IMAGE" != "true" ] || [ "$source_complete" != "true" ] ||
  [ "$dirty" != "false" ]; then
  echo "Local draft only: validation, complete source, and a clean support tree are required before publication."
  exit 0
fi
echo "Review $OUT_DIR_DISPLAY/RELEASE-NOTES.md, then publish with a command like:"
printf '  (cd %q && gh release create %q --target %q --prerelease --title %q --notes-file RELEASE-NOTES.md' \
  "$OUT_DIR_DISPLAY" "$RELEASE_NAME" "$repo_commit" "$RELEASE_NAME"
for asset in "${release_assets[@]}"; do
  printf ' %q' "$asset"
done
printf ')\n'
