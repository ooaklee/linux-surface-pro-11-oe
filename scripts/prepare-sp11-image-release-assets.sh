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
APT_PROVENANCE=""
BUILD_INPUTS=""
TOUCHSCREEN_MODULE_MANIFEST=""
TOUCHSCREEN_SIGNING_CERTIFICATE=""
KERNEL_SIGNATURE_REPORT=""
IMAGE_BUILD_MANIFEST=""
SOURCE_SNAPSHOT_DIR=""
IMAGE_SNAPSHOT_DIR=""
IMAGE_SNAPSHOT=""
OUTPUT_STAGING_DIR=""
OUTPUT_STAGING_IDENTITY=""
OUTPUT_STAGING_TREE=""
OUTPUT_INSTALL_PENDING="false"
INSTALLED_OUTPUT_IDENTITY=""
INSTALLED_OUTPUT_TREE=""
PREVIOUS_OUTPUT_CONTAINER=""
PREVIOUS_OUTPUT_CONTAINER_IDENTITY=""
PREVIOUS_OUTPUT_PATH=""
PREVIOUS_OUTPUT_IDENTITY=""
PREVIOUS_OUTPUT_TREE=""
SOURCE_BINDING_IMAGE="ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03"
KERNEL_CANDIDATE_ROOT_FD=55
KERNEL_CANDIDATE_ROOT=""
KERNEL_CANDIDATE_ROOT_STATE=""

MANIFEST_NAME="sp11-live-image-release-manifest.txt"
OUTLINE_NAME="sp11-live-image-outline.txt"
SOURCE_NOTICE_NAME="SOURCE-NOTICE.md"
SOURCE_CHECKSUM_NAME="SOURCE-SHA256SUMS"
IMAGE_BUILD_MANIFEST_NAME="sp11-live-image-build-manifest.txt"
APT_PROVENANCE_NAME="sp11-kernel-apt-provenance.txt"
BUILD_INPUTS_NAME="sp11-kernel-build-inputs.txt"
TOUCHSCREEN_SIGNING_CERTIFICATE_NAME="sp11-module-signing-cert.x509"
KERNEL_SIGNATURE_REPORT_NAME="sp11-kernel-module-signatures.txt"
MODULE_SIGNING_POLICY="sp11-controlled-rsa4096-sha512-v1"

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
  --apt-provenance PATH   Exact $APT_PROVENANCE_NAME v1 sidecar from the same
                         immutable release build.
  --build-inputs PATH     Exact $BUILD_INPUTS_NAME v1 envelope from the same
                         immutable release build.
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
  corresponding-source archives and source checksums for validation-complete output
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

kernel_candidate_root_state() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

descriptor = os.open(
    sys.argv[1],
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
)
try:
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[1], follow_symlinks=False)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
        value.st_uid,
        value.st_gid,
    )
    if (
        not stat.S_ISDIR(held.st_mode)
        or stat.S_IMODE(held.st_mode) != 0o500
        or held.st_uid != os.geteuid()
        or stable(held) != stable(mapped)
    ):
        raise RuntimeError
    print(*stable(held))
finally:
    os.close(descriptor)
' "$1"
}

verify_kernel_candidate_root() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

expected = tuple(int(value, 10) for value in sys.argv[3:12])
held = os.fstat(int(sys.argv[1], 10))
mapped = os.stat(sys.argv[2], follow_symlinks=False)
stable = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_mode,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
    value.st_nlink,
    value.st_uid,
    value.st_gid,
)
if (
    not stat.S_ISDIR(held.st_mode)
    or stat.S_IMODE(held.st_mode) != 0o500
    or held.st_uid != os.geteuid()
    or stable(held) != expected
    or stable(mapped) != expected
):
    raise SystemExit(1)
' "$KERNEL_CANDIDATE_ROOT_FD" "$KERNEL_CANDIDATE_ROOT" \
    $KERNEL_CANDIDATE_ROOT_STATE
}

verify_kernel_candidate_member() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

root = int(sys.argv[1], 10)
root_path = sys.argv[2]
path = sys.argv[3]
name = os.path.basename(path)
if not name or path != os.path.join(root_path, name):
    raise SystemExit(1)
descriptor = os.open(
    name,
    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
    dir_fd=root,
)
try:
    held = os.fstat(descriptor)
    mapped = os.stat(path, follow_symlinks=False)
    if (
        not stat.S_ISREG(held.st_mode)
        or held.st_nlink != 1
        or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise RuntimeError
finally:
    os.close(descriptor)
' "$KERNEL_CANDIDATE_ROOT_FD" "$KERNEL_CANDIDATE_ROOT" "$1"
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

cleanup_image_snapshot() {
  [ -n "$IMAGE_SNAPSHOT_DIR" ] || return 0
  case "$IMAGE_SNAPSHOT_DIR" in
    "${repo_dir:-}/build/release/.image-raw-snapshot."*) rm -rf -- "$IMAGE_SNAPSHOT_DIR" ;;
    *) echo "Warning: refusing to remove unexpected raw-image snapshot: $IMAGE_SNAPSHOT_DIR" >&2 ;;
  esac
}

cleanup_output_staging() {
  local current_identity=""

  [ -n "$OUTPUT_STAGING_DIR" ] || return 0
  case "$OUTPUT_STAGING_DIR" in
    "${repo_dir:-}/build/release/."*.staging.*)
      current_identity="$(directory_identity "$OUTPUT_STAGING_DIR" 2>/dev/null || true)"
      if [ -n "$OUTPUT_STAGING_IDENTITY" ] &&
        [ "$current_identity" = "$OUTPUT_STAGING_IDENTITY" ]; then
        rm -rf -- "$OUTPUT_STAGING_DIR"
      elif [ -e "$OUTPUT_STAGING_DIR" ] || [ -L "$OUTPUT_STAGING_DIR" ]; then
        echo "Warning: preserving unexpected image release staging occupant: $OUTPUT_STAGING_DIR" >&2
      fi
      ;;
    *) echo "Warning: refusing to remove unexpected image release staging directory: $OUTPUT_STAGING_DIR" >&2 ;;
  esac
}

directory_identity() {
  local path="$1" identity

  if identity="$(stat -c '%d:%i' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  elif identity="$(stat -f '%d:%i' "$path" 2>/dev/null)"; then
    printf '%s\n' "$identity"
  else
    return 1
  fi
}

directory_tree_identity() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys


root = os.fsencode(sys.argv[1])
root_stat = os.lstat(root)
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise SystemExit("tree identity root is not a real directory")

result = hashlib.sha256()


def frame(tag: bytes, value: bytes) -> None:
    result.update(len(tag).to_bytes(4, "big"))
    result.update(tag)
    result.update(len(value).to_bytes(8, "big"))
    result.update(value)


def stable_fields(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def visit(path: bytes, relative: bytes) -> None:
    before = os.lstat(path)
    mode = before.st_mode
    if stat.S_ISREG(mode):
        kind = b"file"
    elif stat.S_ISDIR(mode):
        kind = b"directory"
    elif stat.S_ISLNK(mode):
        kind = b"symlink"
    else:
        kind = b"special"
    frame(b"path", relative)
    frame(b"kind", kind)
    frame(
        b"metadata",
        (
            f"{before.st_dev}:{before.st_ino}:{before.st_mode}:"
            f"{before.st_nlink}:{before.st_uid}:{before.st_gid}:"
            f"{before.st_size}:{before.st_rdev}"
        ).encode("ascii"),
    )
    if relative:
        frame(
            b"timestamps",
            f"{before.st_mtime_ns}:{before.st_ctime_ns}".encode("ascii"),
        )
    if stat.S_ISREG(mode):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            descriptor_before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(descriptor_before.st_mode)
                or descriptor_before.st_dev != before.st_dev
                or descriptor_before.st_ino != before.st_ino
            ):
                raise RuntimeError("regular file changed before descriptor capture")
            content = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                content.update(chunk)
            descriptor_after = os.fstat(descriptor)
            if stable_fields(descriptor_before) != stable_fields(descriptor_after):
                raise RuntimeError("regular file changed while it was hashed")
            after = os.lstat(path)
            if stable_fields(before) != stable_fields(after):
                raise RuntimeError("regular file path changed while it was hashed")
            frame(b"content", content.digest())
        finally:
            os.close(descriptor)
    elif stat.S_ISDIR(mode):
        names = sorted(os.listdir(path))
        for name in names:
            child_relative = name if not relative else relative + b"/" + name
            visit(os.path.join(path, name), child_relative)
        after = os.lstat(path)
        if stable_fields(before) != stable_fields(after):
            raise RuntimeError("directory changed while it was traversed")
    elif stat.S_ISLNK(mode):
        target = os.readlink(path)
        after = os.lstat(path)
        if stable_fields(before) != stable_fields(after):
            raise RuntimeError("symlink changed while it was read")
        frame(b"target", target)
    else:
        raise RuntimeError("special filesystem nodes are not supported")


visit(root, b"")
print(result.hexdigest())
PY
}

stable_directory_tree_identity() {
  local path="$1" first second

  first="$(directory_tree_identity "$path")" || return 1
  second="$(directory_tree_identity "$path")" || return 1
  [ "$first" = "$second" ] || {
    echo "Directory tree changed between identity passes: $path" >&2
    return 1
  }
  printf '%s\n' "$first"
}

private_container_has_only() {
  python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

container = os.fsencode(sys.argv[1])
expected = os.fsencode(sys.argv[2])
metadata = os.lstat(container)
if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit(1)
if stat.S_IMODE(metadata.st_mode) != 0o700:
    raise SystemExit(1)
if os.listdir(container) != [expected]:
    raise SystemExit(1)
PY
}

private_container_is_empty() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

container = os.fsencode(sys.argv[1])
metadata = os.lstat(container)
if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit(1)
if stat.S_IMODE(metadata.st_mode) != 0o700 or os.listdir(container):
    raise SystemExit(1)
PY
}

remove_exact_empty_private_container() {
  local container="$1" expected_identity="$2"

  [ -n "$container" ] && [ -n "$expected_identity" ] &&
    [ "$(directory_identity "$container" 2>/dev/null || true)" = \
      "$expected_identity" ] &&
    private_container_is_empty "$container" && rmdir "$container"
}

rollback_output_install() {
  local current_identity="" current_tree="" failed_container=""
  local failed_container_identity="" failed_path="" failed_identity=""
  local candidate_exact="false" failed_candidate_placed="false" restore_ok="true"

  [ "$OUTPUT_INSTALL_PENDING" = "true" ] || return 0
  OUTPUT_INSTALL_PENDING="false"

  if [ -e "$FINAL_OUT_DIR" ] || [ -L "$FINAL_OUT_DIR" ]; then
    current_identity="$(directory_identity "$FINAL_OUT_DIR" 2>/dev/null || true)"
    if [ -z "$INSTALLED_OUTPUT_IDENTITY" ] ||
      [ "$current_identity" != "$INSTALLED_OUTPUT_IDENTITY" ]; then
      echo "Warning: preserving unexpected image output occupant during rollback: $FINAL_OUT_DIR" >&2
      restore_ok="false"
    else
      failed_container="$(mktemp -d "$release_root_abs/.${out_leaf}.failed.XXXXXX")"
      chmod 700 "$failed_container"
      failed_container_identity="$(directory_identity "$failed_container")"
      failed_path="$failed_container/candidate"
      if ! mv "$FINAL_OUT_DIR" "$failed_path"; then
        echo "Warning: could not quarantine the failed image candidate: $FINAL_OUT_DIR" >&2
        if remove_exact_empty_private_container \
            "$failed_container" "$failed_container_identity"; then
          failed_container=""
        else
          echo "Warning: preserving changed failed-candidate recovery container: $failed_container" >&2
        fi
        restore_ok="false"
      else
        failed_candidate_placed="true"
        failed_identity="$(directory_identity "$failed_path" 2>/dev/null || true)"
        current_tree="$(stable_directory_tree_identity "$failed_path" 2>/dev/null || true)"
        if [ "$failed_identity" = "$INSTALLED_OUTPUT_IDENTITY" ] &&
          [ -n "$INSTALLED_OUTPUT_TREE" ] && [ "$current_tree" = "$INSTALLED_OUTPUT_TREE" ] &&
          [ "$(directory_identity "$failed_container" 2>/dev/null || true)" = \
            "$failed_container_identity" ] &&
          private_container_has_only "$failed_container" candidate; then
          candidate_exact="true"
        fi
      fi
    fi
  fi

  if [ "$restore_ok" = "true" ] && [ -n "$PREVIOUS_OUTPUT_PATH" ]; then
    current_identity="$(directory_identity "$PREVIOUS_OUTPUT_PATH" 2>/dev/null || true)"
    current_tree="$(stable_directory_tree_identity "$PREVIOUS_OUTPUT_PATH" 2>/dev/null || true)"
    if [ "$(directory_identity "$PREVIOUS_OUTPUT_CONTAINER" 2>/dev/null || true)" != \
        "$PREVIOUS_OUTPUT_CONTAINER_IDENTITY" ] ||
      ! private_container_has_only "$PREVIOUS_OUTPUT_CONTAINER" original ||
      [ "$current_identity" != "$PREVIOUS_OUTPUT_IDENTITY" ] ||
      [ -z "$PREVIOUS_OUTPUT_TREE" ] || [ "$current_tree" != "$PREVIOUS_OUTPUT_TREE" ] ||
      [ -e "$FINAL_OUT_DIR" ] || [ -L "$FINAL_OUT_DIR" ]; then
      echo "Warning: preserving changed previous image output for manual recovery: $PREVIOUS_OUTPUT_CONTAINER" >&2
      restore_ok="false"
    elif ! mv "$PREVIOUS_OUTPUT_PATH" "$FINAL_OUT_DIR"; then
      echo "Warning: could not restore previous image output: $PREVIOUS_OUTPUT_CONTAINER" >&2
      restore_ok="false"
    else
      current_identity="$(directory_identity "$FINAL_OUT_DIR" 2>/dev/null || true)"
      current_tree="$(stable_directory_tree_identity "$FINAL_OUT_DIR" 2>/dev/null || true)"
      if [ "$current_identity" != "$PREVIOUS_OUTPUT_IDENTITY" ] ||
        [ "$current_tree" != "$PREVIOUS_OUTPUT_TREE" ]; then
        echo "Warning: restored image output changed during recovery: $FINAL_OUT_DIR" >&2
        restore_ok="false"
      elif [ "$(directory_identity "$PREVIOUS_OUTPUT_CONTAINER" 2>/dev/null || true)" != \
          "$PREVIOUS_OUTPUT_CONTAINER_IDENTITY" ] ||
        ! private_container_is_empty "$PREVIOUS_OUTPUT_CONTAINER" ||
        ! rmdir "$PREVIOUS_OUTPUT_CONTAINER"; then
        echo "Warning: restored the previous image output but preserved its nonempty recovery container: $PREVIOUS_OUTPUT_CONTAINER" >&2
      else
        PREVIOUS_OUTPUT_CONTAINER=""
      fi
    fi
  elif [ "$restore_ok" = "true" ] &&
    { [ -e "$FINAL_OUT_DIR" ] || [ -L "$FINAL_OUT_DIR" ]; }; then
    echo "Warning: failed image output remains at its final path: $FINAL_OUT_DIR" >&2
    restore_ok="false"
  fi

  if [ -n "$failed_container" ] && [ -e "$failed_container" ]; then
    if [ "$failed_candidate_placed" = "true" ] &&
      [ "$restore_ok" = "true" ] && [ "$candidate_exact" = "true" ] &&
      [ "$(directory_identity "$failed_container" 2>/dev/null || true)" = \
        "$failed_container_identity" ] &&
      private_container_has_only "$failed_container" candidate &&
      [ "$(directory_identity "$failed_path" 2>/dev/null || true)" = \
        "$INSTALLED_OUTPUT_IDENTITY" ] &&
      [ "$(stable_directory_tree_identity "$failed_path" 2>/dev/null || true)" = \
        "$INSTALLED_OUTPUT_TREE" ]; then
      if ! rm -rf -- "$failed_container"; then
        echo "Warning: preserving exact failed image candidate after cleanup failure: $failed_container" >&2
      fi
    elif [ "$failed_candidate_placed" = "true" ]; then
      echo "Preserved failed image candidate for manual recovery: $failed_container" >&2
    else
      echo "Preserved failed-candidate recovery container for manual inspection: $failed_container" >&2
    fi
  fi

  if [ "$restore_ok" = "true" ]; then
    if [ -n "$PREVIOUS_OUTPUT_IDENTITY" ]; then
      echo "Post-install image release verification failed; restored the prior output." >&2
    else
      echo "Post-install image release verification failed; no prior output was replaced." >&2
    fi
  elif [ -n "$PREVIOUS_OUTPUT_CONTAINER" ]; then
    echo "Preserved previous image output recovery data: $PREVIOUS_OUTPUT_CONTAINER" >&2
  fi
}

trap 'rollback_output_install; cleanup_output_staging; cleanup_image_snapshot; cleanup_source_snapshot' EXIT

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
    --apt-provenance)
      require_arg "$1" "${2:-}"
      APT_PROVENANCE="$2"
      shift 2
      ;;
    --build-inputs)
      require_arg "$1" "${2:-}"
      BUILD_INPUTS="$2"
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
require_tool cp
require_tool git
require_tool python3
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
  [ -n "$APT_PROVENANCE" ] || [ -n "$BUILD_INPUTS" ] ||
  [ -n "$TOUCHSCREEN_MODULE_MANIFEST" ] || [ -n "$IMAGE_BUILD_MANIFEST" ]; then
  if [ -z "$KERNEL_BUILD_MANIFEST" ] || [ -z "$KERNEL_RELEASE_MANIFEST" ] ||
    [ -z "$APT_PROVENANCE" ] || [ -z "$BUILD_INPUTS" ] ||
    [ -z "$TOUCHSCREEN_MODULE_MANIFEST" ] || [ -z "$IMAGE_BUILD_MANIFEST" ]; then
    echo "Supply --kernel-build-manifest, --kernel-release-manifest, --apt-provenance, --build-inputs, --touchscreen-module-manifest, and --image-build-manifest together." >&2
    exit 2
  fi
  binding_complete="true"
fi

if [ "$VALIDATE_IMAGE" = "true" ] &&
  { [ "$source_complete" != "true" ] || [ "$binding_complete" != "true" ]; }; then
  echo "Refusing validation-complete live-image assets without bound corresponding source and payload manifests." >&2
  echo "Pass both source archives, $SOURCE_NOTICE_NAME, and all six provenance inputs; or use --skip-validate for a local draft." >&2
  exit 1
fi
if [ "$VALIDATE_IMAGE" = "true" ]; then
  require_tool cmp
  require_tool docker
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
  APT_PROVENANCE="$(canonical_source_file "$APT_PROVENANCE")"
  BUILD_INPUTS="$(canonical_source_file "$BUILD_INPUTS")"
  TOUCHSCREEN_MODULE_MANIFEST="$(canonical_source_file "$TOUCHSCREEN_MODULE_MANIFEST")"
  TOUCHSCREEN_SIGNING_CERTIFICATE="$(
    canonical_source_file \
      "$(dirname "$TOUCHSCREEN_MODULE_MANIFEST")/$TOUCHSCREEN_SIGNING_CERTIFICATE_NAME"
  )"
  KERNEL_SIGNATURE_REPORT="$(
    canonical_source_file \
      "$(dirname "$KERNEL_BUILD_MANIFEST")/$KERNEL_SIGNATURE_REPORT_NAME"
  )"
  IMAGE_BUILD_MANIFEST="$(canonical_source_file "$IMAGE_BUILD_MANIFEST")"
  kernel_build_manifest_base="$(basename "$KERNEL_BUILD_MANIFEST")"
  kernel_release_manifest_base="$(basename "$KERNEL_RELEASE_MANIFEST")"
  apt_provenance_base="$(basename "$APT_PROVENANCE")"
  build_inputs_base="$(basename "$BUILD_INPUTS")"
  touchscreen_module_manifest_base="$(basename "$TOUCHSCREEN_MODULE_MANIFEST")"
  touchscreen_signing_certificate_base="$(basename "$TOUCHSCREEN_SIGNING_CERTIFICATE")"
  kernel_signature_report_base="$(basename "$KERNEL_SIGNATURE_REPORT")"
  image_build_manifest_base="$(basename "$IMAGE_BUILD_MANIFEST")"
  [ "$kernel_build_manifest_base" = "sp11-kernel-build-manifest.txt" ] || {
    echo "Kernel build manifest basename must be sp11-kernel-build-manifest.txt." >&2
    exit 2
  }
  [ "$kernel_release_manifest_base" = "sp11-kernel-release-manifest.txt" ] || {
    echo "Kernel release manifest basename must be sp11-kernel-release-manifest.txt." >&2
    exit 2
  }
  [ "$apt_provenance_base" = "$APT_PROVENANCE_NAME" ] || {
    echo "APT provenance basename must be $APT_PROVENANCE_NAME." >&2
    exit 2
  }
  [ "$build_inputs_base" = "$BUILD_INPUTS_NAME" ] || {
    echo "Build-inputs basename must be $BUILD_INPUTS_NAME." >&2
    exit 2
  }
  [ "$touchscreen_module_manifest_base" = "sp11-touchscreen-modules-manifest.txt" ] || {
    echo "Touchscreen module manifest basename must be sp11-touchscreen-modules-manifest.txt." >&2
    exit 2
  }
  [ "$touchscreen_signing_certificate_base" = "$TOUCHSCREEN_SIGNING_CERTIFICATE_NAME" ] || {
    echo "Touchscreen signing certificate basename must be $TOUCHSCREEN_SIGNING_CERTIFICATE_NAME." >&2
    exit 2
  }
  [ "$kernel_signature_report_base" = "$KERNEL_SIGNATURE_REPORT_NAME" ] || {
    echo "Kernel signature-report basename must be $KERNEL_SIGNATURE_REPORT_NAME." >&2
    exit 2
  }
  [ "$image_build_manifest_base" = "$IMAGE_BUILD_MANIFEST_NAME" ] || {
    echo "Image build manifest basename must be $IMAGE_BUILD_MANIFEST_NAME." >&2
    exit 2
  }
  binding_paths=(
    "$KERNEL_BUILD_MANIFEST"
    "$KERNEL_RELEASE_MANIFEST"
    "$APT_PROVENANCE"
    "$BUILD_INPUTS"
    "$TOUCHSCREEN_MODULE_MANIFEST"
    "$TOUCHSCREEN_SIGNING_CERTIFICATE"
    "$KERNEL_SIGNATURE_REPORT"
    "$IMAGE_BUILD_MANIFEST"
  )
  for binding_path_index in "${!binding_paths[@]}"; do
    comparison_index=$((binding_path_index + 1))
    while [ "$comparison_index" -lt "${#binding_paths[@]}" ]; do
      if [ "${binding_paths[$binding_path_index]}" = "${binding_paths[$comparison_index]}" ]; then
        echo "Image release provenance inputs must be distinct files." >&2
        exit 2
      fi
      comparison_index=$((comparison_index + 1))
    done
  done
fi

if [ "$source_complete" = "true" ] && [ "$binding_complete" = "true" ]; then
  touchscreen_candidate_dir="$(dirname "$TOUCHSCREEN_MODULE_MANIFEST")"
  kernel_candidate_inputs=(
    "$KERNEL_SOURCE_ASSET"
    "$TOUCHSCREEN_SOURCE_ASSET"
    "$KERNEL_BUILD_MANIFEST"
    "$KERNEL_RELEASE_MANIFEST"
    "$APT_PROVENANCE"
    "$BUILD_INPUTS"
    "$TOUCHSCREEN_MODULE_MANIFEST"
    "$TOUCHSCREEN_SIGNING_CERTIFICATE"
    "$KERNEL_SIGNATURE_REPORT"
    "$touchscreen_candidate_dir/gpi.ko"
    "$touchscreen_candidate_dir/spi-geni-qcom.ko"
    "$touchscreen_candidate_dir/mshw0485_touch.ko"
  )
  KERNEL_CANDIDATE_ROOT="$(dirname "${kernel_candidate_inputs[0]}")"
  for kernel_candidate_input in "${kernel_candidate_inputs[@]}"; do
    if [ "$(dirname "$kernel_candidate_input")" != "$KERNEL_CANDIDATE_ROOT" ]; then
      echo "Kernel candidate inputs must share one committed release root." >&2
      exit 1
    fi
  done
  KERNEL_CANDIDATE_ROOT_STATE="$(
    kernel_candidate_root_state "$KERNEL_CANDIDATE_ROOT"
  )" || {
    echo "Kernel candidate root must be an exact host-owned mode-0500 directory." >&2
    exit 1
  }
  kernel_candidate_previous_directory="$(pwd -P)"
  cd "$KERNEL_CANDIDATE_ROOT" || {
    echo "Could not enter the committed kernel candidate root." >&2
    exit 1
  }
  exec 55< .
  cd "$kernel_candidate_previous_directory" || {
    echo "Could not restore the image-release preparer directory." >&2
    exit 1
  }
  verify_kernel_candidate_root || {
    echo "Committed kernel candidate root mapping changed during acquisition." >&2
    exit 1
  }
  for kernel_candidate_input in "${kernel_candidate_inputs[@]}"; do
    verify_kernel_candidate_member "$kernel_candidate_input" || {
      echo "Kernel candidate input is not bound to its committed release root." >&2
      exit 1
    }
  done
  kernel_release_validator="$repo_dir/scripts/validate-sp11-touchscreen-release.sh"
  if [ ! -f "$kernel_release_validator" ] || [ -L "$kernel_release_validator" ] ||
     ! "$kernel_release_validator" --local-prepared-candidate \
       --dir "$KERNEL_CANDIDATE_ROOT" >/dev/null; then
    echo "Committed local kernel candidate failed full release validation." >&2
    exit 1
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
      echo "Refusing a validation-complete image because remote tag $RELEASE_NAME could not be checked on origin." >&2
      echo "Restore remote access and rerun so an existing tag cannot be reused accidentally." >&2
      exit 1
    fi
  else
    echo "Refusing a validation-complete image because the support repository has no origin remote." >&2
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

IMAGE_SNAPSHOT_DIR="$(mktemp -d "$release_root_abs/.image-raw-snapshot.XXXXXX")"
chmod 700 "$IMAGE_SNAPSHOT_DIR"
IMAGE_SNAPSHOT="$IMAGE_SNAPSHOT_DIR/$image_base"
image_source_before_size="$(file_size "$image_abs")"
image_source_before_sha="$(shasum -a 256 "$image_abs" | awk '{print $1}')"

snapshot_created="false"
if cp -c -- "$image_abs" "$IMAGE_SNAPSHOT" 2>/dev/null; then
  snapshot_created="true"
else
  rm -f -- "$IMAGE_SNAPSHOT"
fi
if [ "$snapshot_created" != "true" ]; then
  if cp --reflink=always --sparse=always -- "$image_abs" "$IMAGE_SNAPSHOT" 2>/dev/null; then
    snapshot_created="true"
  else
    rm -f -- "$IMAGE_SNAPSHOT"
  fi
fi
if [ "$snapshot_created" != "true" ]; then
  if cp --sparse=always -- "$image_abs" "$IMAGE_SNAPSHOT" 2>/dev/null; then
    snapshot_created="true"
  else
    rm -f -- "$IMAGE_SNAPSHOT"
  fi
fi
if [ "$snapshot_created" != "true" ]; then
  if cp -- "$image_abs" "$IMAGE_SNAPSHOT"; then
    snapshot_created="true"
  else
    rm -f -- "$IMAGE_SNAPSHOT"
  fi
fi
[ "$snapshot_created" = "true" ] && [ -s "$IMAGE_SNAPSHOT" ] &&
  [ -f "$IMAGE_SNAPSHOT" ] && [ ! -L "$IMAGE_SNAPSHOT" ] || {
  echo "Could not create a private regular snapshot of the raw image." >&2
  exit 1
}
chmod 0400 "$IMAGE_SNAPSHOT"
image_source_after_size="$(file_size "$image_abs")"
image_source_after_sha="$(shasum -a 256 "$image_abs" | awk '{print $1}')"
image_size="$(file_size "$IMAGE_SNAPSHOT")"
image_sha="$(shasum -a 256 "$IMAGE_SNAPSHOT" | awk '{print $1}')"
if [ "$image_source_before_size" != "$image_source_after_size" ] ||
  [ "$image_source_before_sha" != "$image_source_after_sha" ] ||
  [ "$image_source_before_size" != "$image_size" ] ||
  [ "$image_source_before_sha" != "$image_sha" ]; then
  echo "Raw image changed while its private validation snapshot was created." >&2
  exit 1
fi

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
      "$APT_PROVENANCE"
      "$BUILD_INPUTS"
      "$TOUCHSCREEN_MODULE_MANIFEST"
      "$TOUCHSCREEN_SIGNING_CERTIFICATE"
      "$KERNEL_SIGNATURE_REPORT"
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
    APT_PROVENANCE="$SOURCE_SNAPSHOT_DIR/$apt_provenance_base"
    BUILD_INPUTS="$SOURCE_SNAPSHOT_DIR/$build_inputs_base"
    TOUCHSCREEN_MODULE_MANIFEST="$SOURCE_SNAPSHOT_DIR/$touchscreen_module_manifest_base"
    TOUCHSCREEN_SIGNING_CERTIFICATE="$SOURCE_SNAPSHOT_DIR/$touchscreen_signing_certificate_base"
    KERNEL_SIGNATURE_REPORT="$SOURCE_SNAPSHOT_DIR/$kernel_signature_report_base"
    IMAGE_BUILD_MANIFEST="$SOURCE_SNAPSHOT_DIR/$image_build_manifest_base"
  fi
fi

if [ "$source_complete" = "true" ] && [ "$binding_complete" = "true" ]; then
  verify_kernel_candidate_root || {
    echo "Committed kernel candidate root changed during snapshot acquisition." >&2
    exit 1
  }
  for kernel_candidate_input in "${kernel_candidate_inputs[@]}"; do
    verify_kernel_candidate_member "$kernel_candidate_input" || {
      echo "Committed kernel candidate input changed during snapshot acquisition." >&2
      exit 1
    }
  done
fi

if [ "$source_complete" = "true" ]; then
  kernel_source_snapshot_sha="$(shasum -a 256 "$KERNEL_SOURCE_ASSET" | awk '{print $1}')"
  touchscreen_source_snapshot_sha="$(shasum -a 256 "$TOUCHSCREEN_SOURCE_ASSET" | awk '{print $1}')"
  source_notice_snapshot_sha="$(shasum -a 256 "$SOURCE_NOTICE" | awk '{print $1}')"
fi
if [ "$binding_complete" = "true" ]; then
  kernel_build_manifest_size="$(file_size "$KERNEL_BUILD_MANIFEST")"
  kernel_release_manifest_size="$(file_size "$KERNEL_RELEASE_MANIFEST")"
  apt_provenance_size="$(file_size "$APT_PROVENANCE")"
  build_inputs_size="$(file_size "$BUILD_INPUTS")"
  touchscreen_module_manifest_size="$(file_size "$TOUCHSCREEN_MODULE_MANIFEST")"
  touchscreen_signing_certificate_size="$(file_size "$TOUCHSCREEN_SIGNING_CERTIFICATE")"
  kernel_signature_report_size="$(file_size "$KERNEL_SIGNATURE_REPORT")"
  image_build_manifest_size="$(file_size "$IMAGE_BUILD_MANIFEST")"
  kernel_build_manifest_snapshot_sha="$(shasum -a 256 "$KERNEL_BUILD_MANIFEST" | awk '{print $1}')"
  kernel_release_manifest_snapshot_sha="$(shasum -a 256 "$KERNEL_RELEASE_MANIFEST" | awk '{print $1}')"
  apt_provenance_snapshot_sha="$(shasum -a 256 "$APT_PROVENANCE" | awk '{print $1}')"
  build_inputs_snapshot_sha="$(shasum -a 256 "$BUILD_INPUTS" | awk '{print $1}')"
  touchscreen_module_manifest_snapshot_sha="$(shasum -a 256 "$TOUCHSCREEN_MODULE_MANIFEST" | awk '{print $1}')"
  touchscreen_signing_certificate_snapshot_sha="$(shasum -a 256 "$TOUCHSCREEN_SIGNING_CERTIFICATE" | awk '{print $1}')"
  kernel_signature_report_snapshot_sha="$(shasum -a 256 "$KERNEL_SIGNATURE_REPORT" | awk '{print $1}')"
  image_build_manifest_snapshot_sha="$(shasum -a 256 "$IMAGE_BUILD_MANIFEST" | awk '{print $1}')"
fi

[ -x "$public_content_validator" ] && [ ! -L "$public_content_validator" ] || {
  echo "Missing executable public-content validator." >&2
  exit 1
}
if [ "$VALIDATE_IMAGE" = "true" ]; then
  "$public_content_validator" \
    --file "$SOURCE_NOTICE" \
    --file "$KERNEL_BUILD_MANIFEST" \
    --file "$KERNEL_RELEASE_MANIFEST" \
    --file "$APT_PROVENANCE" \
    --file "$BUILD_INPUTS" \
    --file "$TOUCHSCREEN_MODULE_MANIFEST" \
    --file "$KERNEL_SIGNATURE_REPORT" \
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
  if ! python3 -I "$release_manifest_validator" \
      --require-current-head \
      --repo-dir "$repo_dir" \
      --support-commit "$repo_commit" \
      --release-name "$RELEASE_NAME" \
      --kernel-build-manifest "$KERNEL_BUILD_MANIFEST" \
      --kernel-release-manifest "$KERNEL_RELEASE_MANIFEST" \
      --apt-provenance "$APT_PROVENANCE" \
      --build-inputs "$BUILD_INPUTS" \
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
  build_module_signing_policy="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Module signing policy")"
  build_module_signing_private_material_retained="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Module signing private material retained")"
  build_signing_certificate_sha="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Signing certificate SHA256")"
  build_signing_certificate_fingerprint="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Signing certificate fingerprint")"
  build_signing_certificate_serial="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Signing certificate serial")"
  build_kernel_signature_report_asset="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module signature report asset")"
  build_kernel_signature_report_size="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module signature report size")"
  build_kernel_signature_report_sha="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module signature report SHA256")"
  build_kernel_signature_report_schema="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module signature report schema")"
  build_kernel_module_total_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module total count")"
  build_kernel_module_verified_signed_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module verified signed count")"
  build_kernel_module_policy_allowed_unsigned_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module policy-allowed unsigned count")"
  build_kernel_module_unsigned_path_inventory_sha="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Kernel module unsigned-path inventory SHA256")"
  build_output_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Output count")"
  build_deb_count="$(required_manifest_value "$KERNEL_BUILD_MANIFEST" "Deb count")"
  if [ "$build_schema" != "sp11-kernel-build-v2" ] || [ "$build_release" != "true" ] ||
    [ "$build_completed" != "true" ] || [ "$build_support_start" != "$build_support_end" ] ||
    ! [[ "$build_support_start" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$build_source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    ! [[ "$build_patched_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
    [ "$build_module_signing_policy" != "$MODULE_SIGNING_POLICY" ] ||
    [ "$build_module_signing_private_material_retained" != "false" ] ||
    ! [[ "$build_signing_certificate_sha" =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ "$build_signing_certificate_fingerprint" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] ||
    ! [[ "$build_signing_certificate_serial" =~ ^[0-9A-F]+$ ]] ||
    [ "$build_kernel_signature_report_asset" != "$KERNEL_SIGNATURE_REPORT_NAME" ] ||
    [ "$build_kernel_signature_report_size" != "$kernel_signature_report_size" ] ||
    [ "$build_kernel_signature_report_sha" != "$kernel_signature_report_snapshot_sha" ] ||
    [ "$build_kernel_signature_report_schema" != "sp11-kernel-module-signature-verification-v1" ] ||
    ! [[ "$build_kernel_module_total_count" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$build_kernel_module_verified_signed_count" =~ ^(0|[1-9][0-9]*)$ ]] ||
    ! [[ "$build_kernel_module_policy_allowed_unsigned_count" =~ ^(0|[1-9][0-9]*)$ ]] ||
    ! [[ "$build_kernel_module_unsigned_path_inventory_sha" =~ ^[0-9a-f]{64}$ ]] ||
    [ "$build_kernel_module_total_count" -ne $((
      10#$build_kernel_module_verified_signed_count +
        10#$build_kernel_module_policy_allowed_unsigned_count
    )) ] ||
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
  build_signing_certificate_output_sha=""
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
    elif [ "$build_output_role" = "module-signing-certificate" ]; then
      [ -z "$build_signing_certificate_output_sha" ] || {
        echo "Kernel build manifest contains duplicate module-signing-certificate outputs." >&2
        exit 1
      }
      build_signing_certificate_output_sha="$build_output_sha"
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
  [ "$build_signing_certificate_output_sha" = "$build_signing_certificate_sha" ] || {
    echo "Kernel build manifest signing certificate output and metadata disagree." >&2
    exit 1
  }
  if ! python3 "$image_build_manifest_validator" \
      --manifest "$IMAGE_BUILD_MANIFEST" \
      --image "$IMAGE_SNAPSHOT" \
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

  release_outer_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel release schema")"
  release_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build provenance schema")"
  bound_kernel_release_name="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Release")"
  release_build="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Release build")"
  release_completed="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build completed")"
  release_support="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Support repo commit")"
  release_source_head="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Source HEAD")"
  release_patched_tree="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Patched tree ID")"
  release_module_signing_policy="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Module signing policy")"
  release_module_signing_private_material_retained="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Module signing private material retained")"
  release_signing_certificate_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Signing certificate SHA256")"
  release_signing_certificate_fingerprint="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Signing certificate fingerprint")"
  release_signing_certificate_serial="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Signing certificate serial")"
  release_kernel_signature_report_asset="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module signature report asset")"
  release_kernel_signature_report_size="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module signature report size")"
  release_kernel_signature_report_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module signature report SHA256")"
  release_kernel_signature_report_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module signature report schema")"
  release_kernel_module_total_count="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module total count")"
  release_kernel_module_verified_signed_count="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module verified signed count")"
  release_kernel_module_policy_allowed_unsigned_count="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module policy-allowed unsigned count")"
  release_kernel_module_unsigned_path_inventory_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel module unsigned-path inventory SHA256")"
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
  release_build_manifest_asset="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel build manifest asset")"
  release_build_manifest_size="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel build manifest size")"
  release_build_manifest_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel build manifest SHA256")"
  release_apt_asset="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT provenance asset")"
  release_apt_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT provenance schema")"
  release_apt_size="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT provenance size")"
  release_apt_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT provenance SHA256")"
  release_apt_snapshot_id="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT snapshot ID")"
  release_apt_snapshot_uri="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "APT snapshot URI")"
  release_inputs_asset="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build inputs asset")"
  release_inputs_schema="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build inputs schema")"
  release_inputs_size="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build inputs size")"
  release_inputs_sha="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build inputs SHA256")"
  release_creation_propagation="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Build envelope creation propagation")"
  release_kernel_propagation="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Kernel release propagation")"
  release_oci_image="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "OCI index image")"
  release_oci_digest="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "OCI index digest")"
  release_oci_platform="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "OCI platform")"
  release_oci_platform_manifest="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "OCI platform manifest")"
  release_publication_state="$(required_manifest_value "$KERNEL_RELEASE_MANIFEST" "Publication state")"

  apt_schema="$(required_manifest_value "$APT_PROVENANCE" "APT provenance schema")"
  apt_snapshot_id="$(required_manifest_value "$APT_PROVENANCE" "Snapshot ID")"
  apt_snapshot_uri="$(required_manifest_value "$APT_PROVENANCE" "Snapshot URI")"
  apt_completed="$(required_manifest_value "$APT_PROVENANCE" "APT provenance complete")"
  inputs_schema="$(required_manifest_value "$BUILD_INPUTS" "Build inputs schema")"
  inputs_support="$(required_manifest_value "$BUILD_INPUTS" "Support HEAD")"
  inputs_oci_image="$(required_manifest_value "$BUILD_INPUTS" "OCI index image")"
  inputs_oci_digest="$(required_manifest_value "$BUILD_INPUTS" "OCI index digest")"
  inputs_oci_platform="$(required_manifest_value "$BUILD_INPUTS" "OCI platform")"
  inputs_oci_platform_manifest="$(required_manifest_value "$BUILD_INPUTS" "OCI platform manifest")"
  inputs_creation_propagation="$(required_manifest_value "$BUILD_INPUTS" "Publication schema propagation")"
  inputs_completed="$(required_manifest_value "$BUILD_INPUTS" "Build inputs complete")"
  inputs_build_role="$(required_manifest_value "$BUILD_INPUTS" "Input 4 role")"
  inputs_build_path="$(required_manifest_value "$BUILD_INPUTS" "Input 4 path")"
  inputs_build_size="$(required_manifest_value "$BUILD_INPUTS" "Input 4 size")"
  inputs_build_sha="$(required_manifest_value "$BUILD_INPUTS" "Input 4 SHA256")"
  inputs_apt_role="$(required_manifest_value "$BUILD_INPUTS" "Input 5 role")"
  inputs_apt_path="$(required_manifest_value "$BUILD_INPUTS" "Input 5 path")"
  inputs_apt_size="$(required_manifest_value "$BUILD_INPUTS" "Input 5 size")"
  inputs_apt_sha="$(required_manifest_value "$BUILD_INPUTS" "Input 5 SHA256")"
  image_build_schema="$(required_manifest_value "$IMAGE_BUILD_MANIFEST" "Schema")"

  if [ "$release_outer_schema" != "sp11-kernel-release-v1" ] ||
    [ "$release_schema" != "$build_schema" ] || [ "$release_build" != "true" ] ||
    [ "$release_completed" != "true" ] || [ "$release_support" != "$build_support_start" ] ||
    [ "$release_source_head" != "$build_source_head" ] ||
    [ "$release_patched_tree" != "$build_patched_tree" ] ||
    [ "$release_module_signing_policy" != "$build_module_signing_policy" ] ||
    [ "$release_module_signing_private_material_retained" != "$build_module_signing_private_material_retained" ] ||
    [ "$release_signing_certificate_sha" != "$build_signing_certificate_sha" ] ||
    [ "$release_signing_certificate_fingerprint" != "$build_signing_certificate_fingerprint" ] ||
    [ "$release_signing_certificate_serial" != "$build_signing_certificate_serial" ] ||
    [ "$release_kernel_signature_report_asset" != "$build_kernel_signature_report_asset" ] ||
    [ "$release_kernel_signature_report_size" != "$build_kernel_signature_report_size" ] ||
    [ "$release_kernel_signature_report_sha" != "$build_kernel_signature_report_sha" ] ||
    [ "$release_kernel_signature_report_schema" != "$build_kernel_signature_report_schema" ] ||
    [ "$release_kernel_module_total_count" != "$build_kernel_module_total_count" ] ||
    [ "$release_kernel_module_verified_signed_count" != "$build_kernel_module_verified_signed_count" ] ||
    [ "$release_kernel_module_policy_allowed_unsigned_count" != "$build_kernel_module_policy_allowed_unsigned_count" ] ||
    [ "$release_kernel_module_unsigned_path_inventory_sha" != "$build_kernel_module_unsigned_path_inventory_sha" ] ||
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
  if [ "$apt_schema" != "sp11-kernel-apt-provenance-v1" ] ||
    [ "$apt_completed" != "true" ] ||
    [ "$inputs_schema" != "sp11-kernel-build-inputs-v1" ] ||
    [ "$inputs_support" != "$repo_commit" ] || [ "$inputs_completed" != "true" ] ||
    [ "$inputs_creation_propagation" != "incomplete" ] ||
    [ "$inputs_build_role" != "kernel-build-manifest-v2" ] ||
    [ "$inputs_build_path" != "artifacts/$kernel_build_manifest_base" ] ||
    [ "$inputs_build_size" != "$kernel_build_manifest_size" ] ||
    [ "$inputs_build_sha" != "$kernel_build_manifest_snapshot_sha" ] ||
    [ "$inputs_apt_role" != "apt-provenance-v1" ] ||
    [ "$inputs_apt_path" != "artifacts/$apt_provenance_base" ] ||
    [ "$inputs_apt_size" != "$apt_provenance_size" ] ||
    [ "$inputs_apt_sha" != "$apt_provenance_snapshot_sha" ] ||
    [ "$image_build_schema" != "sp11-live-image-build-v1" ]; then
    echo "Immutable APT sidecar and build-inputs envelope are not exact or cross-bound." >&2
    exit 1
  fi
  if [ "$release_build_manifest_asset" != "$kernel_build_manifest_base" ] ||
    [ "$release_build_manifest_size" != "$kernel_build_manifest_size" ] ||
    [ "$release_build_manifest_sha" != "$kernel_build_manifest_snapshot_sha" ] ||
    [ "$release_apt_asset" != "$apt_provenance_base" ] ||
    [ "$release_apt_schema" != "$apt_schema" ] ||
    [ "$release_apt_size" != "$apt_provenance_size" ] ||
    [ "$release_apt_sha" != "$apt_provenance_snapshot_sha" ] ||
    [ "$release_apt_snapshot_id" != "$apt_snapshot_id" ] ||
    [ "$release_apt_snapshot_uri" != "$apt_snapshot_uri" ] ||
    [ "$release_inputs_asset" != "$build_inputs_base" ] ||
    [ "$release_inputs_schema" != "$inputs_schema" ] ||
    [ "$release_inputs_size" != "$build_inputs_size" ] ||
    [ "$release_inputs_sha" != "$build_inputs_snapshot_sha" ] ||
    [ "$release_creation_propagation" != "$inputs_creation_propagation" ] ||
    [ "$release_kernel_propagation" != "complete" ] ||
    [ "$release_oci_image" != "$inputs_oci_image" ] ||
    [ "$release_oci_digest" != "$inputs_oci_digest" ] ||
    [ "$release_oci_platform" != "$inputs_oci_platform" ] ||
    [ "$release_oci_platform_manifest" != "$inputs_oci_platform_manifest" ] ||
    [ "$release_publication_state" != "blocked" ]; then
    echo "Kernel release manifest does not complete the exact immutable-input propagation contract." >&2
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
  module_signing_policy="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing policy")"
  module_signing_private_material_retained="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing private material retained")"
  module_signing_hash_algorithm="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing hash algorithm")"
  module_signing_certificate_asset="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing certificate asset")"
  module_signing_certificate_sha="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing certificate SHA256")"
  module_signing_certificate_fingerprint="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing certificate fingerprint")"
  module_signing_certificate_serial="$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module signing certificate serial")"
  module_names=(gpi.ko spi-geni-qcom.ko mshw0485_touch.ko)
  module_sizes=()
  module_shas=()
  module_payload_sizes=()
  module_payload_shas=()
  module_signature_sizes=()
  module_signature_shas=()
  for module_name in "${module_names[@]}"; do
    module_sizes+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name size")")
    module_shas+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name SHA256")")
    module_payload_sizes+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name payload size")")
    module_payload_shas+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name payload SHA256")")
    module_signature_sizes+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name signature size")")
    module_signature_shas+=("$(required_manifest_value "$TOUCHSCREEN_MODULE_MANIFEST" "Module $module_name signature SHA256")")
  done
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
    [ "$module_kernel_headers_mode" != "$release_touch_headers_mode" ] ||
    [ "$module_signing_policy" != "$build_module_signing_policy" ] ||
    [ "$module_signing_private_material_retained" != "$build_module_signing_private_material_retained" ] ||
    [ "$module_signing_hash_algorithm" != "sha512" ] ||
    [ "$module_signing_certificate_asset" != "$TOUCHSCREEN_SIGNING_CERTIFICATE_NAME" ] ||
    [ "$module_signing_certificate_sha" != "$build_signing_certificate_sha" ] ||
    [ "$module_signing_certificate_fingerprint" != "$build_signing_certificate_fingerprint" ] ||
    [ "$module_signing_certificate_serial" != "$build_signing_certificate_serial" ] ||
    [ "$touchscreen_signing_certificate_snapshot_sha" != "$module_signing_certificate_sha" ]; then
    echo "Touchscreen module manifest does not match the kernel/source identity contract." >&2
    exit 1
  fi

  expected_signed_module_report="$(
    {
      echo "Module signing policy: $module_signing_policy"
      echo "Module signing private material retained: $module_signing_private_material_retained"
      echo "Module signing hash algorithm: $module_signing_hash_algorithm"
      echo "Module signing certificate asset: $module_signing_certificate_asset"
      echo "Module signing certificate SHA256: $module_signing_certificate_sha"
      echo "Module signing certificate fingerprint: $module_signing_certificate_fingerprint"
      echo "Module signing certificate serial: $module_signing_certificate_serial"
      echo "Windows SE init default: disabled"
      module_index=0
      while [ "$module_index" -lt "${#module_names[@]}" ]; do
        module_name="${module_names[$module_index]}"
        echo "Module $module_name size: ${module_sizes[$module_index]}"
        echo "Module $module_name SHA256: ${module_shas[$module_index]}"
        echo "Module $module_name payload size: ${module_payload_sizes[$module_index]}"
        echo "Module $module_name payload SHA256: ${module_payload_shas[$module_index]}"
        echo "Module $module_name signature size: ${module_signature_sizes[$module_index]}"
        echo "Module $module_name signature SHA256: ${module_signature_shas[$module_index]}"
        module_index=$((module_index + 1))
      done
    }
  )"
  signed_module_validator="$repo_dir/scripts/validate-sp11-signed-modules.py"
  [ -x "$signed_module_validator" ] && [ ! -L "$signed_module_validator" ] || {
    echo "Committed controlled signed-module validator is unavailable." >&2
    exit 1
  }
  if ! signed_module_report="$(
    /usr/bin/python3 -I "$signed_module_validator" \
      --certificate "$touchscreen_candidate_dir/$TOUCHSCREEN_SIGNING_CERTIFICATE_NAME" \
      --module "$touchscreen_candidate_dir/gpi.ko" \
      --module "$touchscreen_candidate_dir/spi-geni-qcom.ko" \
      --module "$touchscreen_candidate_dir/mshw0485_touch.ko"
  )" || [ "$signed_module_report" != "$expected_signed_module_report" ]; then
    echo "Touchscreen release manifest or bundle failed cryptographic signature validation." >&2
    exit 1
  fi

  if ! python3 -I "$source_archive_validator" kernel \
      --archive "$KERNEL_SOURCE_ASSET" --expected-tree "$build_patched_tree"; then
    echo "Kernel source archive failed exact-tree validation." >&2
    exit 1
  fi
  if ! python3 -I "$source_archive_validator" touchscreen \
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
    "$touchscreen_signing_certificate_snapshot_sha" \
    "$touchscreen_signing_certificate_base" >> "$shell_expected_payload"
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
  bound_image_sha="$image_sha"
  image_binding_extractor="$repo_dir/scripts/extract-sp11-image-bindings.sh"
  [ -f "$image_binding_extractor" ] && [ ! -L "$image_binding_extractor" ] || {
    echo "Missing regular raw-image binding extractor." >&2
    exit 1
  }
  if ! docker run --rm -i --platform linux/arm64/v8 \
      -v "$IMAGE_SNAPSHOT:/image/source.img:ro" \
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
      --image "$IMAGE_SNAPSHOT" \
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
  if [ "$(shasum -a 256 "$IMAGE_SNAPSHOT" | awk '{print $1}')" != "$bound_image_sha" ]; then
    echo "Private image snapshot changed while its embedded payload identities were validated." >&2
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
chmod 700 "$OUTPUT_STAGING_DIR"
OUTPUT_STAGING_IDENTITY="$(directory_identity "$OUTPUT_STAGING_DIR")"
OUT_DIR="$OUTPUT_STAGING_DIR"

outline="$OUT_DIR/$OUTLINE_NAME"
if [ "$VALIDATE_IMAGE" = "true" ]; then
  outline_raw="$OUT_DIR/$OUTLINE_NAME.raw"
  if ! ./scripts/build-sp11-live-usb-image.sh \
    --validate-image "$IMAGE_SNAPSHOT" >"$outline_raw" 2>&1; then
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
if [ "$(file_size "$IMAGE_SNAPSHOT")" != "$image_size" ] ||
  [ "$(shasum -a 256 "$IMAGE_SNAPSHOT" | awk '{print $1}')" != "$image_sha" ]; then
  echo "Private image snapshot changed after embedded payload validation." >&2
  exit 1
fi
outline_sha="$(shasum -a 256 "$outline" | awk '{print $1}')"
compressed_tmp="$OUT_DIR/$compressed_base"

zstd -T0 -6 --force -o "$compressed_tmp" "$IMAGE_SNAPSHOT"
if [ "$(shasum -a 256 "$IMAGE_SNAPSHOT" | awk '{print $1}')" != "$image_sha" ]; then
  echo "Private image snapshot changed while the release archive was compressed." >&2
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
    mv "$APT_PROVENANCE" "$OUT_DIR/$apt_provenance_base"
    mv "$BUILD_INPUTS" "$OUT_DIR/$build_inputs_base"
    mv "$TOUCHSCREEN_MODULE_MANIFEST" "$OUT_DIR/$touchscreen_module_manifest_base"
    mv "$TOUCHSCREEN_SIGNING_CERTIFICATE" "$OUT_DIR/$touchscreen_signing_certificate_base"
    mv "$KERNEL_SIGNATURE_REPORT" "$OUT_DIR/$kernel_signature_report_base"
    mv "$IMAGE_BUILD_MANIFEST" "$OUT_DIR/$image_build_manifest_base"
    KERNEL_BUILD_MANIFEST="$OUT_DIR/$kernel_build_manifest_base"
    KERNEL_RELEASE_MANIFEST="$OUT_DIR/$kernel_release_manifest_base"
    APT_PROVENANCE="$OUT_DIR/$apt_provenance_base"
    BUILD_INPUTS="$OUT_DIR/$build_inputs_base"
    TOUCHSCREEN_MODULE_MANIFEST="$OUT_DIR/$touchscreen_module_manifest_base"
    TOUCHSCREEN_SIGNING_CERTIFICATE="$OUT_DIR/$touchscreen_signing_certificate_base"
    KERNEL_SIGNATURE_REPORT="$OUT_DIR/$kernel_signature_report_base"
    IMAGE_BUILD_MANIFEST="$OUT_DIR/$image_build_manifest_base"
    if [ "$(shasum -a 256 "$KERNEL_BUILD_MANIFEST" | awk '{print $1}')" != "$kernel_build_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$KERNEL_RELEASE_MANIFEST" | awk '{print $1}')" != "$kernel_release_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$APT_PROVENANCE" | awk '{print $1}')" != "$apt_provenance_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$BUILD_INPUTS" | awk '{print $1}')" != "$build_inputs_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$TOUCHSCREEN_MODULE_MANIFEST" | awk '{print $1}')" != "$touchscreen_module_manifest_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$TOUCHSCREEN_SIGNING_CERTIFICATE" | awk '{print $1}')" != "$touchscreen_signing_certificate_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$KERNEL_SIGNATURE_REPORT" | awk '{print $1}')" != "$kernel_signature_report_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$IMAGE_BUILD_MANIFEST" | awk '{print $1}')" != "$image_build_manifest_snapshot_sha" ]; then
      echo "Staged source-binding manifests changed after validation." >&2
      exit 1
    fi
    source_checksum_inputs+=(
      "$kernel_build_manifest_base"
      "$kernel_release_manifest_base"
      "$apt_provenance_base"
      "$build_inputs_base"
      "$touchscreen_module_manifest_base"
      "$touchscreen_signing_certificate_base"
      "$kernel_signature_report_base"
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
  if [ "$VALIDATE_IMAGE" = "true" ]; then
    echo "Release manifest schema: sp11-live-image-release-v1"
    echo "Kernel build schema: $build_schema"
    echo "Kernel release schema: $release_outer_schema"
    echo "Touchscreen module contract: $module_contract"
    echo "Image build schema: $image_build_schema"
    echo "Kernel build manifest asset: $kernel_build_manifest_base"
    echo "Kernel build manifest size: $kernel_build_manifest_size"
    echo "Kernel build manifest SHA256: $kernel_build_manifest_snapshot_sha"
    echo "Kernel release manifest asset: $kernel_release_manifest_base"
    echo "Kernel release manifest size: $kernel_release_manifest_size"
    echo "Kernel release manifest SHA256: $kernel_release_manifest_snapshot_sha"
    echo "APT provenance asset: $apt_provenance_base"
    echo "APT provenance schema: $apt_schema"
    echo "APT provenance size: $apt_provenance_size"
    echo "APT provenance SHA256: $apt_provenance_snapshot_sha"
    echo "Build inputs asset: $build_inputs_base"
    echo "Build inputs schema: $inputs_schema"
    echo "Build inputs size: $build_inputs_size"
    echo "Build inputs SHA256: $build_inputs_snapshot_sha"
    echo "Touchscreen module manifest asset: $touchscreen_module_manifest_base"
    echo "Touchscreen module manifest size: $touchscreen_module_manifest_size"
    echo "Touchscreen module manifest SHA256: $touchscreen_module_manifest_snapshot_sha"
    echo "Module signing policy: $module_signing_policy"
    echo "Module signing private material retained: $module_signing_private_material_retained"
    echo "Module signing hash algorithm: $module_signing_hash_algorithm"
    echo "Module signing certificate asset: $touchscreen_signing_certificate_base"
    echo "Module signing certificate size: $touchscreen_signing_certificate_size"
    echo "Module signing certificate SHA256: $touchscreen_signing_certificate_snapshot_sha"
    echo "Module signing certificate fingerprint: $module_signing_certificate_fingerprint"
    echo "Module signing certificate serial: $module_signing_certificate_serial"
    echo "Kernel module signature report asset: $kernel_signature_report_base"
    echo "Kernel module signature report size: $kernel_signature_report_size"
    echo "Kernel module signature report SHA256: $kernel_signature_report_snapshot_sha"
    echo "Kernel module signature report schema: $build_kernel_signature_report_schema"
    echo "Kernel module total count: $build_kernel_module_total_count"
    echo "Kernel module verified signed count: $build_kernel_module_verified_signed_count"
    echo "Kernel module policy-allowed unsigned count: $build_kernel_module_policy_allowed_unsigned_count"
    echo "Kernel module unsigned-path inventory SHA256: $build_kernel_module_unsigned_path_inventory_sha"
    echo "Image build manifest asset: $image_build_manifest_base"
    echo "Image build manifest size: $image_build_manifest_size"
    echo "Image build manifest SHA256: $image_build_manifest_snapshot_sha"
    echo "APT snapshot ID: $apt_snapshot_id"
    echo "APT snapshot URI: $apt_snapshot_uri"
    echo "Build envelope creation propagation: $inputs_creation_propagation"
    echo "Kernel release propagation: $release_kernel_propagation"
    echo "Kernel provenance propagation: complete"
    echo "OCI index image: $inputs_oci_image"
    echo "OCI index digest: $inputs_oci_digest"
    echo "OCI platform: $inputs_oci_platform"
    echo "OCI platform manifest: $inputs_oci_platform_manifest"
  else
    echo "Release manifest schema: sp11-live-image-draft-v1"
    echo "Kernel provenance propagation: incomplete"
  fi
  echo "Publication state: blocked"
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
        "$apt_provenance_base" \
        "$build_inputs_base" \
        "$touchscreen_module_manifest_base" \
        "$touchscreen_signing_certificate_base" \
        "$kernel_signature_report_base" \
        "$image_build_manifest_base"; do
        echo "- $binding_file"
        echo "  - SHA256: $(shasum -a 256 "$OUT_DIR/$binding_file" | awk '{print $1}')"
      done
    fi
  else
    echo "- Not included; this output is a local draft and cannot be published."
  fi
} > "$OUT_DIR/$MANIFEST_NAME"

outer_labels="$(awk '
  /^## / { exit }
  /^[A-Za-z][A-Za-z0-9 -]*: / {
    sub(/:.*/, "")
    print
  }
' "$OUT_DIR/$MANIFEST_NAME")"
if [ "$VALIDATE_IMAGE" = "true" ]; then
  expected_outer_labels="$(printf '%s\n' \
    Generated \
    Release \
    'Release manifest schema' \
    'Kernel build schema' \
    'Kernel release schema' \
    'Touchscreen module contract' \
    'Image build schema' \
    'Kernel build manifest asset' \
    'Kernel build manifest size' \
    'Kernel build manifest SHA256' \
    'Kernel release manifest asset' \
    'Kernel release manifest size' \
    'Kernel release manifest SHA256' \
    'APT provenance asset' \
    'APT provenance schema' \
    'APT provenance size' \
    'APT provenance SHA256' \
    'Build inputs asset' \
    'Build inputs schema' \
    'Build inputs size' \
    'Build inputs SHA256' \
    'Touchscreen module manifest asset' \
    'Touchscreen module manifest size' \
    'Touchscreen module manifest SHA256' \
    'Module signing policy' \
    'Module signing private material retained' \
    'Module signing hash algorithm' \
    'Module signing certificate asset' \
    'Module signing certificate size' \
    'Module signing certificate SHA256' \
    'Module signing certificate fingerprint' \
    'Module signing certificate serial' \
    'Kernel module signature report asset' \
    'Kernel module signature report size' \
    'Kernel module signature report SHA256' \
    'Kernel module signature report schema' \
    'Kernel module total count' \
    'Kernel module verified signed count' \
    'Kernel module policy-allowed unsigned count' \
    'Kernel module unsigned-path inventory SHA256' \
    'Image build manifest asset' \
    'Image build manifest size' \
    'Image build manifest SHA256' \
    'APT snapshot ID' \
    'APT snapshot URI' \
    'Build envelope creation propagation' \
    'Kernel release propagation' \
    'Kernel provenance propagation' \
    'OCI index image' \
    'OCI index digest' \
    'OCI platform' \
    'OCI platform manifest' \
    'Publication state' \
    'Support repo commit' \
    'Support repo dirty' \
    'Image source' \
    'Image validation' \
    Compression \
    'Compressed image' \
    'Compressed image size' \
    'Compressed image SHA256' \
    'Part size limit')"
  [ "$outer_labels" = "$expected_outer_labels" ] || {
    echo "Generated live-image release manifest field order does not match schema v1." >&2
    exit 1
  }
  [ "$(required_manifest_value "$OUT_DIR/$MANIFEST_NAME" "Release manifest schema")" = \
      "sp11-live-image-release-v1" ] &&
    [ "$(required_manifest_value "$OUT_DIR/$MANIFEST_NAME" "Kernel provenance propagation")" = \
      "complete" ] || {
      echo "Generated live-image release manifest does not attest completed kernel propagation." >&2
      exit 1
    }
else
  expected_outer_labels="$(printf '%s\n' \
    Generated \
    Release \
    'Release manifest schema' \
    'Kernel provenance propagation' \
    'Publication state' \
    'Support repo commit' \
    'Support repo dirty' \
    'Image source' \
    'Image validation' \
    Compression \
    'Compressed image' \
    'Compressed image size' \
    'Compressed image SHA256' \
    'Part size limit')"
  [ "$outer_labels" = "$expected_outer_labels" ] || {
    echo "Generated live-image draft manifest field order does not match its schema." >&2
    exit 1
  }
fi
[ "$(required_manifest_value "$OUT_DIR/$MANIFEST_NAME" "Publication state")" = "blocked" ] || {
  echo "Generated live-image manifest is not explicitly blocked from publication." >&2
  exit 1
}
outer_manifest_sha="$(shasum -a 256 "$OUT_DIR/$MANIFEST_NAME" | awk '{print $1}')"

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
        "$apt_provenance_base"
        "$build_inputs_base"
        "$touchscreen_module_manifest_base"
        "$touchscreen_signing_certificate_base"
        "$kernel_signature_report_base"
        "$image_build_manifest_base"
      )
    fi
  fi
  shasum -a 256 "${checksum_inputs[@]}" > SHA256SUMS
)
main_checksum_sha="$(shasum -a 256 "$OUT_DIR/SHA256SUMS" | awk '{print $1}')"
source_checksum_sha=""
if [ "$source_complete" = "true" ]; then
  source_checksum_sha="$(
    shasum -a 256 "$OUT_DIR/$SOURCE_CHECKSUM_NAME" | awk '{print $1}'
  )"
fi

cat > "$OUT_DIR/RELEASE-NOTES.md" <<RELEASE_NOTES_END
# Surface Pro 11 Live USB Image

Experimental direct-boot Ubuntu live USB raw disk image for Surface Pro 11.

This image is an optional convenience artifact. The raw image has no separate
release-asset signature, is not an installer ISO, and should be written only to
the intended removable device. Its embedded kernel and touchscreen modules use
the controlled signing policy recorded in the release manifest, with public
certificate `$TOUCHSCREEN_SIGNING_CERTIFICATE_NAME` included for verification.

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
    "kernel-release, APT-provenance, build-inputs, and module manifests, plus" \
    "the public module-signing certificate and" \
    "\`$KERNEL_SIGNATURE_REPORT_NAME\` verification report," \
    "cryptographically bind those archives," \
    "the embedded ISO/DTB/support tree, and the image payload." \
    "Together they cover the patched kernel and exact" \
    "source/build-control files for the three touchscreen modules embedded in the" \
    "image."
else
  printf '%s\n' "Corresponding source is not included. This output is a local draft only."
fi)

## Provenance

See \`$MANIFEST_NAME\` for image size, checksum, support repository commit,
controlled kernel-module signature counts, and validation status. The raw image
is intentionally split into compressed parts
because GitHub release assets must be smaller than $GITHUB_ASSET_LIMIT_BYTES
bytes each.

These artifacts were built from recorded inputs; they are not claimed to be
bit-for-bit reproducible.

Publication remains blocked. $(if [ "$VALIDATE_IMAGE" = "true" ] &&
  [ "$source_complete" = "true" ] && [ "$binding_complete" = "true" ]; then
  printf '%s' 'The immutable APT and build-input propagation attestation is complete, but'
else
  printf '%s' 'This local draft has incomplete kernel-provenance propagation, and'
fi) this preparation does not waive the independent real-build, recovery,
corresponding-source, or release-authorization gates. The interim
licence/UCM direction is recorded in LEGAL.md with final reviews pending; those
reviews are disclosure obligations rather than a blanket block on newly
authored artifacts.
RELEASE_NOTES_END
release_notes_sha="$(shasum -a 256 "$OUT_DIR/RELEASE-NOTES.md" | awk '{print $1}')"

if [ "$VALIDATE_IMAGE" = "true" ]; then
  public_output_args=(
    --file "$OUT_DIR/$OUTLINE_NAME"
    --file "$OUT_DIR/$MANIFEST_NAME"
    --file "$OUT_DIR/$SOURCE_NOTICE_NAME"
    --file "$OUT_DIR/$SOURCE_CHECKSUM_NAME"
    --file "$OUT_DIR/$kernel_build_manifest_base"
    --file "$OUT_DIR/$kernel_release_manifest_base"
    --file "$OUT_DIR/$apt_provenance_base"
    --file "$OUT_DIR/$build_inputs_base"
    --file "$OUT_DIR/$touchscreen_module_manifest_base"
    --file "$OUT_DIR/$kernel_signature_report_base"
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
      "$apt_provenance_base"
      "$build_inputs_base"
      "$touchscreen_module_manifest_base"
      "$touchscreen_signing_certificate_base"
      "$kernel_signature_report_base"
      "$image_build_manifest_base"
    )
  fi
fi
for part in "${parts[@]}"; do
  release_assets+=("$(basename "$part")")
done

verify_prepared_output() {
  local prepared_dir="$1"
  local actual_members expected_members release_asset expected_checksum_members
  local actual_checksum_members expected_source_members actual_source_members
  local final_outer_labels final_expected_payload final_compressed_sha final_raw_sha
  local binding_index binding_file binding_label binding_size binding_sha
  local outer_index outer_value part_file part_base part_size part_sha
  local public_args=()
  local prepared_members=("${release_assets[@]}" "RELEASE-NOTES.md")
  local checksum_members=()
  local part_files=()

  [ -d "$prepared_dir" ] && [ ! -L "$prepared_dir" ] || {
    echo "Prepared image output is not a regular directory." >&2
    return 1
  }
  expected_members="$(printf '%s\n' "${prepared_members[@]}" | LC_ALL=C sort)"
  actual_members="$(
    find "$prepared_dir" -mindepth 1 -maxdepth 1 -print |
      while IFS= read -r prepared_path; do basename "$prepared_path"; done |
      LC_ALL=C sort
  )"
  if [ "$actual_members" != "$expected_members" ]; then
    echo "Prepared image output membership differs from the exact allowlist." >&2
    return 1
  fi
  for release_asset in "${prepared_members[@]}"; do
    [ -s "$prepared_dir/$release_asset" ] && [ -f "$prepared_dir/$release_asset" ] &&
      [ ! -L "$prepared_dir/$release_asset" ] || {
      echo "Prepared image output has an unsafe or empty final file: $release_asset" >&2
      return 1
    }
  done
  if [ "$(shasum -a 256 "$prepared_dir/$OUTLINE_NAME" | awk '{print $1}')" != \
      "$outline_sha" ]; then
    echo "Prepared image outline bytes changed after generation." >&2
    return 1
  fi
  if [ "$(shasum -a 256 "$prepared_dir/$MANIFEST_NAME" | awk '{print $1}')" != \
      "$outer_manifest_sha" ]; then
    echo "Prepared live-image outer manifest bytes changed after generation." >&2
    return 1
  fi
  if [ "$(shasum -a 256 "$prepared_dir/RELEASE-NOTES.md" | awk '{print $1}')" != \
      "$release_notes_sha" ]; then
    echo "Prepared image release-note bytes changed after generation." >&2
    return 1
  fi
  if [ "$(shasum -a 256 "$prepared_dir/SHA256SUMS" | awk '{print $1}')" != \
      "$main_checksum_sha" ]; then
    echo "Prepared image SHA256SUMS bytes changed after generation." >&2
    return 1
  fi
  if [ "$source_complete" = "true" ] &&
    [ "$(shasum -a 256 "$prepared_dir/$SOURCE_CHECKSUM_NAME" | awk '{print $1}')" != \
      "$source_checksum_sha" ]; then
    echo "Prepared image $SOURCE_CHECKSUM_NAME bytes changed after generation." >&2
    return 1
  fi

  for release_asset in "${release_assets[@]}"; do
    [ "$release_asset" = "SHA256SUMS" ] || checksum_members+=("$release_asset")
  done
  if ! grep -Eq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$' "$prepared_dir/SHA256SUMS" ||
    grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$' "$prepared_dir/SHA256SUMS"; then
    echo "Prepared image SHA256SUMS has an invalid row." >&2
    return 1
  fi
  expected_checksum_members="$(printf '%s\n' "${checksum_members[@]}" | LC_ALL=C sort)"
  actual_checksum_members="$(awk '{print $2}' "$prepared_dir/SHA256SUMS" | LC_ALL=C sort)"
  if [ "$actual_checksum_members" != "$expected_checksum_members" ]; then
    echo "Prepared image SHA256SUMS membership differs from the exact upload inventory." >&2
    return 1
  fi
  if ! (cd "$prepared_dir" && shasum -a 256 -c SHA256SUMS >/dev/null); then
    echo "Prepared image output does not match its final SHA256SUMS." >&2
    return 1
  fi

  if [ "$source_complete" = "true" ]; then
    if ! grep -Eq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$' \
        "$prepared_dir/$SOURCE_CHECKSUM_NAME" ||
      grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$' \
        "$prepared_dir/$SOURCE_CHECKSUM_NAME"; then
      echo "Prepared image $SOURCE_CHECKSUM_NAME has an invalid row." >&2
      return 1
    fi
    expected_source_members="$(printf '%s\n' "${source_checksum_inputs[@]}" | LC_ALL=C sort)"
    actual_source_members="$(
      awk '{print $2}' "$prepared_dir/$SOURCE_CHECKSUM_NAME" | LC_ALL=C sort
    )"
    if [ "$actual_source_members" != "$expected_source_members" ]; then
      echo "Prepared image $SOURCE_CHECKSUM_NAME membership is not exact." >&2
      return 1
    fi
    if ! (cd "$prepared_dir" && shasum -a 256 -c "$SOURCE_CHECKSUM_NAME" >/dev/null); then
      echo "Prepared image source assets do not match $SOURCE_CHECKSUM_NAME." >&2
      return 1
    fi
    if [ "$(shasum -a 256 "$prepared_dir/$kernel_source_base" | awk '{print $1}')" != \
        "$kernel_source_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$prepared_dir/$touchscreen_source_base" | awk '{print $1}')" != \
        "$touchscreen_source_snapshot_sha" ] ||
      [ "$(shasum -a 256 "$prepared_dir/$SOURCE_NOTICE_NAME" | awk '{print $1}')" != \
        "$source_notice_snapshot_sha" ]; then
      echo "Prepared image corresponding-source bytes changed after validation." >&2
      return 1
    fi
  fi

  if [ "$binding_complete" = "true" ]; then
    local binding_files=(
      "$kernel_build_manifest_base"
      "$kernel_release_manifest_base"
      "$apt_provenance_base"
      "$build_inputs_base"
      "$touchscreen_module_manifest_base"
      "$touchscreen_signing_certificate_base"
      "$kernel_signature_report_base"
      "$image_build_manifest_base"
    )
    local binding_labels=(
      'Kernel build manifest'
      'Kernel release manifest'
      'APT provenance'
      'Build inputs'
      'Touchscreen module manifest'
      'Touchscreen public signing certificate'
      'Kernel module signature report'
      'Image build manifest'
    )
    local binding_sizes=(
      "$kernel_build_manifest_size"
      "$kernel_release_manifest_size"
      "$apt_provenance_size"
      "$build_inputs_size"
      "$touchscreen_module_manifest_size"
      "$touchscreen_signing_certificate_size"
      "$kernel_signature_report_size"
      "$image_build_manifest_size"
    )
    local binding_shas=(
      "$kernel_build_manifest_snapshot_sha"
      "$kernel_release_manifest_snapshot_sha"
      "$apt_provenance_snapshot_sha"
      "$build_inputs_snapshot_sha"
      "$touchscreen_module_manifest_snapshot_sha"
      "$touchscreen_signing_certificate_snapshot_sha"
      "$kernel_signature_report_snapshot_sha"
      "$image_build_manifest_snapshot_sha"
    )
    binding_index=0
    while [ "$binding_index" -lt "${#binding_files[@]}" ]; do
      binding_file="${binding_files[$binding_index]}"
      binding_label="${binding_labels[$binding_index]}"
      binding_size="${binding_sizes[$binding_index]}"
      binding_sha="${binding_shas[$binding_index]}"
      if [ "$(file_size "$prepared_dir/$binding_file")" != "$binding_size" ] ||
        [ "$(shasum -a 256 "$prepared_dir/$binding_file" | awk '{print $1}')" != \
          "$binding_sha" ]; then
        echo "Prepared $binding_label bytes changed after validation." >&2
        return 1
      fi
      binding_index=$((binding_index + 1))
    done
  fi

  final_outer_labels="$(awk '
    /^## / { exit }
    /^[A-Za-z][A-Za-z0-9 -]*: / { sub(/:.*/, ""); print }
  ' "$prepared_dir/$MANIFEST_NAME")"
  if [ "$final_outer_labels" != "$expected_outer_labels" ]; then
    echo "Prepared live-image outer manifest field order changed." >&2
    return 1
  fi
  if [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" "Publication state")" != \
      "blocked" ] ||
    [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" "Compressed image")" != \
      "$compressed_base" ] ||
    [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" "Compressed image size")" != \
      "$compressed_size bytes" ] ||
    [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" "Compressed image SHA256")" != \
      "$compressed_sha" ]; then
    echo "Prepared live-image outer manifest changed its archive or publication state." >&2
    return 1
  fi
  grep -Fxq -- "- $image_base" "$prepared_dir/$MANIFEST_NAME" &&
    grep -Fxq "  - Size: $image_size bytes" "$prepared_dir/$MANIFEST_NAME" &&
    grep -Fxq "  - SHA256: $image_sha" "$prepared_dir/$MANIFEST_NAME" || {
    echo "Prepared live-image outer manifest changed its raw-image identity." >&2
    return 1
  }

  if [ "$VALIDATE_IMAGE" = "true" ]; then
    local outer_labels_to_check=(
      'Release manifest schema'
      'Kernel build schema'
      'Kernel release schema'
      'Touchscreen module contract'
      'Image build schema'
      'Kernel build manifest asset'
      'Kernel build manifest size'
      'Kernel build manifest SHA256'
      'Kernel release manifest asset'
      'Kernel release manifest size'
      'Kernel release manifest SHA256'
      'APT provenance asset'
      'APT provenance schema'
      'APT provenance size'
      'APT provenance SHA256'
      'Build inputs asset'
      'Build inputs schema'
      'Build inputs size'
      'Build inputs SHA256'
      'Touchscreen module manifest asset'
      'Touchscreen module manifest size'
      'Touchscreen module manifest SHA256'
      'Module signing policy'
      'Module signing private material retained'
      'Module signing hash algorithm'
      'Module signing certificate asset'
      'Module signing certificate size'
      'Module signing certificate SHA256'
      'Module signing certificate fingerprint'
      'Module signing certificate serial'
      'Kernel module signature report asset'
      'Kernel module signature report size'
      'Kernel module signature report SHA256'
      'Kernel module signature report schema'
      'Kernel module total count'
      'Kernel module verified signed count'
      'Kernel module policy-allowed unsigned count'
      'Kernel module unsigned-path inventory SHA256'
      'Image build manifest asset'
      'Image build manifest size'
      'Image build manifest SHA256'
      'APT snapshot ID'
      'APT snapshot URI'
      'Build envelope creation propagation'
      'Kernel release propagation'
      'Kernel provenance propagation'
      'OCI index image'
      'OCI index digest'
      'OCI platform'
      'OCI platform manifest'
    )
    local outer_values_to_check=(
      'sp11-live-image-release-v1'
      "$build_schema"
      "$release_outer_schema"
      "$module_contract"
      "$image_build_schema"
      "$kernel_build_manifest_base"
      "$kernel_build_manifest_size"
      "$kernel_build_manifest_snapshot_sha"
      "$kernel_release_manifest_base"
      "$kernel_release_manifest_size"
      "$kernel_release_manifest_snapshot_sha"
      "$apt_provenance_base"
      "$apt_schema"
      "$apt_provenance_size"
      "$apt_provenance_snapshot_sha"
      "$build_inputs_base"
      "$inputs_schema"
      "$build_inputs_size"
      "$build_inputs_snapshot_sha"
      "$touchscreen_module_manifest_base"
      "$touchscreen_module_manifest_size"
      "$touchscreen_module_manifest_snapshot_sha"
      "$module_signing_policy"
      "$module_signing_private_material_retained"
      "$module_signing_hash_algorithm"
      "$touchscreen_signing_certificate_base"
      "$touchscreen_signing_certificate_size"
      "$touchscreen_signing_certificate_snapshot_sha"
      "$module_signing_certificate_fingerprint"
      "$module_signing_certificate_serial"
      "$kernel_signature_report_base"
      "$kernel_signature_report_size"
      "$kernel_signature_report_snapshot_sha"
      "$build_kernel_signature_report_schema"
      "$build_kernel_module_total_count"
      "$build_kernel_module_verified_signed_count"
      "$build_kernel_module_policy_allowed_unsigned_count"
      "$build_kernel_module_unsigned_path_inventory_sha"
      "$image_build_manifest_base"
      "$image_build_manifest_size"
      "$image_build_manifest_snapshot_sha"
      "$apt_snapshot_id"
      "$apt_snapshot_uri"
      "$inputs_creation_propagation"
      "$release_kernel_propagation"
      'complete'
      "$inputs_oci_image"
      "$inputs_oci_digest"
      "$inputs_oci_platform"
      "$inputs_oci_platform_manifest"
    )
    outer_index=0
    while [ "$outer_index" -lt "${#outer_labels_to_check[@]}" ]; do
      outer_value="$(
        required_manifest_value "$prepared_dir/$MANIFEST_NAME" \
          "${outer_labels_to_check[$outer_index]}"
      )"
      if [ "$outer_value" != "${outer_values_to_check[$outer_index]}" ]; then
        echo "Prepared live-image outer manifest binding changed: ${outer_labels_to_check[$outer_index]}" >&2
        return 1
      fi
      outer_index=$((outer_index + 1))
    done
  elif [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" \
      "Release manifest schema")" != "sp11-live-image-draft-v1" ] ||
    [ "$(required_manifest_value "$prepared_dir/$MANIFEST_NAME" \
      "Kernel provenance propagation")" != "incomplete" ]; then
    echo "Prepared live-image draft lost its explicit nonpublishable state." >&2
    return 1
  fi

  for part_file in "${parts[@]}"; do
    part_base="$(basename "$part_file")"
    part_file="$prepared_dir/$part_base"
    part_size="$(file_size "$part_file")"
    part_sha="$(shasum -a 256 "$part_file" | awk '{print $1}')"
    grep -Fxq -- "- $part_base" "$prepared_dir/$MANIFEST_NAME" &&
      grep -Fxq "  - Size: $part_size bytes" "$prepared_dir/$MANIFEST_NAME" &&
      grep -Fxq "  - SHA256: $part_sha" "$prepared_dir/$MANIFEST_NAME" || {
      echo "Prepared live-image outer manifest changed a split-part identity." >&2
      return 1
    }
    part_files+=("$part_file")
  done
  if [ "$(file_size "$IMAGE_SNAPSHOT")" != "$image_size" ] ||
    [ "$(shasum -a 256 "$IMAGE_SNAPSHOT" | awk '{print $1}')" != "$image_sha" ]; then
    echo "Private raw-image snapshot changed before final output verification." >&2
    return 1
  fi
  final_compressed_sha="$(cat "${part_files[@]}" | shasum -a 256 | awk '{print $1}')"
  final_raw_sha="$(cat "${part_files[@]}" | zstd -dc | shasum -a 256 | awk '{print $1}')"
  if [ "$final_compressed_sha" != "$compressed_sha" ] || [ "$final_raw_sha" != "$image_sha" ]; then
    echo "Prepared split archive does not reconstruct the validated raw-image snapshot." >&2
    return 1
  fi

  if [ "$VALIDATE_IMAGE" = "true" ]; then
    final_expected_payload="$SOURCE_SNAPSHOT_DIR/final-expected-payload-sha256"
    if ! python3 -I "$release_manifest_validator" \
        --require-current-head \
        --repo-dir "$repo_dir" \
        --support-commit "$repo_commit" \
        --release-name "$RELEASE_NAME" \
        --kernel-build-manifest "$prepared_dir/$kernel_build_manifest_base" \
        --kernel-release-manifest "$prepared_dir/$kernel_release_manifest_base" \
        --apt-provenance "$prepared_dir/$apt_provenance_base" \
        --build-inputs "$prepared_dir/$build_inputs_base" \
        --touchscreen-module-manifest "$prepared_dir/$touchscreen_module_manifest_base" \
        --kernel-source "$prepared_dir/$kernel_source_base" \
        --touchscreen-source "$prepared_dir/$touchscreen_source_base" \
        --expected-payload-out "$final_expected_payload"; then
      echo "Prepared image attachments failed final six-manifest validation." >&2
      return 1
    fi
    if ! "$payload_identity_validator" \
        --expected "$final_expected_payload" \
        --actual "$payload_output_dir/actual-payload-sha256" >/dev/null; then
      echo "Prepared manifests no longer match the validated raw-image payload." >&2
      return 1
    fi
    if ! python3 -I "$source_archive_validator" kernel \
        --archive "$prepared_dir/$kernel_source_base" --expected-tree "$build_patched_tree" ||
      ! python3 -I "$source_archive_validator" touchscreen \
        --archive "$prepared_dir/$touchscreen_source_base" \
        --expected-modules-tree "$module_source_tree" \
        --expected-license-blob "$module_license_blob" \
        --license-mode "$module_license_mode" \
        --expected-archive-comment "$module_source_commit"; then
      echo "Prepared corresponding-source archives failed final exact-tree validation." >&2
      return 1
    fi
    if ! python3 "$image_build_manifest_validator" \
        --manifest "$prepared_dir/$image_build_manifest_base" \
        --image "$IMAGE_SNAPSHOT" \
        --support-commit "$repo_commit" \
        --support-manifest "$expected_support_manifest" \
        --expected-kernel-dtb-sha256 "$build_kernel_dtb_sha" \
        --actual-layout "$payload_output_dir/actual-image-layout" >/dev/null; then
      echo "Prepared image-build manifest failed final raw-image validation." >&2
      return 1
    fi
  fi

  public_args=(
    --file "$prepared_dir/$OUTLINE_NAME"
    --file "$prepared_dir/$MANIFEST_NAME"
    --file "$prepared_dir/SHA256SUMS"
    --file "$prepared_dir/RELEASE-NOTES.md"
  )
  if [ "$source_complete" = "true" ]; then
    public_args+=(
      --file "$prepared_dir/$SOURCE_NOTICE_NAME"
      --file "$prepared_dir/$SOURCE_CHECKSUM_NAME"
    )
    if [ "$binding_complete" = "true" ]; then
      public_args+=(
        --file "$prepared_dir/$kernel_build_manifest_base"
        --file "$prepared_dir/$kernel_release_manifest_base"
        --file "$prepared_dir/$apt_provenance_base"
        --file "$prepared_dir/$build_inputs_base"
        --file "$prepared_dir/$touchscreen_module_manifest_base"
        --file "$prepared_dir/$kernel_signature_report_base"
        --file "$prepared_dir/$image_build_manifest_base"
      )
    fi
  fi
  if ! "$public_content_validator" "${public_args[@]}" >/dev/null; then
    echo "Prepared image output failed final public-content validation." >&2
    return 1
  fi
}

verify_final_support_state
if ! verify_prepared_output "$OUT_DIR"; then
  echo "Pre-install image release verification failed." >&2
  exit 1
fi
if [ "$(directory_identity "$OUTPUT_STAGING_DIR" 2>/dev/null || true)" != \
    "$OUTPUT_STAGING_IDENTITY" ]; then
  echo "Prepared image staging directory identity changed before installation." >&2
  exit 1
fi
OUTPUT_STAGING_TREE="$(stable_directory_tree_identity "$OUTPUT_STAGING_DIR")" || {
  echo "Could not capture a stable prepared image tree before installation." >&2
  exit 1
}
if [ "$source_complete" = "true" ] && [ "$binding_complete" = "true" ]; then
  verify_kernel_candidate_root || {
    echo "Committed kernel candidate root changed before image-release installation." >&2
    exit 1
  }
  for kernel_candidate_input in "${kernel_candidate_inputs[@]}"; do
    verify_kernel_candidate_member "$kernel_candidate_input" || {
      echo "Committed kernel candidate input changed before image-release installation." >&2
      exit 1
    }
  done
fi
INSTALLED_OUTPUT_IDENTITY="$OUTPUT_STAGING_IDENTITY"
INSTALLED_OUTPUT_TREE="$OUTPUT_STAGING_TREE"

if [ -e "$FINAL_OUT_DIR" ] || [ -L "$FINAL_OUT_DIR" ]; then
  [ -d "$FINAL_OUT_DIR" ] && [ ! -L "$FINAL_OUT_DIR" ] || {
    echo "Refusing to replace a non-directory or symlinked image release output." >&2
    exit 1
  }
  PREVIOUS_OUTPUT_IDENTITY="$(directory_identity "$FINAL_OUT_DIR")"
  PREVIOUS_OUTPUT_TREE="$(stable_directory_tree_identity "$FINAL_OUT_DIR")" || {
    echo "Could not capture a stable identity for the existing image output." >&2
    exit 1
  }
  PREVIOUS_OUTPUT_CONTAINER="$(
    mktemp -d "$release_root_abs/.${out_leaf}.previous.XXXXXX"
  )"
  chmod 700 "$PREVIOUS_OUTPUT_CONTAINER"
  PREVIOUS_OUTPUT_CONTAINER_IDENTITY="$(directory_identity "$PREVIOUS_OUTPUT_CONTAINER")"
  PREVIOUS_OUTPUT_PATH="$PREVIOUS_OUTPUT_CONTAINER/original"
fi
OUTPUT_INSTALL_PENDING="true"
if [ -n "$PREVIOUS_OUTPUT_PATH" ]; then
  if ! mv "$FINAL_OUT_DIR" "$PREVIOUS_OUTPUT_PATH"; then
    OUTPUT_INSTALL_PENDING="false"
    if remove_exact_empty_private_container \
        "$PREVIOUS_OUTPUT_CONTAINER" "$PREVIOUS_OUTPUT_CONTAINER_IDENTITY"; then
      PREVIOUS_OUTPUT_CONTAINER=""
      PREVIOUS_OUTPUT_PATH=""
    else
      echo "Preserved changed previous-output recovery container: $PREVIOUS_OUTPUT_CONTAINER" >&2
    fi
    echo "Could not retain the previous image release directory privately." >&2
    exit 1
  fi
  if [ "$(directory_identity "$PREVIOUS_OUTPUT_PATH" 2>/dev/null || true)" != \
      "$PREVIOUS_OUTPUT_IDENTITY" ] ||
    [ "$(directory_identity "$PREVIOUS_OUTPUT_CONTAINER" 2>/dev/null || true)" != \
      "$PREVIOUS_OUTPUT_CONTAINER_IDENTITY" ] ||
    ! private_container_has_only "$PREVIOUS_OUTPUT_CONTAINER" original; then
    echo "Previous image output identity changed while it was retained." >&2
    exit 1
  fi
  moved_previous_tree="$(stable_directory_tree_identity "$PREVIOUS_OUTPUT_PATH")" || {
    echo "Could not capture a stable private identity for the previous image output." >&2
    exit 1
  }
  if [ "$moved_previous_tree" != "$PREVIOUS_OUTPUT_TREE" ]; then
    echo "Previous image output tree changed while it was retained privately." >&2
    exit 1
  fi
fi
[ ! -e "$FINAL_OUT_DIR" ] && [ ! -L "$FINAL_OUT_DIR" ] || {
  echo "Image release destination was occupied during atomic installation." >&2
  exit 1
}
if ! mv "$OUTPUT_STAGING_DIR" "$FINAL_OUT_DIR"; then
  echo "Could not atomically install the prepared image release directory." >&2
  exit 1
fi
OUT_DIR="$FINAL_OUT_DIR"
if [ "$(directory_identity "$FINAL_OUT_DIR" 2>/dev/null || true)" != \
    "$INSTALLED_OUTPUT_IDENTITY" ]; then
  echo "Installed image release directory identity changed during atomic installation." >&2
  exit 1
fi
OUTPUT_STAGING_DIR=""
OUTPUT_STAGING_IDENTITY=""
OUTPUT_STAGING_TREE=""
if ! verify_prepared_output "$FINAL_OUT_DIR"; then
  echo "Post-install image release verification failed." >&2
  exit 1
fi
if ! verify_final_support_state; then
  echo "Post-install support-state verification failed." >&2
  exit 1
fi
if ! verify_prepared_output "$FINAL_OUT_DIR"; then
  echo "Final committed image release verification failed." >&2
  exit 1
fi

retired_previous_container="$PREVIOUS_OUTPUT_CONTAINER"
retired_previous_container_identity="$PREVIOUS_OUTPUT_CONTAINER_IDENTITY"
retired_previous_path="$PREVIOUS_OUTPUT_PATH"
retired_previous_identity="$PREVIOUS_OUTPUT_IDENTITY"
retired_previous_tree="$PREVIOUS_OUTPUT_TREE"
OUTPUT_INSTALL_PENDING="false"
INSTALLED_OUTPUT_IDENTITY=""
INSTALLED_OUTPUT_TREE=""
PREVIOUS_OUTPUT_CONTAINER=""
PREVIOUS_OUTPUT_CONTAINER_IDENTITY=""
PREVIOUS_OUTPUT_PATH=""
PREVIOUS_OUTPUT_IDENTITY=""
PREVIOUS_OUTPUT_TREE=""

if [ -n "$retired_previous_container" ]; then
  retire_previous="true"
  if [ "$(directory_identity "$retired_previous_container" 2>/dev/null || true)" != \
      "$retired_previous_container_identity" ] ||
    ! private_container_has_only "$retired_previous_container" original ||
    [ "$(directory_identity "$retired_previous_path" 2>/dev/null || true)" != \
      "$retired_previous_identity" ] ||
    [ "$(stable_directory_tree_identity "$retired_previous_path" 2>/dev/null || true)" != \
      "$retired_previous_tree" ]; then
    retire_previous="false"
  fi
  if [ "$retire_previous" = "true" ]; then
    if ! rm -rf -- "$retired_previous_container"; then
      echo "The verified image output is committed, but previous-output retirement failed; preserved recovery data: $retired_previous_container" >&2
    fi
  else
    echo "The verified image output is committed, but the previous output changed; preserved recovery data: $retired_previous_container" >&2
  fi
fi

echo "Prepared release assets in $OUT_DIR_DISPLAY"
echo
if [ "$VALIDATE_IMAGE" != "true" ] || [ "$source_complete" != "true" ] ||
  [ "$binding_complete" != "true" ] || [ "$dirty" != "false" ]; then
  echo "Local draft only: validation, complete source/provenance, and a clean support tree are required before any publication review."
else
  echo "Validated preparation only: immutable kernel provenance propagation is complete."
fi
echo "NO-PUBLISH: independent real-build, recovery, corresponding-source, and release-authorization gates remain open; final licence/UCM reviews remain disclosed in LEGAL.md."
