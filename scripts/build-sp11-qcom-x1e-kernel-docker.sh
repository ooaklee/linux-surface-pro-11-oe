#!/usr/bin/env bash
set -euo pipefail

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_TEMPLATE_DIR GIT_WORK_TREE
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

IMAGE=""
IMAGE_EXPLICIT="false"
PLATFORM="linux/arm64"
PLATFORM_EXPLICIT="false"
WORK_DIR="build/docker-sp11-qcom-x1e-kernel"
WORK_ROOT_IDENTITY=""
WORK_ROOT_FD=52
WORK_ROOT_FD_OPEN="false"
WORK_ROOT_IMPORT_IDENTITY=()
RELEASE_WORK_DIR_NAMES=()
RELEASE_WORK_DIR_IDENTITIES=()
RELEASE_ARTIFACTS_FD=58
RELEASE_ARTIFACTS_FD_OPEN="false"
RELEASE_ARTIFACTS_IDENTITY=""
RELEASE_ARTIFACTS_IMPORT_IDENTITY=()
RELEASE_BUILD_ARGS_IMPORT_IDENTITY=()
RELEASE_ENTRYPOINT_IMPORT_IDENTITY=()
RELEASE_OCI_INDEX_IMPORT_IDENTITY=()
CONTAINER_WORK_DIR="/linux-work"
LINUX_WORK_VOLUME="sp11-qcom-x1e-kernel-build"
METADATA=""
SOURCE_MODE="apt"
SOURCE_PACKAGE=""
SOURCE_VERSION=""
GIT_URL=""
GIT_BRANCH=""
EXPECTED_SOURCE_COMMIT=""
BUILD_TARGET=""
PATCH_DIR=""
PATCH_DIRS=""
JOBS=""
MIN_FREE_GB=""
APT_SOURCES_FILE=""
ENABLE_DEB_SRC="true"
COPY_TO_PAYLOAD="false"
PAYLOAD_DIR="payload/kernel-debs"
RESET_SOURCE="false"
SKIP_CLEAN="false"
DRY_RUN="false"
RELEASE_BUILD="false"
SUPPORT_HEAD_START=""
CONTROL_DIR=""
PAYLOAD_STAGE=""
KERNEL_BASELINE=""
KERNEL_BASELINE_ACCESS=""
KERNEL_BASELINE_FD=53
KERNEL_BASELINE_FD_OPEN="false"
KERNEL_BASELINE_REL="config/kernel-baselines/7.2-rc5-jg-0.env"
KERNEL_BASELINE_VALIDATOR_REL="scripts/validate-sp11-kernel-baseline.sh"
BASELINE_CONTROL_DIR=""
BASELINE_CONTROL_PARENT=""
BASELINE_CONTROL_IDENTITY=""
BASELINE_CONTROL_FD=50
BASELINE_CONTROL_FD_OPEN="false"
BASELINE_CONTROL_ACCESS_DIR=""
BASELINE_CONTROL_INITIAL_STATE=""
BASELINE_CONTROL_FINAL_STATE=""
KERNEL_BASELINE_VALIDATOR=""
KERNEL_BASELINE_VALIDATOR_ACCESS=""
KERNEL_BASELINE_VALIDATOR_FD=54
KERNEL_BASELINE_VALIDATOR_FD_OPEN="false"
KERNEL_BASELINE_STATE=""
KERNEL_BASELINE_VALIDATOR_STATE=""
KERNEL_BASELINE_SHA256=""
RELEASE_BUILD_ARGS_STATE=""
RELEASE_BUILD_ARGS_SHA256=""
EXPECTED_RELEASE_BUILD_ARGS_SHA256=""
RELEASE_ENTRYPOINT_STATE=""
RELEASE_ENTRYPOINT_SHA256=""
EXPECTED_RELEASE_ENTRYPOINT_SHA256=""
RELEASE_OCI_INDEX_STATE=""
RELEASE_OCI_INDEX_SHA256=""
EXPECTED_RELEASE_OCI_INDEX_SHA256=""
RELEASE_STATE_VOLUME_NAME=""
RELEASE_STATE_VOLUME_TOKEN=""
DOCKER_BIN=""
RELEASE_PYTHON_BIN="/usr/bin/python3"
RELEASE_PYTHON_IDENTITY=""
RELEASE_OCI_VALIDATOR_IDENTITY=""
RELEASE_OCI_VALIDATOR_SHA256=""
RELEASE_OCI_VALIDATOR_OBJECT_ID=""
RELEASE_OCI_VALIDATOR_MODE=""
RELEASE_OCI_VALIDATOR_SIZE=""
RELEASE_STATE_HELPER_IDENTITY=""
RELEASE_STATE_HELPER_SHA256=""
RELEASE_STATE_HELPER_OBJECT_ID=""
RELEASE_STATE_HELPER_MODE=""
RELEASE_STATE_HELPER_SIZE=""
RELEASE_BUILD_INPUTS_HELPER_SHA256=""
RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID=""
RELEASE_BUILD_INPUTS_HELPER_MODE=""
RELEASE_BUILD_INPUTS_HELPER_SIZE=""
RELEASE_MANIFEST_VALIDATOR_SHA256=""
RELEASE_MANIFEST_VALIDATOR_OBJECT_ID=""
RELEASE_MANIFEST_VALIDATOR_MODE=""
RELEASE_MANIFEST_VALIDATOR_SIZE=""
RELEASE_GIT_OBJECT_FORMAT=""
RELEASE_VALIDATOR_ARGV_SHA256=""
SUPPORT_SNAPSHOT_ROOT=""
SUPPORT_SNAPSHOT_PARENT=""
SUPPORT_SNAPSHOT_ROOT_IDENTITY=""
SUPPORT_SNAPSHOT_FD=51
SUPPORT_SNAPSHOT_FD_OPEN="false"
SUPPORT_SNAPSHOT_ACCESS_ROOT=""
SUPPORT_SNAPSHOT_ROOT_STATE=""
COMMITTED_SUPPORT_DIR=""
COMMITTED_SUPPORT_ACCESS_DIR=""
SUPPORT_SNAPSHOT_TREE=""
SUPPORT_SNAPSHOT_PATHS=()
SUPPORT_SNAPSHOT_TYPES=()
SUPPORT_SNAPSHOT_STATES=()
SUPPORT_SNAPSHOT_NODE_IDENTITIES=()
IMMUTABLE_APT="false"
RELEASE_BASELINE_ID=""
RELEASE_BASELINE_DOCKER_IMAGE=""
RELEASE_BASELINE_DOCKER_PLATFORM=""
RELEASE_BASELINE_DOCKER_PLATFORM_MANIFEST=""
RELEASE_BASELINE_UPSTREAM_URL=""
RELEASE_BASELINE_UPSTREAM_REF=""
RELEASE_BASELINE_UPSTREAM_COMMIT=""
RELEASE_SOURCE_DATE_EPOCH=""
RELEASE_KBUILD_BUILD_USER=""
RELEASE_KBUILD_BUILD_HOST=""
RELEASE_KBUILD_BUILD_TIMESTAMP=""
RELEASE_BASELINE_BUILD_TARGET=""
RELEASE_BASELINE_PATCH_DIRS=""
CONTROL_SNAPSHOT_FILES=()
CONTROL_SNAPSHOT_VALUES=()

usage() {
  cat <<EOF
Usage: $0 [options]

Builds the patched qcom-x1e kernel packages inside a Docker ARM64 Linux
container. This is intended for off-device builds on a faster machine.

Recommended apt-source mode:
  1. On the Surface, run:
       ./scripts/collect-sp11-kernel-source-metadata.sh --out sp11-kernel-source.env
  2. On the Docker host, run:
       $0 --metadata sp11-kernel-source.env --copy-to-payload

Options:
  --metadata FILE        Metadata file from collect-sp11-kernel-source-metadata.sh.
  --source MODE          Source mode for the inner build: apt or git, default apt.
  --source-package NAME  apt source package. Usually comes from --metadata.
  --source-version VER   apt source version. Usually comes from --metadata.
  --git-url URL          Kernel git URL for git mode.
  --git-branch BRANCH    Kernel git branch or tag for git mode.
  --expected-source-commit SHA
                        Require git mode to resolve to this exact 40-hex commit
                        before any patches are applied or a build is started.
  --image IMAGE          Docker image. Defaults to ubuntu:26.04 for apt mode
                         and ubuntu:25.10 for git mode.
  --platform PLATFORM    Docker platform, default $PLATFORM.
  --release-build        Opt in to fail-closed schema-v2 release provenance.
                         Requires an explicit digest-pinned image and platform,
                         exact Git source commit, and clean stable support HEAD.
  --work-dir DIR         Dedicated host control/artifact directory beneath this
                         repository's build/, default $WORK_DIR.
                         Release mode requires DIR and DIR/artifacts to
                         preexist as real, empty, mode-0700 directories owned
                         by the invoking uid.
  --container-work-dir DIR
                         Container build directory, default $CONTAINER_WORK_DIR.
                         The default is backed by a Docker Linux volume so the
                         kernel source is checked out on a case-sensitive
                         filesystem.
  --linux-work-volume NAME
                         Docker volume for --container-work-dir, default
                         $LINUX_WORK_VOLUME. Ignored when --container-work-dir
                         is /work.
  --build-target TARGET  Kernel package target or quoted target list,
                         default from metadata or script.
  --patch-dir DIR        Patch directory to pass to the inner build helper.
  --patch-dirs "DIR1 DIR2 ..."
                        Space-separated list of patch directories,
                        passed through to the inner build helper.
  --jobs N              Parallel build jobs passed to the inner build helper.
  --min-free-gb N        Free-space guard passed to the inner build helper.
  --apt-sources FILE     Optional .sources or .list file to add inside container.
  --no-enable-deb-src    Do not auto-enable deb-src for container Ubuntu sources.
  --copy-to-payload      Copy generated qcom-x1e .deb files to payload/kernel-debs.
  --payload-dir DIR      Repository-relative child of payload/; also enables
                         --copy-to-payload.
  --reset-source         Reset existing source tree in the build work dir.
  --skip-clean           Skip debian/rules clean in the inner build.
  --dry-run              Print the Docker command and inner args, then exit.
  -h, --help             Show this help.

The script builds packages only. Install them on the Surface with
scripts/build-sp11-qcom-x1e-kernel.sh --install-only so the fallback guard runs.
The container runs as root, so the inner build helper bypasses fakeroot.
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

release_python_identity_record() {
  "$RELEASE_PYTHON_BIN" -I -c '
import os
import stat
import sys

path = sys.argv[1]
if sys.flags.isolated != 1 or path != "/usr/bin/python3":
    raise SystemExit(1)
descriptor = os.open(
    path,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
)
try:
    before = os.fstat(descriptor)
    mapped = os.lstat(path)
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(mapped.st_mode)
        or before.st_uid != 0
        or stat.S_IMODE(before.st_mode) & 0o022
        or not stat.S_IMODE(before.st_mode) & 0o111
        or before.st_size <= 0
        or before.st_size > 256 * 1024 * 1024
        or (before.st_dev, before.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise SystemExit(1)
    if not os.pread(descriptor, 1, 0):
        raise SystemExit(1)
    after = os.fstat(descriptor)
    remapped = os.lstat(path)
    fields = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        before.st_nlink,
        before.st_uid,
        before.st_gid,
    )
    if (
        fields
        != (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
            after.st_uid,
            after.st_gid,
        )
        or (after.st_dev, after.st_ino) != (remapped.st_dev, remapped.st_ino)
    ):
        raise SystemExit(1)
    print(*fields)
finally:
    os.close(descriptor)
' "$RELEASE_PYTHON_BIN"
}

capture_release_python_authority() {
  local release_python_fields=()

  [ "$RELEASE_BUILD" = "true" ] || return 0
  RELEASE_PYTHON_IDENTITY="$(release_python_identity_record)" || {
    echo "Release mode requires the trusted real /usr/bin/python3 toolchain authority." >&2
    return 1
  }
  read -r -a release_python_fields <<< "$RELEASE_PYTHON_IDENTITY"
  [ "${#release_python_fields[@]}" -eq 9 ] || return 1
}

verify_release_python_authority() {
  local current

  [ "$RELEASE_BUILD" = "true" ] || return 0
  [ -n "$RELEASE_PYTHON_IDENTITY" ] || return 1
  current="$(release_python_identity_record)" || return 1
  [ "$current" = "$RELEASE_PYTHON_IDENTITY" ]
}

require_apt_list_decoder() {
  if [ -f /usr/lib/apt/apt-helper ] &&
     [ -x /usr/lib/apt/apt-helper ] &&
     [ ! -L /usr/lib/apt/apt-helper ]; then
    return 0
  fi
  require_tool lz4
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

cleanup_control_dir() {
  [ -n "$CONTROL_DIR" ] || return 0
  # Release controls live in BASELINE_CONTROL_DIR and are deliberately
  # retained.  This name-based cleanup is only for the nonrelease staging
  # directory created later in the script.
  [ "$RELEASE_BUILD" != "true" ] || return 0
  case "$CONTROL_DIR" in
    "$work_abs"/.sp11-docker-control.*)
      if [ -d "$CONTROL_DIR" ] && [ ! -L "$CONTROL_DIR" ]; then
        rm -f \
          "$CONTROL_DIR/docker-build-args.txt" \
          "$CONTROL_DIR/docker-build-inside.sh" \
          "$CONTROL_DIR/sp11-oci-index.json"
        rmdir "$CONTROL_DIR" 2>/dev/null || true
      else
        echo "warning: refusing to follow changed Docker control directory: $CONTROL_DIR" >&2
      fi
      ;;
    *)
      echo "warning: refusing to clean unexpected Docker control directory: $CONTROL_DIR" >&2
      ;;
  esac
}

cleanup_payload_stage() {
  [ -n "$PAYLOAD_STAGE" ] || return 0
  # Release mode rejects --copy-to-payload after complete option parsing, so
  # this pathname cleanup is reachable only for the legacy nonrelease copy.
  [ "$RELEASE_BUILD" != "true" ] || return 0
  if [ -z "${payload_abs:-}" ]; then
    echo "warning: refusing to clean a payload stage without a validated payload root" >&2
    return 0
  fi
  case "$PAYLOAD_STAGE" in
    "$payload_abs"/.sp11-kernel-debs.*)
      if [ -d "$PAYLOAD_STAGE" ] && [ ! -L "$PAYLOAD_STAGE" ]; then
        find "$PAYLOAD_STAGE" -mindepth 1 -maxdepth 1 -type f -exec rm -f -- {} +
        rmdir "$PAYLOAD_STAGE" 2>/dev/null || true
      else
        echo "warning: refusing to follow changed payload staging directory: $PAYLOAD_STAGE" >&2
      fi
      ;;
    *)
      echo "warning: refusing to clean unexpected payload staging directory: $PAYLOAD_STAGE" >&2
      ;;
  esac
}

cleanup_held_release_roots() {
  # Closing an inherited directory handle cannot traverse a replaced name.
  if [ "$RELEASE_ARTIFACTS_FD_OPEN" = "true" ]; then
    exec 58<&-
    RELEASE_ARTIFACTS_FD_OPEN="false"
  fi
  if [ "$KERNEL_BASELINE_VALIDATOR_FD_OPEN" = "true" ]; then
    exec 54<&-
    KERNEL_BASELINE_VALIDATOR_FD_OPEN="false"
  fi
  if [ "$KERNEL_BASELINE_FD_OPEN" = "true" ]; then
    exec 53<&-
    KERNEL_BASELINE_FD_OPEN="false"
  fi
  if [ "$WORK_ROOT_FD_OPEN" = "true" ]; then
    exec 52<&-
    WORK_ROOT_FD_OPEN="false"
  fi
  if [ "$BASELINE_CONTROL_FD_OPEN" = "true" ]; then
    exec 50<&-
    BASELINE_CONTROL_FD_OPEN="false"
  fi
  if [ "$SUPPORT_SNAPSHOT_FD_OPEN" = "true" ]; then
    exec 51<&-
    SUPPORT_SNAPSHOT_FD_OPEN="false"
  fi
}

baseline_control_identity() {
  local path="$1"

  case "$(uname -s)" in
    Darwin) stat -f '%d:%i:%Lp:%u:%g' "$path" ;;
    *) stat -c '%d:%i:%a:%u:%g' -- "$path" ;;
  esac
}

baseline_control_file_state() {
  local path="$1" expected_links="${2:-1}" before after digest

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) before="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) before="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  case "$(uname -s)" in
    Darwin) after="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) after="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  [ "$before" = "$after" ] && [ "${before##*:}" = "$expected_links" ] &&
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s:%s\n' "$before" "$digest"
}

baseline_control_directory_state() {
  local path="$1" before after

  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) before="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) before="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  case "$(uname -s)" in
    Darwin) after="$(stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g:%l' "$path")" ;;
    *) after="$(stat -c '%d:%i:%s:%y:%z:%a:%u:%g:%h' -- "$path")" ;;
  esac
  [ "$before" = "$after" ] || return 1
  printf '%s\n' "$before"
}

verify_held_release_directory() {
  local descriptor="$1" path="$2" expected_identity="$3"

  "$RELEASE_PYTHON_BIN" -I -c '
import os
import stat
import sys

descriptor = int(sys.argv[1], 10)
path = sys.argv[2]
expected = sys.argv[3]
held = os.fstat(descriptor)
mapped = os.lstat(path)

def identity(metadata):
    return ":".join(str(value) for value in (
        metadata.st_dev,
        metadata.st_ino,
        format(stat.S_IMODE(metadata.st_mode), "o"),
        metadata.st_uid,
        metadata.st_gid,
    ))

if (
    not stat.S_ISDIR(held.st_mode)
    or stat.S_ISLNK(mapped.st_mode)
    or identity(held) != expected
    or identity(mapped) != expected
    or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
):
    raise SystemExit(1)
' "$descriptor" "$path" "$expected_identity"
}

held_release_directory_identity_fields() {
  local descriptor="$1"

  "$RELEASE_PYTHON_BIN" -I -c '
import os
import stat
import sys

metadata = os.fstat(int(sys.argv[1], 10))
if not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit(1)
print(
    metadata.st_dev,
    metadata.st_ino,
    stat.S_IMODE(metadata.st_mode),
    metadata.st_uid,
    metadata.st_gid,
)
' "$descriptor"
}

held_release_companion_identity_fields() {
  local name="$1" expected_digest="$2"

  "$RELEASE_PYTHON_BIN" -I -c '
import hashlib
import os
import stat
import sys

parent = int(sys.argv[1], 10)
name = sys.argv[2]
expected_digest = sys.argv[3]
if (
    not name
    or name in (".", "..")
    or "/" in name
    or len(expected_digest) != 64
    or any(character not in "0123456789abcdef" for character in expected_digest)
):
    raise SystemExit(1)
descriptor = os.open(
    name,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    dir_fd=parent,
)
try:
    before = os.fstat(descriptor)
    mapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(mapped.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_size <= 0
        or before.st_size > 64 * 1024 * 1024
        or before.st_nlink != 1
        or (before.st_dev, before.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise SystemExit(1)
    digest = hashlib.sha256()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(descriptor, min(65536, before.st_size - offset), offset)
        if not chunk:
            raise SystemExit(1)
        digest.update(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
    remapped = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if (
        os.pread(descriptor, 1, before.st_size)
        or digest.hexdigest() != expected_digest
        or (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_nlink,
        )
        != (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
        )
        or (after.st_dev, after.st_ino) != (remapped.st_dev, remapped.st_ino)
    ):
        raise SystemExit(1)
    print(
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        after.st_nlink,
        after.st_uid,
        after.st_gid,
    )
finally:
    os.close(descriptor)
' "$WORK_ROOT_FD" "$name" "$expected_digest"
}

capture_release_companion_import_identities() {
  local build_args_record entrypoint_record oci_index_record value

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_release_work_root_binding || return 1
  verify_release_work_root_prebuild_membership || return 1
  build_args_record="$(held_release_companion_identity_fields \
    docker-build-args.txt "$RELEASE_BUILD_ARGS_SHA256")" || {
      echo "Could not capture the held release build-arguments identity." >&2
      return 1
    }
  entrypoint_record="$(held_release_companion_identity_fields \
    docker-build-inside.sh "$RELEASE_ENTRYPOINT_SHA256")" || {
      echo "Could not capture the held release entrypoint identity." >&2
      return 1
    }
  oci_index_record="$(held_release_companion_identity_fields \
    sp11-oci-index.json "$RELEASE_OCI_INDEX_SHA256")" || {
      echo "Could not capture the held release OCI-index identity." >&2
      return 1
    }
  read -r -a RELEASE_BUILD_ARGS_IMPORT_IDENTITY <<< "$build_args_record"
  read -r -a RELEASE_ENTRYPOINT_IMPORT_IDENTITY <<< "$entrypoint_record"
  read -r -a RELEASE_OCI_INDEX_IMPORT_IDENTITY <<< "$oci_index_record"
  for value in \
    "${RELEASE_BUILD_ARGS_IMPORT_IDENTITY[@]}" \
    "${RELEASE_ENTRYPOINT_IMPORT_IDENTITY[@]}" \
    "${RELEASE_OCI_INDEX_IMPORT_IDENTITY[@]}"; do
    [[ "$value" =~ ^[0-9]+$ ]] || {
      echo "Release companion import identity is malformed." >&2
      return 1
    }
  done
  [ "${#RELEASE_BUILD_ARGS_IMPORT_IDENTITY[@]}" -eq 9 ] &&
    [ "${#RELEASE_ENTRYPOINT_IMPORT_IDENTITY[@]}" -eq 9 ] &&
    [ "${#RELEASE_OCI_INDEX_IMPORT_IDENTITY[@]}" -eq 9 ] || {
      echo "Release companion import identity field count is not exact." >&2
      return 1
    }
  verify_release_work_root_binding || return 1
  verify_release_work_root_prebuild_membership || return 1
}

verify_held_release_file() {
  local descriptor="$1" path="$2" expected_digest="$3" expected_mode="$4"

  "$RELEASE_PYTHON_BIN" -I -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1], 10)
path = sys.argv[2]
expected_digest = sys.argv[3]
expected_mode = int(sys.argv[4], 8)
held = os.fstat(descriptor)
mapped = os.lstat(path)
if (
    not stat.S_ISREG(held.st_mode)
    or not stat.S_ISREG(mapped.st_mode)
    or stat.S_IMODE(held.st_mode) != expected_mode
    or held.st_nlink != 1
    or held.st_size <= 0
    or held.st_size > 4 * 1024 * 1024
    or (held.st_dev, held.st_ino) != (mapped.st_dev, mapped.st_ino)
):
    raise SystemExit(1)
digest = hashlib.sha256()
offset = 0
while offset < held.st_size:
    chunk = os.pread(descriptor, min(65536, held.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    digest.update(chunk)
    offset += len(chunk)
if os.pread(descriptor, 1, held.st_size) or digest.hexdigest() != expected_digest:
    raise SystemExit(1)
after = os.fstat(descriptor)
remapped = os.lstat(path)
if (
    (held.st_dev, held.st_ino, held.st_size, held.st_mtime_ns, held.st_ctime_ns)
    != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    or (after.st_dev, after.st_ino) != (remapped.st_dev, remapped.st_ino)
):
    raise SystemExit(1)
' "$descriptor" "$path" "$expected_digest" "$expected_mode"
}

held_release_directory_access_path() {
  local descriptor="$1" path="$2" expected_identity="$3"

  if [ "$(uname -s)" = Linux ] &&
     verify_held_release_directory "$descriptor" "$path" "$expected_identity" &&
     [ -d "/proc/self/fd/$descriptor" ]; then
    printf '/proc/self/fd/%s\n' "$descriptor"
  else
    # Darwin /dev/fd entries cannot be traversed as directory roots. Docker
    # Desktop/remote daemons likewise consume bind sources by pathname, not by
    # a transferable client FD; those mounts remain an explicitly rechecked
    # controller/daemon trust boundary.
    printf '%s\n' "$path"
  fi
}

create_release_file_exclusive() {
  local parent="$1" parent_identity="$2" parent_fd="$3"
  local name="$4" maximum="$5" operation="$6"
  shift 6

  [ "$RELEASE_BUILD" = "true" ] || return 1
  "$RELEASE_PYTHON_BIN" -I -c '
import hashlib
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

parent_path, expected_parent_identity = sys.argv[1:3]
parent_descriptor = int(sys.argv[3], 10)
name = sys.argv[4]
maximum = int(sys.argv[5], 10)
operation = sys.argv[6]
arguments = sys.argv[7:]
if (
    not name
    or len(name) > 128
    or name in (".", "..")
    or "/" in name
    or any(ord(character) < 32 or ord(character) == 127 for character in name)
    or maximum <= 0
    or maximum > 64 * 1024 * 1024
    or operation not in ("stdin", "copy", "command")
):
    raise SystemExit(1)

output_flags = (
    os.O_RDWR
    | os.O_CREAT
    | os.O_EXCL
    | os.O_NOFOLLOW
    | os.O_NONBLOCK
    | os.O_CLOEXEC
)

def stable(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )

def directory_identity(metadata):
    return ":".join(str(value) for value in (
        metadata.st_dev,
        metadata.st_ino,
        format(stat.S_IMODE(metadata.st_mode), "o"),
        metadata.st_uid,
        metadata.st_gid,
    ))

def verify_parent(descriptor, held_identity):
    current = os.fstat(descriptor)
    mapped = os.lstat(parent_path)
    if (
        not stat.S_ISDIR(current.st_mode)
        or stat.S_ISLNK(mapped.st_mode)
        or directory_identity(current) != expected_parent_identity
        or directory_identity(current) != held_identity
        or (current.st_dev, current.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise OSError("unsafe release parent")

def write_all(descriptor, data):
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short release write")
        view = view[written:]

parent = -1
output = -1
source = -1
producer = None
created = False
release_signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}

# An invoking shell may have inherited SIGCHLD=SIG_IGN, which lets children
# auto-reap before Popen records an authoritative status.  This embedded
# supervisor is the first child owner in its process: reset once, then require
# the disposition to remain exact at every producer acquisition.
try:
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
except (OSError, ValueError):
    raise SystemExit(1)
if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
    raise SystemExit(1)

def interrupted(signum, _frame):
    # The first delivered terminal signal closes the handler-to-scrub gap;
    # any second/pending signal remains blocked until cleanup has finished.
    signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    raise InterruptedError("interrupted release output acquisition: %d" % signum)

try:
    for release_signal in release_signals:
        signal.signal(release_signal, interrupted)
    parent = os.dup(parent_descriptor)
    parent_metadata = os.fstat(parent)
    held_parent_identity = directory_identity(parent_metadata)
    verify_parent(parent, held_parent_identity)
    # Hostile acquisition fixtures can plant only a final-name tripwire inside
    # the already-held release parent. They cannot write through the target,
    # delete a name, or make an otherwise failing acquisition succeed.
    if os.environ.get("SP11_RELEASE_CREATOR_FIXTURE") == "true":
        fixture_mode = os.environ.get("CAPTURE_ATTACK_MODE", "")
        fixture_victim = os.environ.get("CAPTURE_ATTACK_VICTIM", "")
        fixture_work_root = os.environ.get("CAPTURE_ATTACK_WORK_ROOT", "")
        fixture_key = (fixture_mode, name, operation)
        if fixture_key in (
            ("snapshot-symlink", "kernel-baseline.env", "copy"),
            ("retained-fifo-link", "docker-build-args.txt", "copy"),
        ):
            if not os.path.isabs(fixture_victim) or "\0" in fixture_victim:
                raise OSError("invalid exclusive-create fixture victim")
            if fixture_mode == "snapshot-symlink":
                if not (
                    parent_path.startswith("/tmp/sp11-kernel-baseline.")
                    or parent_path.startswith("/private/tmp/sp11-kernel-baseline.")
                ):
                    raise OSError("invalid snapshot fixture parent")
            elif parent_path != fixture_work_root:
                raise OSError("invalid retained-evidence fixture parent")
            os.symlink(fixture_victim, name, dir_fd=parent)
        elif fixture_key == ("private-args-fifo", "docker-build-args.txt", "stdin"):
            if not (
                parent_path.startswith("/tmp/sp11-kernel-baseline.")
                or parent_path.startswith("/private/tmp/sp11-kernel-baseline.")
            ):
                raise OSError("invalid FIFO fixture parent")
            if os.mkfifo in os.supports_dir_fd:
                os.mkfifo(name, 0o600, dir_fd=parent)
            elif sys.platform == "darwin":
                # Fixed Darwin Python 3.9 lacks mkfifo(dir_fd=...). Keep the
                # fixture on the already-held parent authority by making that
                # descriptor as the temporary helper cwd; no pathname parent
                # is reopened and the cwd dies with this helper process.
                saved_cwd = os.open(
                    ".", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                )
                try:
                    os.fchdir(parent)
                    os.mkfifo(name, 0o600)
                finally:
                    os.fchdir(saved_cwd)
                    os.close(saved_cwd)
            else:
                raise OSError("exclusive FIFO fixture requires mkfifoat")
            planted = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISFIFO(planted.st_mode):
                raise OSError("exclusive FIFO fixture did not plant a FIFO")
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    try:
        output = os.open(name, output_flags, 0o600, dir_fd=parent)
        created = True
    finally:
        # A pending signal can only raise after the created descriptor has
        # been registered for exact-inode scrub.
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    output_initial = os.fstat(output)
    if (
        not stat.S_ISREG(output_initial.st_mode)
        or stat.S_IMODE(output_initial.st_mode) != 0o600
        or output_initial.st_size != 0
        or output_initial.st_nlink != 1
    ):
        raise OSError("unsafe exclusive release output")

    if operation == "copy":
        if len(arguments) != 1:
            raise OSError("invalid release copy arguments")
        source_path = arguments[0]
        source = os.open(
            source_path,
            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        source_before = os.fstat(source)
        source_mapped = os.lstat(source_path)
        if (
            not stat.S_ISREG(source_before.st_mode)
            or stat.S_ISLNK(source_mapped.st_mode)
            or source_before.st_size <= 0
            or source_before.st_size > maximum
            or source_before.st_nlink != 1
            or (source_before.st_dev, source_before.st_ino)
            != (source_mapped.st_dev, source_mapped.st_ino)
        ):
            raise OSError("unsafe release copy source")
        remaining = source_before.st_size
        while remaining:
            chunk = os.read(source, min(65536, remaining))
            if not chunk:
                raise OSError("truncated release copy source")
            write_all(output, chunk)
            remaining -= len(chunk)
        if os.read(source, 1):
            raise OSError("release copy source grew")
        source_after = os.fstat(source)
        source_remapped = os.lstat(source_path)
        if (
            stable(source_before) != stable(source_after)
            or (source_after.st_dev, source_after.st_ino)
            != (source_remapped.st_dev, source_remapped.st_ino)
        ):
            raise OSError("release copy source changed")
    elif operation == "stdin":
        if arguments:
            raise OSError("invalid release stdin arguments")
        total = 0
        while True:
            chunk = os.read(0, min(65536, maximum - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise OSError("release stdin exceeded its limit")
            write_all(output, chunk)
    else:
        if (
            not arguments
            or len(arguments) > 32
            or not os.path.isabs(arguments[0])
            or any(not argument or "\0" in argument for argument in arguments)
        ):
            raise OSError("invalid release command")
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        try:
            if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
                raise OSError("release command child-wait authority changed")
            def restore_child_signal_mask():
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

            producer = subprocess.Popen(
                arguments,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                close_fds=True,
                start_new_session=True,
                preexec_fn=restore_child_signal_mask,
            )
        finally:
            # producer is registered while release signals are still blocked;
            # a pending signal can only raise after there is a child to reap.
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if producer.stdout is None or producer.stderr is None:
            raise OSError("release command pipes are unavailable")
        fixture_deadline = (
            os.environ.get("SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT") == "true"
        )
        total_timeout = 2.0 if fixture_deadline else 120.0
        inactivity_timeout = 0.5 if fixture_deadline else 30.0
        stderr_maximum = 1024 * 1024
        started = time.monotonic()
        deadline = started + total_timeout
        last_progress = started
        total = 0
        # Docker may emit legitimate warnings on stderr even when the exact
        # requested stdout is valid. Drain and bound those non-authoritative
        # diagnostics, but discard them; exit status and sealed stdout bytes
        # remain the command result authority.
        diagnostics_total = 0
        selector = selectors.DefaultSelector()
        try:
            for stream, stream_name in (
                (producer.stdout, "stdout"),
                (producer.stderr, "stderr"),
            ):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream.fileno(), selectors.EVENT_READ, stream_name)
            while selector.get_map():
                now = time.monotonic()
                remaining_total = deadline - now
                remaining_progress = inactivity_timeout - (now - last_progress)
                if remaining_total <= 0 or remaining_progress <= 0:
                    raise TimeoutError("release command exceeded its deadline")
                events = selector.select(min(1.0, remaining_total, remaining_progress))
                if not events:
                    continue
                for key, _mask in events:
                    try:
                        chunk = os.read(key.fd, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fd)
                        continue
                    last_progress = time.monotonic()
                    if key.data == "stdout":
                        total += len(chunk)
                        if total > maximum:
                            raise OSError("release command output exceeded its limit")
                        write_all(output, chunk)
                    else:
                        diagnostics_total += len(chunk)
                        if diagnostics_total > stderr_maximum:
                            raise OSError("release command diagnostics exceeded their limit")
        finally:
            selector.close()
        remaining = min(
            deadline - time.monotonic(),
            inactivity_timeout - (time.monotonic() - last_progress),
        )
        if remaining <= 0:
            raise TimeoutError("release command did not exit before its deadline")
        wait_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        try:
            returncode = producer.wait(timeout=remaining)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, wait_mask)
        producer.stdout.close()
        producer.stderr.close()
        producer = None
        if returncode != 0:
            raise OSError("release producer failed")

    os.fsync(output)
    before_hash = os.fstat(output)
    if (
        not stat.S_ISREG(before_hash.st_mode)
        or stat.S_IMODE(before_hash.st_mode) != 0o600
        or before_hash.st_size <= 0
        or before_hash.st_size > maximum
        or before_hash.st_nlink != 1
    ):
        raise OSError("unsafe completed release output")
    digest = hashlib.sha256()
    offset = 0
    while offset < before_hash.st_size:
        chunk = os.pread(output, min(65536, before_hash.st_size - offset), offset)
        if not chunk:
            raise OSError("truncated completed release output")
        digest.update(chunk)
        offset += len(chunk)
    if os.pread(output, 1, before_hash.st_size):
        raise OSError("completed release output grew")
    after_hash = os.fstat(output)
    mapped_output = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if (
        stable(before_hash) != stable(after_hash)
        or not stat.S_ISREG(mapped_output.st_mode)
        or (after_hash.st_dev, after_hash.st_ino)
        != (mapped_output.st_dev, mapped_output.st_ino)
    ):
        raise OSError("completed release output mapping changed")
    verify_parent(parent, held_parent_identity)
    try:
        os.fsync(parent)
    except OSError:
        if sys.platform != "darwin":
            raise
    # The durable, verified bytes are now committed. Block terminal signals
    # across the entire first-close transition, discard any pending handled
    # signal, and close every exact descriptor before reporting success. A
    # signal delivered before this boundary still reaches the outer scrub.
    signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    if (
        os.environ.get("SP11_RELEASE_EXCLUSIVE_CLOSE_SIGNAL_FIXTURE") == "true"
        and os.environ.get("SP11_RELEASE_EXCLUSIVE_CLOSE_SIGNAL_TARGET") == name
    ):
        os.kill(os.getpid(), signal.SIGTERM)
        os.kill(os.getpid(), signal.SIGHUP)
    for release_signal in release_signals:
        signal.signal(release_signal, signal.SIG_IGN)
    if source >= 0:
        try:
            os.close(source)
        except BaseException:
            pass
        source = -1
    if output >= 0:
        try:
            os.close(output)
        except BaseException:
            pass
        output = -1
    if parent >= 0:
        try:
            os.close(parent)
        except BaseException:
            pass
        parent = -1
except BaseException:
    # A second/pending terminal signal must not interrupt producer reaping or
    # exact-inode scrub. Keep the release signals blocked until this helper
    # exits, and discard any further instances by changing their disposition.
    try:
        signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        for release_signal in release_signals:
            signal.signal(release_signal, signal.SIG_IGN)
    except BaseException:
        pass
    if producer is not None:
        for stream in (producer.stdout, producer.stderr):
            try:
                if stream is not None:
                    stream.close()
            except BaseException:
                pass
        if producer.poll() is None:
            try:
                os.killpg(producer.pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
            try:
                producer.wait(timeout=5)
            except BaseException:
                try:
                    os.killpg(producer.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                try:
                    producer.wait()
                except BaseException:
                    pass
    if created and output >= 0:
        try:
            os.ftruncate(output, 0)
            os.fsync(output)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if source >= 0:
        try:
            os.close(source)
        except BaseException:
            pass
    if output >= 0:
        try:
            os.close(output)
        except BaseException:
            pass
    if parent >= 0:
        try:
            os.close(parent)
        except BaseException:
            pass
' "$parent" "$parent_identity" "$parent_fd" "$name" "$maximum" "$operation" "$@"
}

run_release_command_bounded() {
  local maximum="$1"
  shift

  [ "$RELEASE_BUILD" = "true" ] || return 1
  "$RELEASE_PYTHON_BIN" -I -c '
import os
import selectors
import signal
import subprocess
import sys
import time

maximum = int(sys.argv[1], 10)
arguments = sys.argv[2:]
if (
    maximum <= 0
    or maximum > 1024 * 1024
    or not arguments
    or len(arguments) > 32
    or not os.path.isabs(arguments[0])
    or any(not argument or "\0" in argument for argument in arguments)
):
    raise SystemExit(1)

producer = None
release_signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}

try:
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
except (OSError, ValueError):
    raise SystemExit(1)
if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
    raise SystemExit(1)

def interrupted(signum, _frame):
    signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    raise InterruptedError("interrupted bounded release command: %d" % signum)

def stop_and_reap():
    global producer
    if producer is None:
        return
    for stream in (producer.stdout, producer.stderr):
        try:
            if stream is not None:
                stream.close()
        except BaseException:
            pass
    if producer.poll() is None:
        try:
            os.killpg(producer.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        try:
            producer.wait(timeout=5)
        except BaseException:
            try:
                os.killpg(producer.pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
            try:
                producer.wait()
            except BaseException:
                pass
    else:
        try:
            producer.wait()
        except BaseException:
            pass
    producer = None

try:
    for release_signal in release_signals:
        signal.signal(release_signal, interrupted)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    try:
        if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
            raise OSError("bounded release command child-wait authority changed")
        def restore_child_signal_mask():
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

        producer = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
            preexec_fn=restore_child_signal_mask,
        )
    finally:
        # The child is registered while terminal signals are blocked. A
        # pending signal cannot run cleanup until its exact process group is
        # available to stop and reap.
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    if producer.stdout is None or producer.stderr is None:
        raise OSError("bounded release command pipes are unavailable")

    fixture_deadline = (
        os.environ.get("SP11_RELEASE_SUPERVISOR_FIXTURE_TIMEOUT") == "true"
    )
    total_timeout = 2.0 if fixture_deadline else 120.0
    inactivity_timeout = 0.5 if fixture_deadline else 30.0
    stderr_maximum = 1024 * 1024
    started = time.monotonic()
    deadline = started + total_timeout
    last_progress = started
    output = bytearray()
    # Successful Docker warnings are non-authoritative. They are drained and
    # discarded under an independent byte bound; only exit status and the
    # caller-checked stdout bytes authorize the result.
    diagnostics_total = 0
    selector = selectors.DefaultSelector()
    try:
        for stream, stream_name in (
            (producer.stdout, "stdout"),
            (producer.stderr, "stderr"),
        ):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream.fileno(), selectors.EVENT_READ, stream_name)
        while selector.get_map():
            now = time.monotonic()
            remaining_total = deadline - now
            remaining_progress = inactivity_timeout - (now - last_progress)
            if remaining_total <= 0 or remaining_progress <= 0:
                raise TimeoutError("bounded release command exceeded its deadline")
            events = selector.select(min(1.0, remaining_total, remaining_progress))
            if not events:
                continue
            for key, _mask in events:
                try:
                    chunk = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                last_progress = time.monotonic()
                if key.data == "stdout":
                    if len(output) + len(chunk) > maximum:
                        raise OSError("bounded release command output exceeded its limit")
                    output.extend(chunk)
                else:
                    diagnostics_total += len(chunk)
                    if diagnostics_total > stderr_maximum:
                        raise OSError(
                            "bounded release command diagnostics exceeded their limit"
                        )
    finally:
        selector.close()

    remaining = min(
        deadline - time.monotonic(),
        inactivity_timeout - (time.monotonic() - last_progress),
    )
    if remaining <= 0:
        raise TimeoutError("bounded release command did not exit before its deadline")
    wait_mask = signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
    try:
        returncode = producer.wait(timeout=remaining)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, wait_mask)
    producer.stdout.close()
    producer.stderr.close()
    producer = None
    if returncode != 0 or b"\0" in output:
        raise OSError("bounded release command failed")

    view = memoryview(output)
    while view:
        written = os.write(1, view)
        if written <= 0:
            raise OSError("short bounded release command output write")
        view = view[written:]
except BaseException:
    try:
        signal.pthread_sigmask(signal.SIG_BLOCK, release_signals)
        for release_signal in release_signals:
            signal.signal(release_signal, signal.SIG_IGN)
    except BaseException:
        pass
    stop_and_reap()
    raise SystemExit(1)
finally:
    stop_and_reap()
' "$maximum" "$@"
}

verify_baseline_control_membership() {
  local phase="$1" path name count=0
  local seen_baseline=false seen_validator=false seen_args=false
  local seen_entrypoint=false seen_oci=false

  while IFS= read -r -d '' path; do
    count=$((count + 1))
    name="${path##*/}"
    case "$name" in
      kernel-baseline.env)
        [ "$seen_baseline" = false ] || return 1
        seen_baseline=true
        ;;
      validate-sp11-kernel-baseline.sh)
        [ "$seen_validator" = false ] || return 1
        seen_validator=true
        ;;
      docker-build-args.txt)
        [ "$phase" = final ] && [ "$seen_args" = false ] || return 1
        seen_args=true
        ;;
      docker-build-inside.sh)
        [ "$phase" = final ] && [ "$seen_entrypoint" = false ] || return 1
        seen_entrypoint=true
        ;;
      sp11-oci-index.json)
        [ "$phase" = final ] && [ -n "$RELEASE_OCI_INDEX_STATE" ] &&
          [ "$seen_oci" = false ] || return 1
        seen_oci=true
        ;;
      *) return 1 ;;
    esac
  done < <(find "$BASELINE_CONTROL_DIR" -mindepth 1 -maxdepth 1 -print0)
  [ "$seen_baseline" = true ] && [ "$seen_validator" = true ] || return 1
  if [ "$phase" = initial ]; then
    [ "$count" -eq 2 ]
  elif [ -n "$RELEASE_OCI_INDEX_STATE" ]; then
    [ "$count" -eq 5 ] && [ "$seen_args" = true ] &&
      [ "$seen_entrypoint" = true ] && [ "$seen_oci" = true ]
  else
    [ "$count" -eq 4 ] && [ "$seen_args" = true ] &&
      [ "$seen_entrypoint" = true ] && [ "$seen_oci" = false ]
  fi
}

verify_kernel_baseline_state() {
  local current

  [ "$RELEASE_BUILD" = "true" ] || return 0
  current="$(baseline_control_file_state "$KERNEL_BASELINE")" || {
    echo "Committed kernel baseline snapshot is missing, unsafe, or unstable." >&2
    return 1
  }
  if [ "$current" != "$KERNEL_BASELINE_STATE" ]; then
    echo "Committed kernel baseline snapshot changed after materialization." >&2
    return 1
  fi
}

verify_kernel_baseline_control_state() {
  local current

  verify_kernel_baseline_state || return 1
  verify_held_release_file \
    "$KERNEL_BASELINE_FD" "$KERNEL_BASELINE" "$KERNEL_BASELINE_SHA256" 600 || {
      echo "Held committed kernel baseline changed or lost its name binding." >&2
      return 1
    }
  current="$(baseline_control_file_state "$KERNEL_BASELINE_VALIDATOR")" || {
    echo "Committed kernel baseline validator snapshot is missing, unsafe, or unstable." >&2
    return 1
  }
  if [ "$current" != "$KERNEL_BASELINE_VALIDATOR_STATE" ]; then
    echo "Committed kernel baseline validator snapshot changed after materialization." >&2
    return 1
  fi
  verify_held_release_file \
    "$KERNEL_BASELINE_VALIDATOR_FD" "$KERNEL_BASELINE_VALIDATOR" \
    "${KERNEL_BASELINE_VALIDATOR_STATE##*:}" 600 || {
      echo "Held committed kernel baseline validator changed or lost its name binding." >&2
      return 1
    }
}

verify_initial_baseline_control_state() {
  local current_directory_state

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY" || {
      echo "Private committed-baseline control directory handle changed." >&2
      return 1
    }
  current_directory_state="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" || {
    echo "Private committed-baseline control directory is missing, unsafe, or unstable." >&2
    return 1
  }
  if [ -z "$BASELINE_CONTROL_INITIAL_STATE" ] ||
     [ "$current_directory_state" != "$BASELINE_CONTROL_INITIAL_STATE" ] ||
     ! verify_baseline_control_membership initial; then
    echo "Private committed-baseline control directory changed before finalization." >&2
    return 1
  fi
  verify_kernel_baseline_control_state || return 1
  current_directory_state="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" || return 1
  if [ "$current_directory_state" != "$BASELINE_CONTROL_INITIAL_STATE" ] ||
     ! verify_baseline_control_membership initial; then
    echo "Private committed-baseline control directory changed during validation." >&2
    return 1
  fi
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY"
}

refresh_initial_baseline_control_state_after_held_validation() {
  local refreshed_state

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY" || return 1
  verify_baseline_control_membership initial || return 1
  verify_kernel_baseline_control_state || return 1
  refreshed_state="$(baseline_control_directory_state \
    "$BASELINE_CONTROL_DIR")" || return 1
  verify_baseline_control_membership initial || return 1
  verify_kernel_baseline_control_state || return 1
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY" || return 1
  BASELINE_CONTROL_INITIAL_STATE="$refreshed_state"
  verify_initial_baseline_control_state
}

verify_pinned_baseline_control_cwd() {
  [ -d . ] && [ ! -L . ] &&
    [ "$(baseline_control_identity .)" = "$BASELINE_CONTROL_IDENTITY" ] &&
    [ -d "$BASELINE_CONTROL_DIR" ] && [ ! -L "$BASELINE_CONTROL_DIR" ] &&
    [ "$(baseline_control_identity "$BASELINE_CONTROL_DIR")" = \
      "$BASELINE_CONTROL_IDENTITY" ]
}

verify_release_control_state() {
  local path expected_state current_state current_directory_state

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY" || {
      echo "Private release control directory handle changed." >&2
      return 1
    }
  [ -n "$BASELINE_CONTROL_FINAL_STATE" ] || {
    echo "Private release control directory was not finalized." >&2
    return 1
  }
  current_directory_state="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" || {
    echo "Private release control directory is missing, unsafe, or unstable." >&2
    return 1
  }
  if [ "$current_directory_state" != "$BASELINE_CONTROL_FINAL_STATE" ] ||
     ! verify_baseline_control_membership final; then
    echo "Private release control directory state or membership changed." >&2
    return 1
  fi
  verify_kernel_baseline_control_state || return 1
  for path in \
    "$BASELINE_CONTROL_DIR/docker-build-args.txt" \
    "$BASELINE_CONTROL_DIR/docker-build-inside.sh" \
    "$BASELINE_CONTROL_DIR/sp11-oci-index.json"; do
    case "$path" in
      */docker-build-args.txt) expected_state="$RELEASE_BUILD_ARGS_STATE" ;;
      */docker-build-inside.sh) expected_state="$RELEASE_ENTRYPOINT_STATE" ;;
      *) expected_state="$RELEASE_OCI_INDEX_STATE" ;;
    esac
    [ -n "$expected_state" ] || continue
    current_state="$(baseline_control_file_state "$path")" || {
      echo "Private release control input is missing, unsafe, or unstable: $path" >&2
      return 1
    }
    if [ "$current_state" != "$expected_state" ]; then
      echo "Private release control input changed after materialization: $path" >&2
      return 1
    fi
  done
  current_directory_state="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" || return 1
  if [ "$current_directory_state" != "$BASELINE_CONTROL_FINAL_STATE" ] ||
     ! verify_baseline_control_membership final; then
    echo "Private release control directory changed during verification." >&2
    return 1
  fi
  verify_held_release_directory \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY"
}

cleanup_baseline_control_dir() {
  # Release control roots are bounded, private retained evidence.  Never reopen
  # their names during EXIT cleanup to remove, rename, or truncate a path that
  # may have been substituted after the last validation.
  [ -n "$BASELINE_CONTROL_DIR" ] || return 0
  return 0
}

support_snapshot_directory_state() {
  local path="$1"

  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin) stat -f '%d:%i:%z:%Fm:%Fc:%Lp:%u:%g' "$path" ;;
    *) stat -c '%d:%i:%s:%y:%z:%a:%u:%g' -- "$path" ;;
  esac
}

committed_support_git() {
  local safe_support_dir access_dir

  access_dir="${COMMITTED_SUPPORT_ACCESS_DIR:-$COMMITTED_SUPPORT_DIR}"
  safe_support_dir="$(cd "$access_dir" && pwd -P)" || return 1
  GIT_OPTIONAL_LOCKS=0 git \
    -c "safe.directory=$safe_support_dir" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -C "$access_dir" "$@"
}

capture_support_snapshot_inventory() {
  local path relative state node_identity

  SUPPORT_SNAPSHOT_PATHS=()
  SUPPORT_SNAPSHOT_TYPES=()
  SUPPORT_SNAPSHOT_STATES=()
  SUPPORT_SNAPSHOT_NODE_IDENTITIES=()
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    relative="${path#"$SUPPORT_SNAPSHOT_ROOT"/}"
    case "$relative" in
      ""|/*|*//*|../*|*/../*|*/..|*$'\n'*|*$'\r'*|*$'\t'*)
        echo "Private support snapshot contains an unsafe path." >&2
        return 1
        ;;
    esac
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      state="$(baseline_control_file_state "$path")" || return 1
      SUPPORT_SNAPSHOT_TYPES+=(file)
    elif [ -d "$path" ] && [ ! -L "$path" ]; then
      state="$(support_snapshot_directory_state "$path")" || return 1
      SUPPORT_SNAPSHOT_TYPES+=(directory)
    else
      echo "Private support snapshot contains a symlink or special node: $relative" >&2
      return 1
    fi
    SUPPORT_SNAPSHOT_PATHS+=("$relative")
    SUPPORT_SNAPSHOT_STATES+=("$state")
    node_identity="$(baseline_control_identity "$path")" || return 1
    SUPPORT_SNAPSHOT_NODE_IDENTITIES+=("$node_identity")
  done < <(find "$SUPPORT_SNAPSHOT_ROOT" -mindepth 1 -print0)
  [ "${#SUPPORT_SNAPSHOT_PATHS[@]}" -gt 0 ] || return 1
}

verify_support_snapshot_inventory() {
  local path relative state type node_identity index=0

  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    if [ "$index" -ge "${#SUPPORT_SNAPSHOT_PATHS[@]}" ]; then
      echo "Private support snapshot gained an unexpected path." >&2
      return 1
    fi
    relative="${path#"$SUPPORT_SNAPSHOT_ROOT"/}"
    [ "$relative" = "${SUPPORT_SNAPSHOT_PATHS[$index]}" ] || {
      echo "Private support snapshot path inventory changed." >&2
      return 1
    }
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      type="file"
      state="$(baseline_control_file_state "$path")" || return 1
    elif [ -d "$path" ] && [ ! -L "$path" ]; then
      type="directory"
      state="$(support_snapshot_directory_state "$path")" || return 1
    else
      echo "Private support snapshot path became a symlink or special node: $relative" >&2
      return 1
    fi
    if [ "$type" != "${SUPPORT_SNAPSHOT_TYPES[$index]}" ] ||
       [ "$state" != "${SUPPORT_SNAPSHOT_STATES[$index]}" ]; then
      echo "Private support snapshot node changed: $relative" >&2
      return 1
    fi
    node_identity="$(baseline_control_identity "$path")" || return 1
    [ "$node_identity" = "${SUPPORT_SNAPSHOT_NODE_IDENTITIES[$index]}" ] || {
      echo "Private support snapshot node identity changed: $relative" >&2
      return 1
    }
    index=$((index + 1))
  done < <(find "$SUPPORT_SNAPSHOT_ROOT" -mindepth 1 -print0)
  if [ "$index" -ne "${#SUPPORT_SNAPSHOT_PATHS[@]}" ]; then
    echo "Private support snapshot lost a path." >&2
    return 1
  fi
}

verify_release_support_checkout() {
  local current_root_identity current_root_state head tree status

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_held_release_directory \
    "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
    "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" || {
      echo "Private committed support snapshot root handle changed." >&2
      return 1
    }
  if [ ! -d "$SUPPORT_SNAPSHOT_ROOT" ] || [ -L "$SUPPORT_SNAPSHOT_ROOT" ] ||
     ! current_root_identity="$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT")" ||
     [ "$current_root_identity" != "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ]; then
    echo "Private committed support snapshot root changed." >&2
    return 1
  fi
  current_root_state="$(support_snapshot_directory_state "$SUPPORT_SNAPSHOT_ROOT")" || return 1
  if [ "$current_root_state" != "$SUPPORT_SNAPSHOT_ROOT_STATE" ]; then
    echo "Private committed support snapshot root state changed." >&2
    return 1
  fi
  verify_support_snapshot_inventory || return 1
  head="$(committed_support_git rev-parse --verify 'HEAD^{commit}')" || return 1
  tree="$(committed_support_git rev-parse --verify 'HEAD^{tree}')" || return 1
  status="$(committed_support_git status --porcelain=v1 --untracked-files=all --ignored)" || return 1
  if [ "$head" != "$SUPPORT_HEAD_START" ] || [ "$tree" != "$SUPPORT_SNAPSHOT_TREE" ] ||
     [ -n "$status" ] ||
     ! committed_support_git diff-files --quiet --ignore-submodules=none ||
     ! committed_support_git diff-index --quiet --cached "$SUPPORT_HEAD_START" --; then
    echo "Private committed support checkout changed." >&2
    return 1
  fi
  verify_support_snapshot_inventory || return 1
  current_root_state="$(support_snapshot_directory_state "$SUPPORT_SNAPSHOT_ROOT")" || return 1
  if [ "$current_root_state" != "$SUPPORT_SNAPSHOT_ROOT_STATE" ]; then
    echo "Private committed support snapshot root changed during verification." >&2
    return 1
  fi
  verify_held_release_directory \
    "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
    "$SUPPORT_SNAPSHOT_ROOT_IDENTITY"
}

release_support_script_binding_record() {
  local relative_path="$1" inventory_path index state entry metadata listed_path
  local git_mode object_type object_id remainder expected_mode state_tail file_size

  inventory_path="support/$relative_path"
  index=0
  while [ "$index" -lt "${#SUPPORT_SNAPSHOT_PATHS[@]}" ]; do
    if [ "${SUPPORT_SNAPSHOT_PATHS[$index]}" = "$inventory_path" ]; then
      [ "${SUPPORT_SNAPSHOT_TYPES[$index]}" = file ] || return 1
      state="${SUPPORT_SNAPSHOT_STATES[$index]}"
      [[ "${state##*:}" =~ ^[0-9a-f]{64}$ ]] || return 1
      entry="$(committed_support_git ls-tree "$SUPPORT_HEAD_START" -- "$relative_path")" ||
        return 1
      IFS=$'\t' read -r metadata listed_path remainder <<< "$entry"
      read -r git_mode object_type object_id remainder <<< "$metadata"
      case "$git_mode" in
        100644) expected_mode=644 ;;
        100755) expected_mode=755 ;;
        *) return 1 ;;
      esac
      [ -z "$remainder" ] && [ "$listed_path" = "$relative_path" ] &&
        [ "$object_type" = blob ] &&
        [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
      state_tail="${state#*:}"
      state_tail="${state_tail#*:}"
      file_size="${state_tail%%:*}"
      [[ "$file_size" =~ ^[1-9][0-9]*$ ]] || return 1
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "${SUPPORT_SNAPSHOT_NODE_IDENTITIES[$index]}" \
        "${state##*:}" "$object_id" "$expected_mode" "$file_size"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

bind_release_support_python_scripts() {
  local validator_record helper_record build_inputs_record manifest_record remainder
  local _release_build_inputs_identity _release_manifest_identity
  local binding_value binding_digest binding_object binding_size

  [ "$RELEASE_BUILD" = "true" ] || return 0
  verify_release_python_authority || return 1
  verify_release_support_checkout || return 1
  validator_record="$(release_support_script_binding_record \
    scripts/validate-sp11-oci-index.py)" || {
      echo "Could not bind the committed OCI-index validator blob." >&2
      return 1
    }
  IFS=$'\t' read -r \
    RELEASE_OCI_VALIDATOR_IDENTITY RELEASE_OCI_VALIDATOR_SHA256 \
    RELEASE_OCI_VALIDATOR_OBJECT_ID RELEASE_OCI_VALIDATOR_MODE \
    RELEASE_OCI_VALIDATOR_SIZE remainder \
    <<< "$validator_record"
  [ -z "$remainder" ] || return 1
  helper_record="$(release_support_script_binding_record \
    scripts/sp11-kernel-release-state.py)" || {
      echo "Could not bind the committed release-state helper blob." >&2
      return 1
    }
  IFS=$'\t' read -r \
    RELEASE_STATE_HELPER_IDENTITY RELEASE_STATE_HELPER_SHA256 \
    RELEASE_STATE_HELPER_OBJECT_ID RELEASE_STATE_HELPER_MODE \
    RELEASE_STATE_HELPER_SIZE remainder \
    <<< "$helper_record"
  [ -z "$remainder" ] || return 1
  build_inputs_record="$(release_support_script_binding_record \
    scripts/sp11-kernel-build-inputs.py)" || {
      echo "Could not bind the committed build-inputs helper blob." >&2
      return 1
    }
  IFS=$'\t' read -r \
    _release_build_inputs_identity RELEASE_BUILD_INPUTS_HELPER_SHA256 \
    RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID RELEASE_BUILD_INPUTS_HELPER_MODE \
    RELEASE_BUILD_INPUTS_HELPER_SIZE remainder <<< "$build_inputs_record"
  [ -z "$remainder" ] || return 1
  manifest_record="$(release_support_script_binding_record \
    scripts/validate-sp11-image-release-manifests.py)" || {
      echo "Could not bind the committed manifest-validator blob." >&2
      return 1
    }
  IFS=$'\t' read -r \
    _release_manifest_identity RELEASE_MANIFEST_VALIDATOR_SHA256 \
    RELEASE_MANIFEST_VALIDATOR_OBJECT_ID RELEASE_MANIFEST_VALIDATOR_MODE \
    RELEASE_MANIFEST_VALIDATOR_SIZE remainder <<< "$manifest_record"
  [ -z "$remainder" ] || return 1
  for binding_value in \
    "$RELEASE_OCI_VALIDATOR_IDENTITY" "$RELEASE_STATE_HELPER_IDENTITY"; do
    [[ "$binding_value" =~ ^[0-9]+:[1-9][0-9]*:[0-7]+:[0-9]+:[0-9]+$ ]] ||
      return 1
  done
  for binding_digest in \
    "$RELEASE_OCI_VALIDATOR_SHA256" "$RELEASE_STATE_HELPER_SHA256" \
    "$RELEASE_BUILD_INPUTS_HELPER_SHA256" \
    "$RELEASE_MANIFEST_VALIDATOR_SHA256"; do
    [[ "$binding_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  done
  for binding_object in \
    "$RELEASE_OCI_VALIDATOR_OBJECT_ID" "$RELEASE_STATE_HELPER_OBJECT_ID" \
    "$RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID" \
    "$RELEASE_MANIFEST_VALIDATOR_OBJECT_ID"; do
    [[ "$binding_object" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  done
  for binding_size in \
    "$RELEASE_OCI_VALIDATOR_SIZE" "$RELEASE_STATE_HELPER_SIZE" \
    "$RELEASE_BUILD_INPUTS_HELPER_SIZE" "$RELEASE_MANIFEST_VALIDATOR_SIZE"; do
    [[ "$binding_size" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  if [[ "$SUPPORT_HEAD_START" =~ ^[0-9a-f]{40}$ ]]; then
    RELEASE_GIT_OBJECT_FORMAT=sha1
  elif [[ "$SUPPORT_HEAD_START" =~ ^[0-9a-f]{64}$ ]]; then
    RELEASE_GIT_OBJECT_FORMAT=sha256
  else
    return 1
  fi
  [ "$RELEASE_BUILD_INPUTS_HELPER_MODE" = 755 ] &&
    [ "$RELEASE_MANIFEST_VALIDATOR_MODE" = 644 ] || return 1
  verify_release_support_checkout
}

bound_release_support_python() {
  local terminal="$1" relative_path="$2" maximum="$3"
  local expected_identity="$4" expected_sha256="$5" expected_object_id="$6"
  local expected_mode="$7" launcher
  shift 7

  launcher='
import hashlib
import os
import re
import stat
import sys

snapshot_descriptor = int(sys.argv[1], 10)
snapshot_path = sys.argv[2]
expected_snapshot_identity = sys.argv[3]
relative_path = sys.argv[4]
maximum = int(sys.argv[5], 10)
expected_identity = sys.argv[6]
expected_sha256 = sys.argv[7]
expected_object_id = sys.argv[8]
expected_mode = int(sys.argv[9], 8)
program_arguments = sys.argv[10:]
allowed = {
    "scripts/validate-sp11-oci-index.py",
    "scripts/sp11-kernel-release-state.py",
}
fixture_enabled = (
    os.environ.get("SP11_RELEASE_SCRIPT_BINDING_FIXTURE") == "true"
)
fixture_action = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_ACTION", "")
fixture_target = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_TARGET", "")

def identity(metadata):
    return ":".join(str(value) for value in (
        metadata.st_dev,
        metadata.st_ino,
        format(stat.S_IMODE(metadata.st_mode), "o"),
        metadata.st_uid,
        metadata.st_gid,
    ))

def stable(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
    )

def write_all(descriptor, payload):
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short fixture write")
        view = view[written:]

root = -1
support = -1
scripts = -1
program = -1
try:
    if (
        sys.flags.isolated != 1
        or relative_path not in allowed
        or maximum <= 0
        or maximum > 4 * 1024 * 1024
        or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
        or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", expected_object_id)
        or expected_mode not in (0o644, 0o755)
        or (fixture_action or fixture_target) and not fixture_enabled
    ):
        raise OSError("invalid committed program binding")
    root = os.dup(snapshot_descriptor)
    root_before = os.fstat(root)
    root_mapped = os.lstat(snapshot_path)
    if (
        not stat.S_ISDIR(root_before.st_mode)
        or not stat.S_ISDIR(root_mapped.st_mode)
        or identity(root_before) != expected_snapshot_identity
        or identity(root_mapped) != expected_snapshot_identity
        or (root_before.st_dev, root_before.st_ino)
        != (root_mapped.st_dev, root_mapped.st_ino)
    ):
        raise OSError("committed support root changed")
    directory_flags = (
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    )
    support = os.open("support", directory_flags, dir_fd=root)
    support_before = os.fstat(support)
    support_mapped = os.stat("support", dir_fd=root, follow_symlinks=False)
    if (
        not stat.S_ISDIR(support_before.st_mode)
        or not stat.S_ISDIR(support_mapped.st_mode)
        or (support_before.st_dev, support_before.st_ino)
        != (support_mapped.st_dev, support_mapped.st_ino)
    ):
        raise OSError("committed support checkout changed")
    scripts = os.open("scripts", directory_flags, dir_fd=support)
    scripts_before = os.fstat(scripts)
    scripts_mapped = os.stat("scripts", dir_fd=support, follow_symlinks=False)
    if (
        not stat.S_ISDIR(scripts_before.st_mode)
        or not stat.S_ISDIR(scripts_mapped.st_mode)
        or (scripts_before.st_dev, scripts_before.st_ino)
        != (scripts_mapped.st_dev, scripts_mapped.st_ino)
    ):
        raise OSError("committed support scripts directory changed")
    filename = relative_path.removeprefix("scripts/")
    program = os.open(
        filename,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        dir_fd=scripts,
    )
    before = os.fstat(program)
    mapped = os.stat(filename, dir_fd=scripts, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or not stat.S_ISREG(mapped.st_mode)
        or identity(before) != expected_identity
        or identity(mapped) != expected_identity
        or stat.S_IMODE(before.st_mode) != expected_mode
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum
        or (before.st_dev, before.st_ino) != (mapped.st_dev, mapped.st_ino)
    ):
        raise OSError("committed support program identity changed")
    payload = bytearray()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(program, min(65536, before.st_size - offset), offset)
        if not chunk:
            raise OSError("committed support program was truncated")
        payload.extend(chunk)
        offset += len(chunk)
    if os.pread(program, 1, before.st_size):
        raise OSError("committed support program grew")

    if (
        fixture_enabled
        and fixture_action == "mutate-restore"
        and fixture_target == relative_path
    ):
        mutation = os.open(
            filename,
            os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=scripts,
        )
        try:
            original = os.pread(mutation, 1, 0)
            if len(original) != 1:
                raise OSError("fixture could not read held program")
            changed = b"X" if original != b"X" else b"Y"
            os.pwrite(mutation, changed, 0)
            os.fsync(mutation)
            os.pwrite(mutation, original, 0)
            os.fsync(mutation)
        finally:
            os.close(mutation)

    after = os.fstat(program)
    remapped = os.stat(filename, dir_fd=scripts, follow_symlinks=False)
    support_after = os.fstat(support)
    scripts_after = os.fstat(scripts)
    root_after = os.fstat(root)
    root_remapped = os.lstat(snapshot_path)
    support_remapped = os.stat("support", dir_fd=root, follow_symlinks=False)
    scripts_remapped = os.stat("scripts", dir_fd=support, follow_symlinks=False)
    if (
        stable(before) != stable(after)
        or stable(root_before) != stable(root_after)
        or stable(support_before) != stable(support_after)
        or stable(scripts_before) != stable(scripts_after)
        or (root_after.st_dev, root_after.st_ino)
        != (root_remapped.st_dev, root_remapped.st_ino)
        or (support_after.st_dev, support_after.st_ino)
        != (support_remapped.st_dev, support_remapped.st_ino)
        or (scripts_after.st_dev, scripts_after.st_ino)
        != (scripts_remapped.st_dev, scripts_remapped.st_ino)
        or (after.st_dev, after.st_ino) != (remapped.st_dev, remapped.st_ino)
    ):
        raise OSError("committed support program changed while sealing")
    payload_bytes = bytes(payload)
    if hashlib.sha256(payload_bytes).hexdigest() != expected_sha256:
        raise OSError("committed support program SHA-256 changed")
    blob_header = b"blob " + str(len(payload_bytes)).encode("ascii") + b"\0"
    object_hasher = hashlib.sha1() if len(expected_object_id) == 40 else hashlib.sha256()
    object_hasher.update(blob_header)
    object_hasher.update(payload_bytes)
    if object_hasher.hexdigest() != expected_object_id:
        raise OSError("committed support program Git object changed")
    synthetic_name = relative_path
    code = compile(payload_bytes, synthetic_name, "exec", dont_inherit=True)

    if fixture_enabled and fixture_action == "swap-after-seal" and fixture_target == relative_path:
        backup = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_BACKUP", "")
        hostile_marker = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_HOSTILE_MARKER", "")
        restore_marker = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_RESTORE_MARKER", "")
        displaced = os.environ.get("SP11_RELEASE_SCRIPT_BINDING_DISPLACED", "")
        if (
            not re.fullmatch(r"\.sp11-fixture-[0-9a-z-]{1,64}", backup)
            or not hostile_marker
            or not restore_marker
            or not displaced
        ):
            raise OSError("invalid script-binding fixture")
        os.rename(filename, backup, src_dir_fd=scripts, dst_dir_fd=scripts)
        hostile = (
            "import os\n"
            + "descriptor = os.open("
            + repr(hostile_marker)
            + ", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)\n"
            + "os.close(descriptor)\n"
            + "raise SystemExit(97)\n"
        ).encode("utf-8")
        hostile_descriptor = os.open(
            filename,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            expected_mode,
            dir_fd=scripts,
        )
        try:
            write_all(hostile_descriptor, hostile)
            os.fsync(hostile_descriptor)
        finally:
            os.close(hostile_descriptor)
        os.environ["MOCK_SCRIPT_BINDING_RESTORE_DIR"] = os.path.join(
            snapshot_path, "support", "scripts"
        )
        os.environ["MOCK_SCRIPT_BINDING_RESTORE_NAME"] = filename
        os.environ["MOCK_SCRIPT_BINDING_RESTORE_BACKUP"] = backup
        os.environ["MOCK_SCRIPT_BINDING_RESTORE_MARKER"] = restore_marker
        os.environ["MOCK_SCRIPT_BINDING_DISPLACED"] = displaced
    elif (
        fixture_enabled
        and fixture_target == relative_path
        and fixture_action not in ("", "mutate-restore")
    ):
        raise OSError("unsupported script-binding fixture")
except BaseException:
    print("error: committed release support program binding failed", file=sys.stderr)
    raise SystemExit(1)
finally:
    for descriptor in (program, scripts, support, root):
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass

sys.argv = [synthetic_name, *program_arguments]
namespace = {
    "__name__": "__main__",
    "__file__": synthetic_name,
    "__package__": None,
    "__cached__": None,
    "__spec__": None,
}
exec(code, namespace, namespace)
'

  if [ "$terminal" = true ]; then
    exec "$RELEASE_PYTHON_BIN" -I -c "$launcher" \
      "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
      "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" "$relative_path" "$maximum" \
      "$expected_identity" "$expected_sha256" "$expected_object_id" \
      "$expected_mode" "$@"
  else
    "$RELEASE_PYTHON_BIN" -I -c "$launcher" \
      "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
      "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" "$relative_path" "$maximum" \
      "$expected_identity" "$expected_sha256" "$expected_object_id" \
      "$expected_mode" "$@"
  fi
}

run_bound_release_support_python() {
  bound_release_support_python false "$@"
}

exec_bound_release_support_python() {
  bound_release_support_python true "$@"
}

cleanup_release_support_checkout() {
  # The exact committed checkout is retained as private release evidence.  In
  # particular, EXIT cleanup never walks its pathname and removes descendants.
  [ -n "$SUPPORT_SNAPSHOT_ROOT" ] || return 0
  return 0
}

trap 'cleanup_baseline_control_dir; cleanup_release_support_checkout; cleanup_control_dir; cleanup_payload_stage; cleanup_held_release_roots' EXIT

normalize_absolute_path() {
  local input="$1" component normalized=""
  local -a components=()

  case "$input" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ "$input" = "/" ]; then
    printf '/\n'
    return 0
  fi
  IFS='/' read -r -a components <<< "${input#/}"
  for component in "${components[@]}"; do
    case "$component" in
      ""|.) continue ;;
      ..) return 1 ;;
    esac
    normalized="$normalized/$component"
  done
  printf '%s\n' "${normalized:-/}"
}

ensure_safe_work_dir() {
  local requested="$1" candidate normalized current component
  local -a components=()

  case "$requested" in
    ""|.|./)
      echo "--work-dir must name a specific directory without control characters." >&2
      return 1
      ;;
  esac
  case "$requested" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "--work-dir must name a specific directory without control characters." >&2
      return 1
      ;;
  esac
  case "/$requested/" in
    */../*)
      echo "--work-dir must not contain a '..' path component: $requested" >&2
      return 1
      ;;
  esac

  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$repo_dir/$requested" ;;
  esac
  if ! normalized="$(normalize_absolute_path "$candidate")"; then
    echo "Could not normalize --work-dir safely: $requested" >&2
    return 1
  fi

  case "$normalized" in
    "$repo_dir/build"/*) ;;
    *)
      echo "--work-dir must be a dedicated child of this repository's build/ directory: $requested" >&2
      return 1
      ;;
  esac

  current=""
  IFS='/' read -r -a components <<< "${normalized#/}"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    current="$current/$component"
    if [ -L "$current" ]; then
      echo "--work-dir must not contain symlink components: $requested" >&2
      return 1
    fi
    if [ -e "$current" ]; then
      if [ ! -d "$current" ]; then
        echo "--work-dir component is not a directory: $current" >&2
        return 1
      fi
    else
      if [ "$RELEASE_BUILD" = "true" ]; then
        echo "--release-build requires a pre-existing real --work-dir; refusing pre-pin path creation: $requested" >&2
        return 1
      fi
      if ! mkdir -m 700 "$current"; then
        echo "Could not create safe --work-dir component: $current" >&2
        return 1
      fi
      if [ -L "$current" ] || [ ! -d "$current" ]; then
        echo "Unsafe --work-dir component appeared during creation: $current" >&2
        return 1
      fi
    fi
  done

  if [ "$(cd "$normalized" && pwd -P)" != "$normalized" ]; then
    echo "--work-dir did not resolve to its exact non-symlink path: $requested" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

verify_pinned_work_root_cwd() {
  local current_identity

  [ "$RELEASE_BUILD" = "true" ] || return 0
  [ -n "$WORK_ROOT_IDENTITY" ] || {
    echo "Release work root has no captured identity." >&2
    return 1
  }
  if [ "$WORK_ROOT_FD_OPEN" = "true" ]; then
    verify_held_release_directory \
      "$WORK_ROOT_FD" "$work_abs" "$WORK_ROOT_IDENTITY" || {
        echo "Release work root changed from its held directory." >&2
        return 1
      }
  fi
  current_identity="$(baseline_control_identity .)" || return 1
  if [ "$current_identity" != "$WORK_ROOT_IDENTITY" ] ||
     [ ! -d "$work_abs" ] || [ -L "$work_abs" ] ||
     [ "$(baseline_control_identity "$work_abs")" != "$WORK_ROOT_IDENTITY" ]; then
    echo "Release work root changed from its pinned directory." >&2
    return 1
  fi
}

capture_release_work_root_identity() {
  local previous_directory identity_record identity_dev identity_ino
  local identity_mode identity_uid identity_gid identity_remainder

  [ "$RELEASE_BUILD" = "true" ] || return 0

  if ! WORK_ROOT_IDENTITY="$(
    cd "$work_abs" || exit 1
    pinned_identity="$(baseline_control_identity .)" || exit 1
    [ -d "$work_abs" ] && [ ! -L "$work_abs" ] &&
      [ "$(baseline_control_identity "$work_abs")" = "$pinned_identity" ] ||
      exit 1
    printf '%s\n' "$pinned_identity"
  )"; then
    echo "Could not capture the release work-root identity." >&2
    return 1
  fi
  previous_directory="$(pwd -P)" || return 1
  if ! cd "$work_abs" || ! verify_pinned_work_root_cwd; then
    cd "$previous_directory" || true
    echo "Could not enter the pinned release work-root directory." >&2
    return 1
  fi
  # Open `.` through the already-held cwd authority. A late FIFO substitution
  # of the pathname cannot block this open, and a late symlink cannot redirect
  # it after the identity check above.
  if ! exec 52< .; then
    cd "$previous_directory" || true
    echo "Could not hold the release work-root directory." >&2
    return 1
  fi
  WORK_ROOT_FD_OPEN="true"
  if ! cd "$previous_directory"; then
    echo "Could not restore the wrapper directory after holding the release work root." >&2
    return 1
  fi
  if ! verify_held_release_directory \
      "$WORK_ROOT_FD" "$work_abs" "$WORK_ROOT_IDENTITY"; then
    echo "Could not bind the held release work-root directory." >&2
    return 1
  fi
  if ! identity_record="$(
      held_release_directory_identity_fields "$WORK_ROOT_FD"
    )"; then
    echo "Could not capture the held release work-root import identity." >&2
    return 1
  fi
  read -r identity_dev identity_ino identity_mode identity_uid identity_gid \
    identity_remainder <<< "$identity_record"
  if [ -n "$identity_remainder" ] ||
     ! [[ "$identity_dev" =~ ^[0-9]+$ ]] ||
     ! [[ "$identity_ino" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$identity_mode" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$identity_uid" =~ ^[0-9]+$ ]] ||
     ! [[ "$identity_gid" =~ ^[0-9]+$ ]]; then
    echo "Held release work-root import identity is malformed." >&2
    return 1
  fi
  if [ "$identity_mode" -ne 448 ] || [ "$identity_uid" -ne "$EUID" ]; then
    echo "Release work root must be mode 0700 and owned by the invoking uid: $work_abs" >&2
    return 1
  fi
  WORK_ROOT_IMPORT_IDENTITY=(
    "$identity_dev" "$identity_ino" "$identity_mode" "$identity_uid" "$identity_gid"
  )
  (
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
  )
}

verify_release_work_root_binding() {
  [ "$RELEASE_BUILD" = "true" ] || return 0
  (
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
    verify_release_work_dirs_cwd
  )
}

verify_release_work_dirs_cwd() {
  local index name current_identity held_fd

  index=0
  while [ "$index" -lt "${#RELEASE_WORK_DIR_NAMES[@]}" ]; do
    name="${RELEASE_WORK_DIR_NAMES[$index]}"
    case "$name" in
      artifacts) ;;
      *)
        echo "Release work-directory identity set contains an unsafe name." >&2
        return 1
        ;;
    esac
    if [ ! -d "./$name" ] || [ -L "./$name" ] ||
       ! current_identity="$(baseline_control_identity "./$name")" ||
       [ "$current_identity" != "${RELEASE_WORK_DIR_IDENTITIES[$index]}" ]; then
      echo "Release work directory changed from its pinned identity: $work_abs/$name" >&2
      return 1
    fi
    held_fd="$RELEASE_ARTIFACTS_FD"
    verify_held_release_directory \
      "$held_fd" "$work_abs/$name" "${RELEASE_WORK_DIR_IDENTITIES[$index]}" || {
        echo "Release work directory lost its held identity: $work_abs/$name" >&2
        return 1
      }
    index=$((index + 1))
  done
}

verify_release_work_root_prebuild_membership() {
  local unexpected_entry

  [ "$RELEASE_BUILD" = "true" ] && [ "$DRY_RUN" != "true" ] || return 0
  if ! unexpected_entry="$(
      cd "$work_abs" || exit 1
      verify_pinned_work_root_cwd || exit 1
      find . -mindepth 1 -maxdepth 1 \
        ! -name artifacts \
        ! -name docker-build-args.txt \
        ! -name docker-build-inside.sh \
        ! -name sp11-oci-index.json \
        -print -quit
    )"; then
    echo "Could not inspect the release work-root membership exactly." >&2
    return 1
  fi
  if [ -n "$unexpected_entry" ]; then
    echo "Release work root contains an unexpected member before Docker." >&2
    return 1
  fi
  for expected_companion in \
    docker-build-args.txt docker-build-inside.sh sp11-oci-index.json; do
    if [ ! -f "$work_abs/$expected_companion" ] ||
       [ -L "$work_abs/$expected_companion" ]; then
      echo "Release work root is missing an exact regular companion: $expected_companion" >&2
      return 1
    fi
  done
  (
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
    verify_release_work_dirs_cwd || exit 1
  )
}

validate_legacy_control_paths() {
  local control_path

  for control_path in \
    "$work_abs/docker-build-args.txt" \
    "$work_abs/docker-build-inside.sh" \
    "$work_abs/sp11-oci-index.json"; do
    if [ -L "$control_path" ]; then
      echo "Refusing symlinked Docker control-file tripwire: $control_path" >&2
      return 1
    fi
    if [ -e "$control_path" ] && [ ! -f "$control_path" ]; then
      echo "Refusing non-regular legacy Docker control path: $control_path" >&2
      return 1
    fi
  done
}

install_control_file() {
  local source="$1" target="$2"

  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    echo "Refusing unsafe Docker control path during atomic install: $target" >&2
    return 1
  fi
  if ! mv "$source" "$target"; then
    echo "Could not atomically install Docker control file: $target" >&2
    return 1
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    echo "Docker control file is not a regular file after install: $target" >&2
    return 1
  fi
}

install_control_evidence_copy() {
  local source="$1" target="$2"
  local source_state installed_state target_name display_target

  case "$target" in
    "$work_abs"/docker-build-args.txt) target_name="docker-build-args.txt" ;;
    "$work_abs"/docker-build-inside.sh) target_name="docker-build-inside.sh" ;;
    "$work_abs"/sp11-oci-index.json) target_name="sp11-oci-index.json" ;;
    *)
      echo "Release Docker evidence path is outside its pinned work root: $target" >&2
      return 1
      ;;
  esac
  display_target="$work_abs/$target_name"

  (
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
    target="./$target_name"

    source_state="$(baseline_control_file_state "$source")" || {
      echo "Private Docker control input is unsafe before evidence copy: $source" >&2
      exit 1
    }
    if ! create_release_file_exclusive \
        "$work_abs" "$WORK_ROOT_IDENTITY" "$WORK_ROOT_FD" \
        "$target_name" 67108864 copy "$source"; then
      echo "Could not exclusively create retained Docker evidence: $display_target" >&2
      exit 1
    fi
    installed_state="$(baseline_control_file_state "$target")" || {
      echo "Retained Docker evidence is unsafe after creation: $display_target" >&2
      exit 1
    }
    if [ "${installed_state##*:}" != "${source_state##*:}" ]; then
      echo "Retained Docker evidence bytes differ from private control input: $display_target" >&2
      exit 1
    fi
    if [ "$(baseline_control_file_state "$source")" != "$source_state" ]; then
      echo "Private Docker control input changed during evidence copy: $source" >&2
      exit 1
    fi
    verify_pinned_work_root_cwd || exit 1
  )
}

validate_payload_dir() {
  local requested="$1" relative current component
  local -a components=()

  case "$requested" in
    *$'\n'*|*$'\r'*|*$'\t'*)
      echo "--payload-dir must not contain control characters." >&2
      return 1
      ;;
    /*)
      echo "--payload-dir must be repository-relative beneath payload/: $requested" >&2
      return 1
      ;;
    payload/*) relative="${requested#payload/}" ;;
    *)
      echo "--payload-dir must be a child of payload/: $requested" >&2
      return 1
      ;;
  esac
  case "$relative" in
    ""|*//*|*/|./*|*/./*)
      echo "--payload-dir must use a canonical relative path: $requested" >&2
      return 1
      ;;
  esac
  case "/$relative/" in
    */../*)
      echo "--payload-dir must not contain a '..' path component: $requested" >&2
      return 1
      ;;
  esac

  if [ -L "$repo_dir/payload" ] || [ ! -d "$repo_dir/payload" ]; then
    echo "Repository payload root must be a real directory, not a symlink." >&2
    return 1
  fi
  payload_root_abs="$(cd "$repo_dir/payload" && pwd -P)"
  if [ "$payload_root_abs" != "$repo_dir/payload" ]; then
    echo "Repository payload root did not resolve to its exact path." >&2
    return 1
  fi

  current="$payload_root_abs"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    case "$component" in
      ""|.|..)
        echo "--payload-dir contains an unsafe path component: $requested" >&2
        return 1
        ;;
    esac
    current="$current/$component"
    if [ -L "$current" ]; then
      echo "--payload-dir must not contain symlink components: $requested" >&2
      return 1
    fi
    if [ -e "$current" ] && [ ! -d "$current" ]; then
      echo "--payload-dir component is not a directory: $current" >&2
      return 1
    fi
  done
  payload_abs="$current"
}

create_validated_payload_dir() {
  local relative current component
  local -a components=()

  validate_payload_dir "$PAYLOAD_DIR" || return 1
  relative="${PAYLOAD_DIR#payload/}"
  current="$payload_root_abs"
  IFS='/' read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    current="$current/$component"
    if [ ! -e "$current" ]; then
      mkdir -m 755 "$current"
    fi
    if [ -L "$current" ] || [ ! -d "$current" ]; then
      echo "Unsafe payload directory component appeared during creation: $current" >&2
      return 1
    fi
  done
  if [ "$(cd "$payload_abs" && pwd -P)" != "$payload_abs" ]; then
    echo "--payload-dir did not resolve to its exact non-symlink path." >&2
    return 1
  fi
}

support_git() {
  GIT_OPTIONAL_LOCKS=0 git \
    -c "safe.directory=$repo_dir" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -C "$repo_dir" "$@"
}

validate_committed_support_tree() {
  local entry metadata relative_path mode object_type object_id remainder
  local actual_id filesystem_mode entry_count=0

  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *$'\n'*|*$'\r'*)
        echo "Committed support tree contains a control character in a path." >&2
        return 1
        ;;
    esac
    case "$entry" in
      *$'\t'*) ;;
      *)
        echo "Committed support tree record is malformed." >&2
        return 1
        ;;
    esac
    metadata="${entry%%$'\t'*}"
    relative_path="${entry#*$'\t'}"
    case "$relative_path" in
      *$'\t'*)
        echo "Committed support tree contains a tab in a path." >&2
        return 1
        ;;
    esac
    read -r mode object_type object_id remainder <<< "$metadata"
    if [ -n "$remainder" ] || [ "$object_type" != "blob" ] ||
       { [ "$mode" != "100644" ] && [ "$mode" != "100755" ]; } ||
       ! [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
      echo "Committed support tree contains a symlink, submodule, or unsupported entry." >&2
      return 1
    fi
    case "$relative_path" in
      ""|/*|*//*|../*|*/../*|*/..|*$'\n'*|*$'\r'*|*$'\t'*)
        echo "Committed support tree contains an unsafe path." >&2
        return 1
        ;;
    esac
    if [ ! -f "$COMMITTED_SUPPORT_DIR/$relative_path" ] ||
       [ -L "$COMMITTED_SUPPORT_DIR/$relative_path" ]; then
      echo "Committed support checkout did not materialize a regular file: $relative_path" >&2
      return 1
    fi
    actual_id="$(committed_support_git hash-object --no-filters -- "$relative_path")"
    [ "$actual_id" = "$object_id" ] || {
      echo "Committed support checkout raw bytes differ from Git: $relative_path" >&2
      return 1
    }
    case "$(uname -s)" in
      Darwin) filesystem_mode="$(stat -f '%Lp' "$COMMITTED_SUPPORT_DIR/$relative_path")" ;;
      *) filesystem_mode="$(stat -c '%a' -- "$COMMITTED_SUPPORT_DIR/$relative_path")" ;;
    esac
    if { [ "$mode" = "100644" ] && [ "$filesystem_mode" != "644" ]; } ||
       { [ "$mode" = "100755" ] && [ "$filesystem_mode" != "755" ]; }; then
      echo "Committed support checkout mode differs from Git: $relative_path" >&2
      return 1
    fi
    entry_count=$((entry_count + 1))
  done < <(committed_support_git -c core.quotePath=false \
    ls-tree -r -z --full-tree "$SUPPORT_HEAD_START")
  [ "$entry_count" -gt 0 ] || {
    echo "Committed support tree is empty." >&2
    return 1
  }
}

create_release_support_checkout() {
  local created_root expected_tree head tree status root_mode support_child_identity
  local previous_directory

  [ "$RELEASE_BUILD" = "true" ] || return 0
  expected_tree="$(support_git rev-parse --verify "$SUPPORT_HEAD_START^{tree}")"
  SUPPORT_SNAPSHOT_PARENT="$(cd /tmp && pwd -P)"
  created_root="$(umask 077 && mktemp -d "$SUPPORT_SNAPSHOT_PARENT/sp11-kernel-support.XXXXXX")"
  SUPPORT_SNAPSHOT_ROOT="$created_root"
  case "$SUPPORT_SNAPSHOT_ROOT" in
    "$SUPPORT_SNAPSHOT_PARENT"/sp11-kernel-support.*) ;;
    *)
      echo "Private committed-support snapshot path is not canonical." >&2
      exit 1
      ;;
  esac
  if [ -L "$SUPPORT_SNAPSHOT_ROOT" ] || [ ! -d "$SUPPORT_SNAPSHOT_ROOT" ]; then
    echo "Could not create a private committed-support snapshot root." >&2
    exit 1
  fi
  if ! SUPPORT_SNAPSHOT_ROOT_IDENTITY="$(
    cd "$SUPPORT_SNAPSHOT_ROOT"
    pinned_identity="$(baseline_control_identity .)" || exit 1
    [ -d "$SUPPORT_SNAPSHOT_ROOT" ] && [ ! -L "$SUPPORT_SNAPSHOT_ROOT" ] &&
      [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT")" = "$pinned_identity" ] ||
      exit 1
    printf '%s\n' "$pinned_identity"
  )"; then
    echo "Could not capture the pinned committed-support root identity." >&2
    exit 1
  fi
  previous_directory="$(pwd -P)" || exit 1
  if ! cd "$SUPPORT_SNAPSHOT_ROOT" ||
     [ "$(baseline_control_identity .)" != "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ]; then
    cd "$previous_directory" || true
    echo "Could not enter the pinned private committed-support root." >&2
    exit 1
  fi
  if ! exec 51< .; then
    cd "$previous_directory" || true
    echo "Could not hold the private committed-support root." >&2
    exit 1
  fi
  SUPPORT_SNAPSHOT_FD_OPEN="true"
  cd "$previous_directory" || exit 1
  if ! verify_held_release_directory \
      "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
      "$SUPPORT_SNAPSHOT_ROOT_IDENTITY"; then
    echo "Could not bind the held private committed-support root." >&2
    exit 1
  fi
  SUPPORT_SNAPSHOT_ACCESS_ROOT="$(held_release_directory_access_path \
    "$SUPPORT_SNAPSHOT_FD" "$SUPPORT_SNAPSHOT_ROOT" \
    "$SUPPORT_SNAPSHOT_ROOT_IDENTITY")"
  (
    cd "$SUPPORT_SNAPSHOT_ACCESS_ROOT"
    if [ ! -d . ] || [ -L . ] ||
       [ "$(baseline_control_identity .)" != "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ]; then
      echo "Could not pin the private committed-support snapshot root." >&2
      exit 1
    fi
    case "$(uname -s)" in
      Darwin) root_mode="$(stat -f '%Lp' .)" ;;
      *) root_mode="$(stat -c '%a' -- .)" ;;
    esac
    [ "$root_mode" = 700 ] || {
      echo "Private committed-support root was not created with mode 0700." >&2
      exit 1
    }
    mkdir -m 700 ./support
    support_child_identity="$(baseline_control_identity ./support)" || {
      echo "Could not capture the private committed-support checkout identity." >&2
      exit 1
    }
    (
      cd ./support
      if [ ! -d . ] || [ -L . ] ||
         [ "$(baseline_control_identity .)" != "$support_child_identity" ] ||
         [ ! -d "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ -L "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT/support")" != \
           "$support_child_identity" ]; then
        echo "Could not pin the private committed-support checkout directory." >&2
        exit 1
      fi
      COMMITTED_SUPPORT_DIR=.
      if ! GIT_ALLOW_PROTOCOL=file git \
          -c protocol.file.allow=always \
          clone --template= \
          --no-local --no-hardlinks --no-checkout --quiet -- \
          "$repo_dir" .; then
        echo "Could not make a standalone local-only committed-support checkout." >&2
        exit 1
      fi
      if [ "$(baseline_control_identity .)" != "$support_child_identity" ] ||
         [ ! -d "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ -L "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT/support")" != \
           "$support_child_identity" ]; then
        echo "Private committed-support checkout path changed during clone." >&2
        exit 1
      fi
      committed_support_git config core.hooksPath /dev/null
      committed_support_git config core.fsmonitor false
      committed_support_git config core.untrackedCache false
      committed_support_git checkout --detach --force --quiet "$SUPPORT_HEAD_START"
      committed_support_git remote remove origin
      hook_entry=""
      if [ -d ./.git/hooks ] &&
         ! hook_entry="$(find ./.git/hooks -mindepth 1 -print -quit)"; then
        echo "Could not inspect private support checkout hooks exactly." >&2
        exit 1
      fi
      if [ -e ./.git/objects/info/alternates ] || [ -n "$hook_entry" ]; then
        echo "Private support checkout retained shared objects, alternates, or hooks." >&2
        exit 1
      fi
      committed_support_git fsck --strict --no-dangling >/dev/null
      head="$(committed_support_git rev-parse --verify 'HEAD^{commit}')"
      tree="$(committed_support_git rev-parse --verify 'HEAD^{tree}')"
      status="$(committed_support_git status --porcelain=v1 --untracked-files=all --ignored)"
      if [ "$head" != "$SUPPORT_HEAD_START" ] || [ "$tree" != "$expected_tree" ] ||
         [ -n "$status" ]; then
        echo "Private committed-support checkout identity is not exact." >&2
        exit 1
      fi
      validate_committed_support_tree
      if ! empty_directory="$(
          find . -path ./.git -prune -o -type d -empty -print -quit
        )"; then
        echo "Could not inspect private support checkout directories exactly." >&2
        exit 1
      fi
      if [ -n "$empty_directory" ]; then
        echo "Private support checkout contains an untracked empty directory." >&2
        exit 1
      fi
      if [ "$(baseline_control_identity .)" != "$support_child_identity" ] ||
         [ ! -d "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ -L "$SUPPORT_SNAPSHOT_ROOT/support" ] ||
         [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT/support")" != \
           "$support_child_identity" ]; then
        echo "Private committed-support checkout path changed before sealing." >&2
        exit 1
      fi
    )
    COMMITTED_SUPPORT_DIR=./support
    if [ -L "$SUPPORT_SNAPSHOT_ROOT" ] || [ ! -d "$SUPPORT_SNAPSHOT_ROOT" ] ||
       [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT")" != \
         "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ]; then
      echo "Private committed-support snapshot root changed before sealing." >&2
      exit 1
    fi
  )
  COMMITTED_SUPPORT_DIR="$SUPPORT_SNAPSHOT_ROOT/support"
  COMMITTED_SUPPORT_ACCESS_DIR="$SUPPORT_SNAPSHOT_ACCESS_ROOT/support"
  if [ -L "$SUPPORT_SNAPSHOT_ROOT" ] || [ ! -d "$SUPPORT_SNAPSHOT_ROOT" ] ||
     [ "$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT")" != \
       "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ]; then
    echo "Private committed-support snapshot root changed after pinned creation." >&2
    exit 1
  fi
  head="$(committed_support_git rev-parse --verify 'HEAD^{commit}')"
  tree="$(committed_support_git rev-parse --verify 'HEAD^{tree}')"
  status="$(committed_support_git status --porcelain=v1 --untracked-files=all --ignored)"
  if [ "$head" != "$SUPPORT_HEAD_START" ] || [ "$tree" != "$expected_tree" ] ||
     [ -n "$status" ]; then
    echo "Private committed-support checkout changed before sealing." >&2
    exit 1
  fi
  SUPPORT_SNAPSHOT_TREE="$tree"
  validate_committed_support_tree
  capture_support_snapshot_inventory
  SUPPORT_SNAPSHOT_ROOT_STATE="$(support_snapshot_directory_state "$SUPPORT_SNAPSHOT_ROOT")"
  verify_release_support_checkout
}

snapshot_support_blob() {
  local relative_path="$1" expected_mode="$2" destination="$3"
  local entry metadata listed_path mode object_type object_id remainder actual_id hash_path
  local destination_name

  destination_name="$(basename "$destination")"
  if ! entry="$(committed_support_git ls-tree "$SUPPORT_HEAD_START" -- "$relative_path")"; then
    echo "Could not resolve committed support input: $relative_path" >&2
    return 1
  fi
  IFS=$'\t' read -r metadata listed_path remainder <<< "$entry"
  read -r mode object_type object_id remainder <<< "$metadata"
  if [ -n "$remainder" ] || [ "$listed_path" != "$relative_path" ] ||
     [ "$mode" != "$expected_mode" ] || [ "$object_type" != "blob" ] ||
     ! [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "Committed support input has an unexpected Git tree identity: $relative_path" >&2
    return 1
  fi
  if ! create_release_file_exclusive \
      "$BASELINE_CONTROL_DIR" "$BASELINE_CONTROL_IDENTITY" \
      "$BASELINE_CONTROL_FD" \
      "$destination_name" 1048576 copy \
      "$COMMITTED_SUPPORT_ACCESS_DIR/$relative_path"; then
    echo "Could not materialize committed support input: $relative_path" >&2
    return 1
  fi
  if [ ! -f "$destination" ] || [ -L "$destination" ]; then
    echo "Committed support snapshot is not a private regular file: $destination" >&2
    return 1
  fi
  hash_path="$destination"
  case "$hash_path" in
    /*) ;;
    *) hash_path="$(cd "$(dirname "$hash_path")" && pwd -P)/$(basename "$hash_path")" ;;
  esac
  actual_id="$(committed_support_git hash-object --no-filters -- "$hash_path")"
  if [ "$actual_id" != "$object_id" ]; then
    echo "Committed support snapshot does not match its Git blob: $relative_path" >&2
    return 1
  fi
}

create_release_baseline_control() {
  local created_dir root_mode previous_directory

  [ "$RELEASE_BUILD" = "true" ] || return 0
  require_tool shasum
  require_tool stat
  BASELINE_CONTROL_PARENT="$(cd /tmp && pwd -P)"
  created_dir="$(umask 077 && mktemp -d "$BASELINE_CONTROL_PARENT/sp11-kernel-baseline.XXXXXX")"
  BASELINE_CONTROL_DIR="$created_dir"
  case "$BASELINE_CONTROL_DIR" in
    "$BASELINE_CONTROL_PARENT"/sp11-kernel-baseline.*) ;;
    *)
      echo "Private committed-baseline control path is not canonical." >&2
      exit 1
      ;;
  esac
  if [ -L "$BASELINE_CONTROL_DIR" ] || [ ! -d "$BASELINE_CONTROL_DIR" ]; then
    echo "Could not create a private committed-baseline control directory." >&2
    exit 1
  fi
  if ! BASELINE_CONTROL_IDENTITY="$(
    cd "$BASELINE_CONTROL_DIR"
    pinned_identity="$(baseline_control_identity .)" || exit 1
    [ -d "$BASELINE_CONTROL_DIR" ] && [ ! -L "$BASELINE_CONTROL_DIR" ] &&
      [ "$(baseline_control_identity "$BASELINE_CONTROL_DIR")" = "$pinned_identity" ] ||
      exit 1
    printf '%s\n' "$pinned_identity"
  )"; then
    echo "Could not capture the pinned committed-baseline root identity." >&2
    exit 1
  fi
  previous_directory="$(pwd -P)" || exit 1
  if ! cd "$BASELINE_CONTROL_DIR" ||
     [ "$(baseline_control_identity .)" != "$BASELINE_CONTROL_IDENTITY" ]; then
    cd "$previous_directory" || true
    echo "Could not enter the pinned private committed-baseline root." >&2
    exit 1
  fi
  if ! exec 50< .; then
    cd "$previous_directory" || true
    echo "Could not hold the private committed-baseline control root." >&2
    exit 1
  fi
  BASELINE_CONTROL_FD_OPEN="true"
  cd "$previous_directory" || exit 1
  if ! verify_held_release_directory \
      "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
      "$BASELINE_CONTROL_IDENTITY"; then
    echo "Could not bind the held private committed-baseline control root." >&2
    exit 1
  fi
  BASELINE_CONTROL_ACCESS_DIR="$(held_release_directory_access_path \
    "$BASELINE_CONTROL_FD" "$BASELINE_CONTROL_DIR" \
    "$BASELINE_CONTROL_IDENTITY")"
  KERNEL_BASELINE="$BASELINE_CONTROL_DIR/kernel-baseline.env"
  KERNEL_BASELINE_VALIDATOR="$BASELINE_CONTROL_DIR/validate-sp11-kernel-baseline.sh"
  KERNEL_BASELINE_ACCESS="$BASELINE_CONTROL_ACCESS_DIR/kernel-baseline.env"
  KERNEL_BASELINE_VALIDATOR_ACCESS="$BASELINE_CONTROL_ACCESS_DIR/validate-sp11-kernel-baseline.sh"
  (
    cd "$BASELINE_CONTROL_ACCESS_DIR"
    if [ ! -d . ] || [ -L . ] ||
       [ "$(baseline_control_identity .)" != "$BASELINE_CONTROL_IDENTITY" ]; then
      echo "Could not pin the private committed-baseline control root." >&2
      exit 1
    fi
    case "$(uname -s)" in
      Darwin) root_mode="$(stat -f '%Lp' .)" ;;
      *) root_mode="$(stat -c '%a' -- .)" ;;
    esac
    [ "$root_mode" = 700 ] || {
      echo "Private committed-baseline root was not created with mode 0700." >&2
      exit 1
    }
    snapshot_support_blob "$KERNEL_BASELINE_REL" 100644 ./kernel-baseline.env
    snapshot_support_blob \
      "$KERNEL_BASELINE_VALIDATOR_REL" 100755 \
      ./validate-sp11-kernel-baseline.sh
    if [ -L "$BASELINE_CONTROL_DIR" ] || [ ! -d "$BASELINE_CONTROL_DIR" ] ||
       [ "$(baseline_control_identity "$BASELINE_CONTROL_DIR")" != \
         "$BASELINE_CONTROL_IDENTITY" ]; then
      echo "Private committed-baseline root changed before initial sealing." >&2
      exit 1
    fi
  )
  if [ -L "$BASELINE_CONTROL_DIR" ] || [ ! -d "$BASELINE_CONTROL_DIR" ] ||
     [ "$(baseline_control_identity "$BASELINE_CONTROL_DIR")" != \
       "$BASELINE_CONTROL_IDENTITY" ]; then
    echo "Private committed-baseline root changed after pinned creation." >&2
    exit 1
  fi
  KERNEL_BASELINE_STATE="$(baseline_control_file_state "$KERNEL_BASELINE")"
  KERNEL_BASELINE_VALIDATOR_STATE="$(baseline_control_file_state "$KERNEL_BASELINE_VALIDATOR")"
  KERNEL_BASELINE_SHA256="${KERNEL_BASELINE_STATE##*:}"
  if ! exec 53< "$KERNEL_BASELINE"; then
    echo "Could not hold the committed kernel baseline snapshot." >&2
    exit 1
  fi
  KERNEL_BASELINE_FD_OPEN="true"
  if ! exec 54< "$KERNEL_BASELINE_VALIDATOR"; then
    echo "Could not hold the committed kernel baseline validator snapshot." >&2
    exit 1
  fi
  KERNEL_BASELINE_VALIDATOR_FD_OPEN="true"
  verify_held_release_file \
    "$KERNEL_BASELINE_FD" "$KERNEL_BASELINE" "$KERNEL_BASELINE_SHA256" 600 || exit 1
  verify_held_release_file \
    "$KERNEL_BASELINE_VALIDATOR_FD" "$KERNEL_BASELINE_VALIDATOR" \
    "${KERNEL_BASELINE_VALIDATOR_STATE##*:}" 600 || exit 1
  case "$(uname -s)" in
    Linux) KERNEL_BASELINE_ACCESS="/proc/self/fd/$KERNEL_BASELINE_FD" ;;
    *) KERNEL_BASELINE_ACCESS="/dev/fd/$KERNEL_BASELINE_FD" ;;
  esac
  KERNEL_BASELINE_VALIDATOR_ACCESS="/dev/fd/$KERNEL_BASELINE_VALIDATOR_FD"
  BASELINE_CONTROL_INITIAL_STATE="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")"
  if ! verify_baseline_control_membership initial; then
    echo "Private committed-baseline control directory has unexpected contents." >&2
    exit 1
  fi
}

load_release_baseline_values() {
  local emitted key value remainder emitted_keys="" expected_keys

  verify_release_support_checkout || exit 1
  verify_initial_baseline_control_state || exit 1
  if ! emitted="$(
    exec 3<&53
    bash "$KERNEL_BASELINE_VALIDATOR_ACCESS" \
      --repo-dir "$COMMITTED_SUPPORT_ACCESS_DIR" \
      --emit-release-values \
      --baseline-fd 3
  )"; then
    echo "Committed release kernel baseline validation failed." >&2
    exit 1
  fi
  while IFS=$'\t' read -r key value remainder; do
    [ -n "$key" ] && [ -n "$value" ] && [ -z "$remainder" ] || {
      echo "Committed kernel baseline validator emitted malformed data." >&2
      exit 1
    }
    emitted_keys="${emitted_keys}${emitted_keys:+$'\n'}$key"
    case "$key" in
      SP11_KERNEL_BASELINE_ID) RELEASE_BASELINE_ID="$value" ;;
      SP11_KERNEL_DOCKER_IMAGE) RELEASE_BASELINE_DOCKER_IMAGE="$value" ;;
      SP11_KERNEL_DOCKER_PLATFORM) RELEASE_BASELINE_DOCKER_PLATFORM="$value" ;;
      SP11_KERNEL_DOCKER_PLATFORM_MANIFEST) RELEASE_BASELINE_DOCKER_PLATFORM_MANIFEST="$value" ;;
      SP11_KERNEL_UPSTREAM_URL) RELEASE_BASELINE_UPSTREAM_URL="$value" ;;
      SP11_KERNEL_UPSTREAM_REF) RELEASE_BASELINE_UPSTREAM_REF="$value" ;;
      SP11_KERNEL_UPSTREAM_COMMIT) RELEASE_BASELINE_UPSTREAM_COMMIT="$value" ;;
      SP11_KERNEL_SOURCE_DATE_EPOCH) RELEASE_SOURCE_DATE_EPOCH="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_USER) RELEASE_KBUILD_BUILD_USER="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_HOST) RELEASE_KBUILD_BUILD_HOST="$value" ;;
      SP11_KERNEL_KBUILD_BUILD_TIMESTAMP) RELEASE_KBUILD_BUILD_TIMESTAMP="$value" ;;
      SP11_KERNEL_BUILD_TARGET) RELEASE_BASELINE_BUILD_TARGET="$value" ;;
      SP11_KERNEL_PATCH_DIRS) RELEASE_BASELINE_PATCH_DIRS="$value" ;;
      *)
        echo "Committed kernel baseline validator emitted an unexpected key: $key" >&2
        exit 1
        ;;
    esac
  done <<< "$emitted"
  expected_keys=$'SP11_KERNEL_BASELINE_ID\nSP11_KERNEL_DOCKER_IMAGE\nSP11_KERNEL_DOCKER_PLATFORM\nSP11_KERNEL_DOCKER_PLATFORM_MANIFEST\nSP11_KERNEL_UPSTREAM_URL\nSP11_KERNEL_UPSTREAM_REF\nSP11_KERNEL_UPSTREAM_COMMIT\nSP11_KERNEL_SOURCE_DATE_EPOCH\nSP11_KERNEL_KBUILD_BUILD_USER\nSP11_KERNEL_KBUILD_BUILD_HOST\nSP11_KERNEL_KBUILD_BUILD_TIMESTAMP\nSP11_KERNEL_BUILD_TARGET\nSP11_KERNEL_PATCH_DIRS'
  if [ "$emitted_keys" != "$expected_keys" ]; then
    echo "Committed kernel baseline validator field set/order is not exact." >&2
    exit 1
  fi
  refresh_initial_baseline_control_state_after_held_validation || {
    echo "Held committed-baseline authority changed during validation." >&2
    exit 1
  }
  verify_release_support_checkout || exit 1
}

support_dirty_value() {
  local status_output

  if ! status_output="$(support_git status --porcelain --untracked-files=all)"; then
    echo "Could not inspect the support repository worktree state." >&2
    return 1
  fi
  if [ -n "$status_output" ]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
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

capture_release_support_start() {
  local support_dirty

  [ "$RELEASE_BUILD" = "true" ] || return 0

  require_tool git
  if ! support_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "--release-build requires the support scripts to come from a Git worktree." >&2
    exit 1
  fi
  SUPPORT_HEAD_START="$(support_git rev-parse --verify 'HEAD^{commit}')"
  SUPPORT_HEAD_START="$(printf '%s' "$SUPPORT_HEAD_START" | tr '[:upper:]' '[:lower:]')"
  if ! [[ "$SUPPORT_HEAD_START" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "Could not resolve an exact support repository commit for --release-build." >&2
    exit 1
  fi
  if ! support_dirty="$(support_dirty_value)"; then
    exit 1
  fi
  if [ "$support_dirty" != "false" ]; then
    echo "--release-build requires a clean support repository at start." >&2
    exit 1
  fi
}

verify_release_support_stable() {
  local support_head_end support_dirty_end

  [ "$RELEASE_BUILD" = "true" ] || return 0
  support_head_end="$(support_git rev-parse --verify 'HEAD^{commit}')"
  support_head_end="$(printf '%s' "$support_head_end" | tr '[:upper:]' '[:lower:]')"
  if ! support_dirty_end="$(support_dirty_value)"; then
    exit 1
  fi
  if [ "$support_head_end" != "$SUPPORT_HEAD_START" ] || [ "$support_dirty_end" != "false" ]; then
    echo "Support repository changed during the Docker release build; refusing completion." >&2
    echo "Start HEAD: $SUPPORT_HEAD_START" >&2
    echo "End HEAD:   $support_head_end" >&2
    echo "End dirty:  $support_dirty_end" >&2
    exit 1
  fi
}

docker_control_file_state() {
  local path="$1" state

  state="$(baseline_control_file_state "$path")" || {
    echo "Docker control input is not a regular non-symlinked file: $path" >&2
    return 1
  }
  printf '%s\n' "$state"
}

capture_docker_control_state() {
  local path state

  require_tool shasum
  require_tool stat
  CONTROL_SNAPSHOT_FILES=(
    "$work_abs/docker-build-args.txt"
    "$work_abs/docker-build-inside.sh"
  )
  if [ "$IMMUTABLE_APT" = "true" ]; then
    CONTROL_SNAPSHOT_FILES+=("$work_abs/sp11-oci-index.json")
  fi
  CONTROL_SNAPSHOT_VALUES=()
  for path in "${CONTROL_SNAPSHOT_FILES[@]}"; do
    state="$(docker_control_file_state "$path")" || return 1
    CONTROL_SNAPSHOT_VALUES+=("$state")
  done
}

verify_docker_control_state() {
  local index=0 current

  while [ "$index" -lt "${#CONTROL_SNAPSHOT_FILES[@]}" ]; do
    current="$(docker_control_file_state "${CONTROL_SNAPSHOT_FILES[$index]}")" || return 1
    if [ "$current" != "${CONTROL_SNAPSHOT_VALUES[$index]}" ]; then
      echo "Docker control input changed after its pre-run validation: ${CONTROL_SNAPSHOT_FILES[$index]}" >&2
      return 1
    fi
    index=$((index + 1))
  done
}

find_qcom_kernel_debs() {
  find "$1" -maxdepth 4 -type f \
    \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
    -o -name 'linux-image-*-qcom-x1e_*.deb' \
    -o -name 'linux-modules-*-qcom-x1e_*.deb' \
    -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
    -o -name 'linux-headers-*-qcom-x1e_*.deb' \
    -o -name 'linux-qcom-x1e-headers-*_*.deb' \
    -o -name 'linux-qcom-x1e_*.deb' \
    -o -name 'linux-image-qcom-x1e_*.deb' \
    -o -name 'linux-headers-qcom-x1e_*.deb' \) \
    -print | LC_ALL=C sort -u
}

abs_path() {
  local path="$1"
  if [ -d "$path" ]; then
    (cd "$path" && pwd)
  else
    (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd)" "$(basename "$path")")
  fi
}

repo_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$repo_dir" "$1" ;;
  esac
}

committed_repo_abs_path() {
  local requested="$1" relative

  case "$requested" in
    "$repo_dir"/*) relative="${requested#"$repo_dir"/}" ;;
    /*)
      echo "Release support path must be repository-relative: $requested" >&2
      return 1
      ;;
    *) relative="$requested" ;;
  esac
  case "/$relative/" in
    */../*|*/./*|*//*|*$'\n'*|*$'\r'*|*$'\t'*)
      echo "Release support path is not canonical: $requested" >&2
      return 1
      ;;
  esac
  [ -n "$relative" ] || return 1
  printf '%s/%s\n' "$COMMITTED_SUPPORT_DIR" "$relative"
}

repo_container_path() {
  local abs rel
  if [ "$RELEASE_BUILD" = "true" ]; then
    abs="$(committed_repo_abs_path "$1")" || exit 1
    [ -d "$abs" ] && [ ! -L "$abs" ] || {
      echo "Committed release support path is missing or unsafe: $1" >&2
      exit 1
    }
    rel="${abs#"$COMMITTED_SUPPORT_DIR"/}"
    printf '/repo/%s\n' "$rel"
    return 0
  fi
  abs="$(repo_abs_path "$1")"
  case "$abs" in
    "$repo_dir"/*)
      rel="${abs#"$repo_dir"/}"
      printf '/repo/%s\n' "$rel"
      ;;
    *)
      echo "Path must be inside this repository so Docker can access it: $1" >&2
      exit 1
      ;;
  esac
}

is_case_insensitive_dir() {
  local dir probe count

  dir="$1"
  probe="$(mktemp -d "$dir/.case-check.XXXXXX")"
  touch "$probe/sp11-case-check" "$probe/SP11-case-check"
  count="$(find "$probe" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
  rm -rf "$probe"

  [ "$count" -lt 2 ]
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KERNEL_BASELINE="$repo_dir/$KERNEL_BASELINE_REL"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --metadata)
      require_arg "$1" "${2:-}"
      METADATA="$2"
      shift 2
      ;;
    --source)
      require_arg "$1" "${2:-}"
      SOURCE_MODE="$2"
      shift 2
      ;;
    --source-package)
      require_arg "$1" "${2:-}"
      SOURCE_PACKAGE="$2"
      shift 2
      ;;
    --source-version)
      require_arg "$1" "${2:-}"
      SOURCE_VERSION="$2"
      shift 2
      ;;
    --git-url)
      require_arg "$1" "${2:-}"
      GIT_URL="$2"
      shift 2
      ;;
    --git-branch)
      require_arg "$1" "${2:-}"
      GIT_BRANCH="$2"
      shift 2
      ;;
    --expected-source-commit)
      require_arg "$1" "${2:-}"
      EXPECTED_SOURCE_COMMIT="$2"
      shift 2
      ;;
    --image)
      require_arg "$1" "${2:-}"
      IMAGE="$2"
      IMAGE_EXPLICIT="true"
      shift 2
      ;;
    --platform)
      require_arg "$1" "${2:-}"
      PLATFORM="$2"
      PLATFORM_EXPLICIT="true"
      shift 2
      ;;
    --release-build)
      RELEASE_BUILD="true"
      shift
      ;;
    --work-dir)
      require_arg "$1" "${2:-}"
      WORK_DIR="$2"
      shift 2
      ;;
    --container-work-dir)
      require_arg "$1" "${2:-}"
      CONTAINER_WORK_DIR="$2"
      shift 2
      ;;
    --linux-work-volume)
      require_arg "$1" "${2:-}"
      LINUX_WORK_VOLUME="$2"
      shift 2
      ;;
    --build-target)
      require_arg "$1" "${2:-}"
      BUILD_TARGET="$2"
      shift 2
      ;;
    --patch-dir)
      require_arg "$1" "${2:-}"
      PATCH_DIR="$2"
      shift 2
      ;;
    --patch-dirs)
      require_arg "$1" "${2:-}"
      PATCH_DIRS="$2"
      shift 2
      ;;
    --jobs)
      require_arg "$1" "${2:-}"
      JOBS="$2"
      shift 2
      ;;
    --min-free-gb)
      require_arg "$1" "${2:-}"
      MIN_FREE_GB="$2"
      shift 2
      ;;
    --apt-sources)
      require_arg "$1" "${2:-}"
      APT_SOURCES_FILE="$2"
      shift 2
      ;;
    --no-enable-deb-src)
      ENABLE_DEB_SRC="false"
      shift
      ;;
    --copy-to-payload)
      COPY_TO_PAYLOAD="true"
      shift
      ;;
    --payload-dir)
      require_arg "$1" "${2:-}"
      PAYLOAD_DIR="$2"
      COPY_TO_PAYLOAD="true"
      shift 2
      ;;
    --reset-source)
      RESET_SOURCE="true"
      shift
      ;;
    --skip-clean)
      SKIP_CLEAN="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
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

case "$SOURCE_MODE" in
  apt|git)
    ;;
  *)
    echo "Invalid --source: $SOURCE_MODE (expected apt or git)" >&2
    exit 2
    ;;
esac

if [ -n "$EXPECTED_SOURCE_COMMIT" ]; then
  if [ "$SOURCE_MODE" != "git" ]; then
    echo "--expected-source-commit requires --source git." >&2
    exit 2
  fi
  if ! [[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "--expected-source-commit must be an exact 40-hex commit." >&2
    exit 2
  fi
  EXPECTED_SOURCE_COMMIT="$(printf '%s' "$EXPECTED_SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')"
fi

if [ -z "$IMAGE" ]; then
  case "$SOURCE_MODE" in
    git)
      case "$GIT_BRANCH" in
        jg/ubuntu-qcom-x1e-*) IMAGE="ubuntu:26.04" ;;
        *) IMAGE="ubuntu:25.10" ;;
      esac
      ;;
    *) IMAGE="ubuntu:26.04" ;;
  esac
fi

if [ "$RELEASE_BUILD" = "true" ]; then
  if [ "$SOURCE_MODE" != "git" ] || [ -z "$EXPECTED_SOURCE_COMMIT" ]; then
    echo "--release-build requires Git source and --expected-source-commit." >&2
    exit 2
  fi
  if [ -n "$GIT_URL" ] && ! public_https_url "$GIT_URL"; then
    echo "--release-build requires a public HTTPS --git-url without credentials, query, or fragment." >&2
    exit 2
  fi
  if [ -n "$GIT_BRANCH" ] &&
     { ! [[ "$GIT_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
       ! git check-ref-format "refs/heads/$GIT_BRANCH" >/dev/null 2>&1; }; then
    echo "--release-build requires a safe full --git-branch ref name." >&2
    exit 2
  fi
  if [ "$IMAGE_EXPLICIT" != "true" ] ||
     ! [[ "$IMAGE" =~ ^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$ ]]; then
    echo "--release-build requires an explicit --image pinned with @sha256." >&2
    exit 2
  fi
  if [ "$PLATFORM_EXPLICIT" != "true" ]; then
    echo "--release-build requires an explicit --platform." >&2
    exit 2
  fi
  case "$PLATFORM" in
    linux/arm64|linux/arm64/v8) ;;
    *)
      echo "--release-build requires --platform linux/arm64 or linux/arm64/v8." >&2
      exit 2
      ;;
  esac
  if [ "$SKIP_CLEAN" = "true" ]; then
    echo "--release-build cannot be combined with --skip-clean." >&2
    exit 2
  fi
  if [ "$COPY_TO_PAYLOAD" = "true" ]; then
    echo "--release-build cannot copy packages into the tracked payload tree." >&2
    exit 2
  fi
  if [ "$CONTAINER_WORK_DIR" = "/work" ]; then
    echo "--release-build requires a named Linux work volume; --container-work-dir /work is not allowed." >&2
    exit 2
  fi
  if [ -n "$APT_SOURCES_FILE" ]; then
    echo "--release-build cannot use mutable --apt-sources input." >&2
    exit 2
  fi
  capture_release_python_authority || exit 1
fi

capture_release_support_start

case "$CONTAINER_WORK_DIR" in
  /*) ;;
  *)
    echo "--container-work-dir must be an absolute container path." >&2
    exit 2
    ;;
esac

case "$CONTAINER_WORK_DIR" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    echo "--container-work-dir must not contain control characters." >&2
    exit 2
    ;;
esac
if ! normalized_container_work_dir="$(normalize_absolute_path "$CONTAINER_WORK_DIR")" ||
   [ "$normalized_container_work_dir" != "$CONTAINER_WORK_DIR" ]; then
  echo "--container-work-dir must use a canonical absolute path without '.', '..', duplicate, or trailing separators." >&2
  exit 2
fi

case "$CONTAINER_WORK_DIR" in
  /work/*)
    echo "--container-work-dir must not be nested under /work." >&2
    echo "Use /work for the host-mounted work dir or keep the default /linux-work volume." >&2
    exit 2
    ;;
esac

case "$CONTAINER_WORK_DIR" in
  /repo|/repo/*|/sp11-control|/sp11-control/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/etc|/etc/*|\
  /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|\
  /run|/run/*|/tmp|/tmp/*|/var|/var/*|/)
    echo "--container-work-dir must not overlap a container control or support-repository mount: $CONTAINER_WORK_DIR" >&2
    exit 2
    ;;
esac

if [ "$CONTAINER_WORK_DIR" != "/work" ] && [ -z "$LINUX_WORK_VOLUME" ]; then
  echo "--linux-work-volume must not be empty when --container-work-dir is not /work." >&2
  exit 2
fi

if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
  if [ "${#LINUX_WORK_VOLUME}" -gt 128 ] ||
     ! [[ "$LINUX_WORK_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "--linux-work-volume must be a Docker named volume, not a host path or mount specification." >&2
    exit 2
  fi
fi

if [ -n "$METADATA" ]; then
  METADATA="$(abs_path "$METADATA")"
  if [ ! -f "$METADATA" ]; then
    echo "Metadata file not found: $METADATA" >&2
    exit 1
  fi
  metadata_values="$(
    set -euo pipefail
    SP11_SOURCE_PACKAGE=""
    SP11_SOURCE_VERSION=""
    SP11_BUILD_TARGET=""
    # shellcheck source=/dev/null
    . "$METADATA"
    printf 'SP11_SOURCE_PACKAGE=%s\n' "$SP11_SOURCE_PACKAGE"
    printf 'SP11_SOURCE_VERSION=%s\n' "$SP11_SOURCE_VERSION"
    printf 'SP11_BUILD_TARGET=%s\n' "$SP11_BUILD_TARGET"
  )"
  while IFS='=' read -r key value; do
    case "$key" in
      SP11_SOURCE_PACKAGE) metadata_source_package="$value" ;;
      SP11_SOURCE_VERSION) metadata_source_version="$value" ;;
      SP11_BUILD_TARGET) metadata_build_target="$value" ;;
    esac
  done <<<"$metadata_values"
  SOURCE_PACKAGE="${SOURCE_PACKAGE:-${metadata_source_package:-}}"
  SOURCE_VERSION="${SOURCE_VERSION:-${metadata_source_version:-}}"
  BUILD_TARGET="${BUILD_TARGET:-${metadata_build_target:-}}"
fi

if [ "$SOURCE_MODE" = "apt" ]; then
  if [ -z "$SOURCE_PACKAGE" ] || [ -z "$SOURCE_VERSION" ]; then
    echo "Docker apt-source mode needs --metadata or explicit --source-package and --source-version." >&2
    echo "Run scripts/collect-sp11-kernel-source-metadata.sh on the Surface first." >&2
    exit 1
  fi
fi

if [ -n "$JOBS" ] && { ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; }; then
  echo "--jobs must be a positive integer." >&2
  exit 2
fi

if [ -n "$MIN_FREE_GB" ] && { ! [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || [ "$MIN_FREE_GB" -lt 1 ]; }; then
  echo "--min-free-gb must be a positive integer." >&2
  exit 2
fi

if [ "$RELEASE_BUILD" = "true" ] &&
   [ "$BUILD_TARGET" != "binary-indep binary-qcom-x1e" ]; then
  echo "--release-build requires --build-target \"binary-indep binary-qcom-x1e\"." >&2
  exit 2
fi

if [ -n "$APT_SOURCES_FILE" ]; then
  APT_SOURCES_FILE="$(abs_path "$APT_SOURCES_FILE")"
  if [ ! -f "$APT_SOURCES_FILE" ]; then
    echo "apt sources file not found: $APT_SOURCES_FILE" >&2
    exit 1
  fi
fi

create_release_support_checkout
bind_release_support_python_scripts
create_release_baseline_control

if [ -n "$PATCH_DIRS" ]; then
  for pd in $PATCH_DIRS; do
    if [ "$RELEASE_BUILD" = "true" ]; then
      patch_dir_abs="$(committed_repo_abs_path "$pd")" || exit 1
    else
      patch_dir_abs="$(repo_abs_path "$pd")"
    fi
    if [ ! -d "$patch_dir_abs" ]; then
      echo "Patch directory not found: $patch_dir_abs" >&2
      exit 1
    fi
  done
elif [ -n "$PATCH_DIR" ]; then
  if [ "$RELEASE_BUILD" = "true" ]; then
    patch_dir_abs="$(committed_repo_abs_path "$PATCH_DIR")" || exit 1
  else
    patch_dir_abs="$(repo_abs_path "$PATCH_DIR")"
  fi
  if [ ! -d "$patch_dir_abs" ]; then
    echo "Patch directory not found: $patch_dir_abs" >&2
    exit 1
  fi
fi

if ! work_abs="$(ensure_safe_work_dir "$WORK_DIR")"; then
  exit 1
fi
if ! capture_release_work_root_identity; then
  exit 1
fi

if [ "$RELEASE_BUILD" = "true" ]; then
  load_release_baseline_values
  if [ -z "$RELEASE_SOURCE_DATE_EPOCH" ] || [ -z "$RELEASE_KBUILD_BUILD_USER" ] ||
     [ -z "$RELEASE_KBUILD_BUILD_HOST" ] || [ -z "$RELEASE_KBUILD_BUILD_TIMESTAMP" ]; then
    echo "Release kernel baseline is missing the deterministic build-identity values." >&2
    exit 1
  fi
  [ "$IMAGE" = "$RELEASE_BASELINE_DOCKER_IMAGE" ] || {
    echo "--release-build image does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ "$PLATFORM" = "$RELEASE_BASELINE_DOCKER_PLATFORM" ] || {
    echo "--release-build platform does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ "$GIT_URL" = "$RELEASE_BASELINE_UPSTREAM_URL" ] || {
    echo "--release-build Git URL does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ "$GIT_BRANCH" = "$RELEASE_BASELINE_UPSTREAM_REF" ] || {
    echo "--release-build Git ref does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ "$EXPECTED_SOURCE_COMMIT" = "$RELEASE_BASELINE_UPSTREAM_COMMIT" ] || {
    echo "--release-build source commit does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ "$BUILD_TARGET" = "$RELEASE_BASELINE_BUILD_TARGET" ] || {
    echo "--release-build target does not match the immutable kernel baseline." >&2
    exit 2
  }
  [ -z "$PATCH_DIR" ] && [ "$PATCH_DIRS" = "$RELEASE_BASELINE_PATCH_DIRS" ] || {
    echo "--release-build patch directories do not match the immutable kernel baseline." >&2
    exit 2
  }
  IMMUTABLE_APT="true"
fi

if [ "$COPY_TO_PAYLOAD" = "true" ]; then
  if ! validate_payload_dir "$PAYLOAD_DIR"; then
    exit 1
  fi
fi

if [ "$CONTAINER_WORK_DIR" = "/work" ] && is_case_insensitive_dir "$work_abs"; then
  echo "Refusing to build Linux kernel source on a case-insensitive host work directory:" >&2
  echo "  $work_abs" >&2
  echo "Use the default Docker Linux work volume, or pass a case-sensitive host filesystem." >&2
  exit 1
fi

if [ "$IMMUTABLE_APT" = "true" ] && [ "$DRY_RUN" != "true" ]; then
  if [ "$RELEASE_BUILD" = "true" ]; then
    verify_release_python_authority || {
      echo "Trusted release Python authority changed before use." >&2
      exit 1
    }
  else
    require_tool python3
  fi
  require_apt_list_decoder
fi

if [ "$DRY_RUN" != "true" ]; then
  require_tool docker
  DOCKER_BIN="$(command -v docker)"
  case "$DOCKER_BIN" in
    /*) ;;
    *)
      echo "Could not resolve Docker to an absolute command path." >&2
      exit 1
      ;;
  esac
  [ -x "$DOCKER_BIN" ] || {
    echo "The resolved absolute Docker command is not executable." >&2
    exit 1
  }
fi

if [ "$IMMUTABLE_APT" = "true" ]; then
  if ! release_dir_records="$(
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
    # The retained APT trees never cross back into host directories. They stay
    # in the private Docker release-state volume and are exported only inside
    # one canonical evidence tar. Only the small flat artifact set has a held
    # host publication directory.
    for release_name in artifacts; do
      release_dir="./$release_name"
      display_release_dir="$work_abs/$release_name"
      if [ -L "$release_dir" ] ||
         { [ -e "$release_dir" ] && [ ! -d "$release_dir" ]; }; then
        echo "Refusing unsafe release-build directory: $display_release_dir" >&2
        exit 1
      fi
      if [ ! -e "$release_dir" ]; then
        echo "Release-build artifact directory must already exist: $display_release_dir" >&2
        exit 1
      fi
      if [ ! -d "$release_dir" ] || [ -L "$release_dir" ]; then
        echo "Release-build directory is not a real directory: $display_release_dir" >&2
        exit 1
      fi
      if ! release_dir_entry="$(
          find "$release_dir" -mindepth 1 -maxdepth 1 -print -quit
        )"; then
        echo "Could not inspect release-build directory exactly: $display_release_dir" >&2
        exit 1
      fi
      if [ -n "$release_dir_entry" ]; then
        echo "Release-build directory must start empty: $display_release_dir" >&2
        exit 1
      fi
      release_dir_identity="$(baseline_control_identity "$release_dir")" || exit 1
      printf '%s\t%s\n' "$release_name" "$release_dir_identity"
    done
    verify_pinned_work_root_cwd || exit 1
  )"; then
    exit 1
  fi
  RELEASE_WORK_DIR_NAMES=()
  RELEASE_WORK_DIR_IDENTITIES=()
  while IFS=$'\t' read -r release_name release_dir_identity remainder; do
    [ -n "$release_name" ] && [ -n "$release_dir_identity" ] && [ -z "$remainder" ] || {
      echo "Release work-directory identity capture was malformed." >&2
      exit 1
    }
    RELEASE_WORK_DIR_NAMES+=("$release_name")
    RELEASE_WORK_DIR_IDENTITIES+=("$release_dir_identity")
    case "$release_name" in
      artifacts) RELEASE_ARTIFACTS_IDENTITY="$release_dir_identity" ;;
    esac
  done <<< "$release_dir_records"
  [ "${#RELEASE_WORK_DIR_NAMES[@]}" -eq 1 ] || {
    echo "Release work-directory identity set is not exact." >&2
    exit 1
  }
  release_previous_directory="$(pwd -P)" || exit 1
  if ! cd "$work_abs/artifacts" ||
     [ "$(baseline_control_identity .)" != "$RELEASE_ARTIFACTS_IDENTITY" ]; then
    cd "$release_previous_directory" || true
    echo "Could not enter the pinned release artifact directory." >&2
    exit 1
  fi
  # Acquire the descriptor through the held cwd object, never by reopening the
  # attacker-replaceable artifact pathname.
  if ! exec 58< .; then
    cd "$release_previous_directory" || true
    echo "Could not hold the release artifact directory." >&2
    exit 1
  fi
  RELEASE_ARTIFACTS_FD_OPEN="true"
  cd "$release_previous_directory" || exit 1
  verify_held_release_directory \
    "$RELEASE_ARTIFACTS_FD" "$work_abs/artifacts" \
    "$RELEASE_ARTIFACTS_IDENTITY" || exit 1
  release_artifact_import_record="$(
    held_release_directory_identity_fields "$RELEASE_ARTIFACTS_FD"
  )" || exit 1
  read -r release_artifact_import_dev release_artifact_import_ino \
    release_artifact_import_mode release_artifact_import_uid \
    release_artifact_import_gid release_artifact_import_remainder \
    <<< "$release_artifact_import_record"
  if [ -n "$release_artifact_import_remainder" ] ||
     ! [[ "$release_artifact_import_dev" =~ ^[0-9]+$ ]] ||
     ! [[ "$release_artifact_import_ino" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$release_artifact_import_mode" =~ ^[1-9][0-9]*$ ]] ||
     ! [[ "$release_artifact_import_uid" =~ ^[0-9]+$ ]] ||
     ! [[ "$release_artifact_import_gid" =~ ^[0-9]+$ ]]; then
    echo "Held release artifact import identity is malformed." >&2
    exit 1
  fi
  if [ "$release_artifact_import_mode" -ne 448 ] ||
     [ "$release_artifact_import_uid" -ne "$EUID" ]; then
    echo "Release artifact directory must be mode 0700 and owned by the invoking uid: $work_abs/artifacts" >&2
    exit 1
  fi
  RELEASE_ARTIFACTS_IMPORT_IDENTITY=(
    "$release_artifact_import_dev"
    "$release_artifact_import_ino"
    "$release_artifact_import_mode"
    "$release_artifact_import_uid"
    "$release_artifact_import_gid"
  )
  verify_release_work_root_binding || exit 1
fi

if ! validate_legacy_control_paths; then
  exit 1
fi
if [ "$RELEASE_BUILD" = "true" ]; then
  args_file="$BASELINE_CONTROL_DIR/docker-build-args.txt"
  run_script="$BASELINE_CONTROL_DIR/docker-build-inside.sh"
  oci_index_file="$BASELINE_CONTROL_DIR/sp11-oci-index.json"
else
  CONTROL_DIR="$(mktemp -d "$work_abs/.sp11-docker-control.XXXXXX")"
  chmod 700 "$CONTROL_DIR"
  if [ -L "$CONTROL_DIR" ] || [ ! -d "$CONTROL_DIR" ]; then
    echo "Could not create a private Docker control directory safely." >&2
    exit 1
  fi
  args_file="$CONTROL_DIR/docker-build-args.txt"
  run_script="$CONTROL_DIR/docker-build-inside.sh"
  oci_index_file="$CONTROL_DIR/sp11-oci-index.json"
fi
if [ "$RELEASE_BUILD" = "true" ]; then
  verify_initial_baseline_control_state || exit 1
fi

if [ "$IMMUTABLE_APT" = "true" ] && [ "$DRY_RUN" != "true" ]; then
  EXPECTED_RELEASE_OCI_INDEX_SHA256="${IMAGE##*@sha256:}"
  if ! [[ "$EXPECTED_RELEASE_OCI_INDEX_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Pinned release OCI index digest is not canonical." >&2
    exit 1
  fi
  verify_initial_baseline_control_state || exit 1
  if ! create_release_file_exclusive \
      "$BASELINE_CONTROL_DIR" "$BASELINE_CONTROL_IDENTITY" \
      "$BASELINE_CONTROL_FD" \
      sp11-oci-index.json 67108864 command \
      "$DOCKER_BIN" buildx imagetools inspect --raw "$IMAGE"; then
    echo "Could not capture the raw pinned OCI index." >&2
    exit 1
  fi
  RELEASE_OCI_INDEX_STATE="$(baseline_control_file_state "$oci_index_file")" || exit 1
  RELEASE_OCI_INDEX_SHA256="${RELEASE_OCI_INDEX_STATE##*:}"
  if [ "$RELEASE_OCI_INDEX_SHA256" != "$EXPECTED_RELEASE_OCI_INDEX_SHA256" ]; then
    echo "Private OCI index bytes differ from the pinned index digest." >&2
    exit 1
  fi
  verify_release_support_checkout
  verify_release_python_authority || exit 1
  if ! run_bound_release_support_python \
      scripts/validate-sp11-oci-index.py 1048576 \
      "$RELEASE_OCI_VALIDATOR_IDENTITY" "$RELEASE_OCI_VALIDATOR_SHA256" \
      "$RELEASE_OCI_VALIDATOR_OBJECT_ID" "$RELEASE_OCI_VALIDATOR_MODE" \
      --raw-index "$BASELINE_CONTROL_ACCESS_DIR/sp11-oci-index.json" \
      --index-ref "$RELEASE_BASELINE_DOCKER_IMAGE" \
      --platform "$RELEASE_BASELINE_DOCKER_PLATFORM" \
      --expected-platform-manifest "$RELEASE_BASELINE_DOCKER_PLATFORM_MANIFEST"; then
    echo "Could not execute the exact committed OCI-index validator." >&2
    exit 1
  fi
  if [ "$(baseline_control_file_state "$oci_index_file")" != "$RELEASE_OCI_INDEX_STATE" ]; then
    echo "Private OCI index changed during semantic validation." >&2
    exit 1
  fi
  verify_release_support_checkout
fi
if [ "$RELEASE_BUILD" = "true" ] && [ "$DRY_RUN" = "true" ]; then
  # A dry-run does not query Docker, but its printed entrypoint and validator
  # vector still bind the reviewed raw OCI-index digest from the pinned image.
  RELEASE_OCI_INDEX_SHA256="${IMAGE##*@sha256:}"
  [[ "$RELEASE_OCI_INDEX_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Pinned release OCI index digest is not canonical." >&2
    exit 1
  }
fi

inner_args=(
  --source "$SOURCE_MODE"
  --work-dir "$CONTAINER_WORK_DIR"
  --install-deps
  --no-fakeroot
)
if [ "$RELEASE_BUILD" = "true" ]; then
  inner_args+=(
    --release-build
    --source-date-epoch "$RELEASE_SOURCE_DATE_EPOCH"
    --kbuild-build-user "$RELEASE_KBUILD_BUILD_USER"
    --kbuild-build-host "$RELEASE_KBUILD_BUILD_HOST"
    --kbuild-build-timestamp "$RELEASE_KBUILD_BUILD_TIMESTAMP"
  )
fi

case "$SOURCE_MODE" in
  apt)
    inner_args+=(--source-package "$SOURCE_PACKAGE" --source-version "$SOURCE_VERSION")
    ;;
  git)
    [ -n "$GIT_URL" ] && inner_args+=(--git-url "$GIT_URL")
    [ -n "$GIT_BRANCH" ] && inner_args+=(--git-branch "$GIT_BRANCH")
    [ -n "$EXPECTED_SOURCE_COMMIT" ] && inner_args+=(--expected-source-commit "$EXPECTED_SOURCE_COMMIT")
    ;;
esac

[ -n "$BUILD_TARGET" ] && inner_args+=(--build-target "$BUILD_TARGET")
if [ -n "$PATCH_DIRS" ]; then
  container_dirs=""
  for pd in $PATCH_DIRS; do
    container_dirs="$container_dirs $(repo_container_path "$pd")"
  done
  container_dirs="${container_dirs# }"
  inner_args+=(--patch-dirs "$container_dirs")
fi
[ -n "$PATCH_DIR" ] && inner_args+=(--patch-dir "$(repo_container_path "$PATCH_DIR")")
[ -n "$JOBS" ] && inner_args+=(--jobs "$JOBS")
[ -n "$MIN_FREE_GB" ] && inner_args+=(--min-free-gb "$MIN_FREE_GB")
[ "$RESET_SOURCE" = "true" ] && inner_args+=(--reset-source)
[ "$SKIP_CLEAN" = "true" ] && inner_args+=(--skip-clean)

if [ "$RELEASE_BUILD" = "true" ]; then
  release_build_args_text="$(printf '%s\n' "${inner_args[@]}")"
  EXPECTED_RELEASE_BUILD_ARGS_SHA256="$(
    printf '%s\n' "$release_build_args_text" | shasum -a 256 | awk '{print $1}'
  )"
  [[ "$EXPECTED_RELEASE_BUILD_ARGS_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Could not derive the in-memory release build-argument digest." >&2
    exit 1
  }
  if ! printf '%s\n' "$release_build_args_text" |
      create_release_file_exclusive \
        "$BASELINE_CONTROL_DIR" "$BASELINE_CONTROL_IDENTITY" \
        "$BASELINE_CONTROL_FD" \
        docker-build-args.txt 1048576 stdin; then
    echo "Could not exclusively create private release build arguments." >&2
    exit 1
  fi
else
  printf '%s\n' "${inner_args[@]}" > "$args_file"
  chmod 600 "$args_file"
fi

emit_docker_entrypoint() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

artifact_dir=/work/artifacts
control_dir=/work
if [ "${SP11_PRIVATE_SUPPORT_SNAPSHOT:-false}" = "true" ] &&
   [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" != "true" ]; then
  echo "Private release support requires the immutable release control path." >&2
  exit 1
fi
if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" = "true" ]; then
  control_dir=/sp11-control
  if [ ! -r /proc/self/mountinfo ] || [ -L /proc/self/mountinfo ] ||
     ! awk '
       function has_ro(options, count, item) {
         count = split(options, item, ",")
         for (slot = 1; slot <= count; slot++) {
           if (item[slot] == "ro") return 1
         }
         return 0
       }
       $5 == "/repo" {
         repo_count++
         if (has_ro($6)) repo_ro++
         next
       }
       index($5, "/repo/") == 1 { repo_nested++ }
       $5 == "/sp11-control" {
         control_count++
         if (has_ro($6)) control_ro++
         next
       }
       index($5, "/sp11-control/") == 1 { control_nested++ }
       $5 == "/work" {
         work_count++
         if (!has_ro($6)) work_rw++
         next
       }
       index($5, "/work/") == 1 { work_nested++ }
       END {
         exit !(repo_count == 1 && repo_ro == 1 && repo_nested == 0 &&
                control_count == 1 && control_ro == 1 && control_nested == 0 &&
                work_count == 1 && work_rw == 1 && work_nested == 0)
       }
     ' /proc/self/mountinfo; then
    echo "Immutable release build requires exact unshadowed read-only /repo and /sp11-control mounts." >&2
    exit 1
  fi
  [ -d /work ] && [ ! -L /work ] &&
    [ "$(cd /work && pwd -P)" = /work ] || {
      echo "Private release-state volume is not an exact real /work mount." >&2
      exit 1
    }
  if ! release_state_entry="$(
      find /work -mindepth 1 -maxdepth 1 -print -quit
    )"; then
    echo "Could not inspect the private release-state volume exactly." >&2
    exit 1
  fi
  if [ -n "$release_state_entry" ]; then
    echo "Private release-state volume did not start empty." >&2
    exit 1
  fi
  mkdir -m 700 \
    /work/apt-archives /work/apt-indexes /work/apt-lists "$artifact_dir"
  for required_dir in /work /work/apt-archives /work/apt-indexes /work/apt-lists "$artifact_dir"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || {
      echo "Unsafe immutable build directory: $required_dir" >&2
      exit 1
    }
    [ "$(cd "$required_dir" && pwd -P)" = "$required_dir" ] || {
      echo "Non-canonical immutable build directory: $required_dir" >&2
      exit 1
    }
  done
  if ! release_artifact_entry="$(
      find "$artifact_dir" -mindepth 1 -maxdepth 1 -print -quit
    )"; then
    echo "Could not inspect the immutable release artifact directory exactly." >&2
    exit 1
  fi
  if [ -n "$release_artifact_entry" ]; then
    echo "Immutable release artifact directory must start empty." >&2
    exit 1
  fi
  verify_private_control_digest() {
    local path="$1" expected="$2" label="$3" actual

    if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
       [ ! -f "$path" ] || [ -L "$path" ]; then
      echo "Invalid or missing private release control input: $label" >&2
      exit 1
    fi
    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
      echo "Private release control input does not match its expected digest: $label" >&2
      exit 1
    fi
  }
  verify_private_control_digest \
    /sp11-control/docker-build-args.txt \
    "${SP11_EXPECTED_BUILD_ARGS_SHA256:-}" \
    "Docker build arguments"
  verify_private_control_digest \
    /sp11-control/docker-build-inside.sh \
    "${SP11_EXPECTED_ENTRYPOINT_SHA256:-}" \
    "Docker entrypoint"
  verify_private_control_digest \
    /sp11-control/kernel-baseline.env \
    "${SP11_EXPECTED_BASELINE_SHA256:-}" \
    "kernel baseline"
  verify_private_control_digest \
    /sp11-control/sp11-oci-index.json \
    "${SP11_EXPECTED_OCI_INDEX_SHA256:-}" \
    "OCI index"
  install -m 0600 \
    /sp11-control/docker-build-args.txt \
    /work/docker-build-args.txt
  install -m 0600 \
    /sp11-control/docker-build-inside.sh \
    /work/docker-build-inside.sh
  install -m 0600 \
    /sp11-control/sp11-oci-index.json \
    /work/sp11-oci-index.json
else
  echo "Cleaning copied artifact shuttle directory: $artifact_dir"
  rm -rf "$artifact_dir"
  mkdir -p "$artifact_dir"
fi

enable_deb_src() {
  local file tmp

  for file in /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    tmp="$(mktemp)"
    awk '
      /^Types:/ {
        if ($0 !~ /(^|[[:space:]])deb-src([[:space:]]|$)/) {
          $0 = $0 " deb-src"
        }
      }
      { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
  done

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$file" ] || continue
    tmp="$(mktemp)"
    awk '
      /^deb[[:space:]]/ {
        print
        line = $0
        sub(/^deb[[:space:]]/, "deb-src ", line)
        print line
        next
      }
      { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
  done
}

if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" = "true" ]; then
  [ ! -e /tmp/sp11-apt-sources ] || {
    echo "Immutable release build refuses a mutable APT sources mount." >&2
    exit 1
  }
  /repo/scripts/sp11-immutable-apt.sh bootstrap \
    --baseline /sp11-control/kernel-baseline.env \
    --archives-dir /work/apt-archives \
    --index-cache-dir /work/apt-indexes \
    --retained-lists-dir /work/apt-lists \
    --work-dir /work \
    --kernel-work-dir "${SP11_CONTAINER_WORK_DIR:-/linux-work}"
elif [ -f /tmp/sp11-apt-sources ]; then
  case "${SP11_APT_SOURCES_NAME:-sp11-qcom-x1e.sources}" in
    *.sources) install -m 0644 /tmp/sp11-apt-sources /etc/apt/sources.list.d/sp11-qcom-x1e.sources ;;
    *) install -m 0644 /tmp/sp11-apt-sources /etc/apt/sources.list.d/sp11-qcom-x1e.list ;;
  esac
fi

if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" != "true" ] &&
   [ "${SP11_ENABLE_DEB_SRC:-true}" = "true" ]; then
  enable_deb_src
fi

if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" != "true" ]; then
  apt-get update
fi
apt-get install -y --no-install-recommends ca-certificates git dpkg-dev

build_args=()
while IFS= read -r build_arg; do
  build_args+=("$build_arg")
done < "$control_dir/docker-build-args.txt"
/repo/scripts/build-sp11-qcom-x1e-kernel.sh "${build_args[@]}"

find_qcom_kernel_debs() {
  find "$1" -maxdepth 4 -type f \
    \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
    -o -name 'linux-image-*-qcom-x1e_*.deb' \
    -o -name 'linux-modules-*-qcom-x1e_*.deb' \
    -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
    -o -name 'linux-headers-*-qcom-x1e_*.deb' \
    -o -name 'linux-qcom-x1e-headers-*_*.deb' \
    -o -name 'linux-qcom-x1e_*.deb' \
    -o -name 'linux-image-qcom-x1e_*.deb' \
    -o -name 'linux-headers-qcom-x1e_*.deb' \) \
    -print | LC_ALL=C sort -u
}

container_work_dir="${SP11_CONTAINER_WORK_DIR:-/linux-work}"
while IFS= read -r deb; do
  [ -n "$deb" ] || continue
  cp -f "$deb" "$artifact_dir/"
done < <(find_qcom_kernel_debs "$container_work_dir")

for manifest in \
  "$container_work_dir/sp11-kernel-build-manifest.txt" \
  "$container_work_dir/sp11-kernel-debs.txt"; do
  [ -f "$manifest" ] && cp -f "$manifest" "$artifact_dir/"
done

if [ "${SP11_IMMUTABLE_APT_REQUIRED:-false}" = "true" ]; then
  local_build_deps=()
  while IFS= read -r deb; do
    [ -n "$deb" ] && local_build_deps+=("$deb")
  done < <(find "$container_work_dir" -mindepth 1 -maxdepth 1 -type f \
    -name '*-build-deps_*.deb' -print | LC_ALL=C sort)
  if [ "${#local_build_deps[@]}" -ne 1 ]; then
    echo "Immutable release build requires exactly one generated build-deps Deb; found ${#local_build_deps[@]}." >&2
    exit 1
  fi
  cp -f "${local_build_deps[0]}" "$artifact_dir/"
  /repo/scripts/sp11-immutable-apt.sh finalize \
    --baseline /sp11-control/kernel-baseline.env \
    --archives-dir /work/apt-archives \
    --index-cache-dir /work/apt-indexes \
    --retained-lists-dir /work/apt-lists \
    --work-dir /work \
    --kernel-work-dir "$container_work_dir" \
    --output "$artifact_dir/sp11-kernel-apt-provenance.txt"
  build_inputs_args=(
    --baseline /sp11-control/kernel-baseline.env
    --baseline-sha256 "${SP11_EXPECTED_BASELINE_SHA256:-}"
    --build-args-sha256 "${SP11_EXPECTED_BUILD_ARGS_SHA256:-}"
    --entrypoint-sha256 "${SP11_EXPECTED_ENTRYPOINT_SHA256:-}"
    --oci-index-sha256 "${SP11_EXPECTED_OCI_INDEX_SHA256:-}"
    --work-dir /work
    --support-head "${SP11_EXPECTED_SUPPORT_COMMIT:-}"
    --build-args /work/docker-build-args.txt
    --entrypoint /work/docker-build-inside.sh
    --oci-index /work/sp11-oci-index.json
    --build-manifest "$artifact_dir/sp11-kernel-build-manifest.txt"
    --apt-provenance "$artifact_dir/sp11-kernel-apt-provenance.txt"
    --apt-archives-dir /work/apt-archives
    --apt-lists-dir /work/apt-lists
    --apt-index-cache-dir /work/apt-indexes
    --apt-local-build-deps-dir "$artifact_dir"
    --apt-pre-inventory /work/sp11-apt-installed-pre.txt
    --apt-post-inventory /work/sp11-apt-installed-post.txt
    --output "$artifact_dir/sp11-kernel-build-inputs.txt"
  )
  /usr/bin/python3 -I /repo/scripts/sp11-kernel-build-inputs.py write \
    "${build_inputs_args[@]}"
  validation_attestation_args=(
    --apt-bootstrap-state /work/sp11-apt-bootstrap-state.txt
    --attestation-output /work/sp11-kernel-preseal-validation.txt
    --git-object-format "${SP11_EXPECTED_GIT_OBJECT_FORMAT:-}"
    --build-inputs-helper-sha256 \
      "${SP11_EXPECTED_BUILD_INPUTS_HELPER_SHA256:-}"
    --build-inputs-helper-object-id \
      "${SP11_EXPECTED_BUILD_INPUTS_HELPER_OBJECT_ID:-}"
    --manifest-validator-sha256 \
      "${SP11_EXPECTED_MANIFEST_VALIDATOR_SHA256:-}"
    --manifest-validator-object-id \
      "${SP11_EXPECTED_MANIFEST_VALIDATOR_OBJECT_ID:-}"
  )
  /usr/bin/python3 -I /repo/scripts/sp11-kernel-build-inputs.py validate \
    "${build_inputs_args[@]}" "${validation_attestation_args[@]}"
  /usr/bin/python3 -I /repo/scripts/sp11-kernel-release-state.py seal \
    --work-root /work \
    --support-head "${SP11_EXPECTED_SUPPORT_COMMIT:-}" \
    --baseline-sha256 "${SP11_EXPECTED_BASELINE_SHA256:-}" \
    --build-args-sha256 "${SP11_EXPECTED_BUILD_ARGS_SHA256:-}" \
    --entrypoint-sha256 "${SP11_EXPECTED_ENTRYPOINT_SHA256:-}" \
    --oci-index-sha256 "${SP11_EXPECTED_OCI_INDEX_SHA256:-}" \
    --container-image "${SP11_BUILD_CONTAINER_IMAGE:-}" \
    --container-platform "${SP11_BUILD_CONTAINER_PLATFORM:-}" \
    --git-object-format "${SP11_EXPECTED_GIT_OBJECT_FORMAT:-}" \
    --validator-argv-sha256 "${SP11_EXPECTED_VALIDATOR_ARGV_SHA256:-}" \
    --build-inputs-helper-size \
      "${SP11_EXPECTED_BUILD_INPUTS_HELPER_SIZE:-}" \
    --build-inputs-helper-sha256 \
      "${SP11_EXPECTED_BUILD_INPUTS_HELPER_SHA256:-}" \
    --build-inputs-helper-object-id \
      "${SP11_EXPECTED_BUILD_INPUTS_HELPER_OBJECT_ID:-}" \
    --manifest-validator-size \
      "${SP11_EXPECTED_MANIFEST_VALIDATOR_SIZE:-}" \
    --manifest-validator-sha256 \
      "${SP11_EXPECTED_MANIFEST_VALIDATOR_SHA256:-}" \
    --manifest-validator-object-id \
      "${SP11_EXPECTED_MANIFEST_VALIDATOR_OBJECT_ID:-}"
fi
EOF
}
docker_entrypoint_text="$(emit_docker_entrypoint)"
if [ "$RELEASE_BUILD" = "true" ]; then
  EXPECTED_RELEASE_ENTRYPOINT_SHA256="$(
    printf '%s\n' "$docker_entrypoint_text" | shasum -a 256 | awk '{print $1}'
  )"
  [[ "$EXPECTED_RELEASE_ENTRYPOINT_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Could not derive the in-memory release entrypoint digest." >&2
    exit 1
  }
  release_validator_argv=(
    /usr/bin/python3
    -I
    /repo/scripts/sp11-kernel-build-inputs.py
    validate
    --baseline /sp11-control/kernel-baseline.env
    --baseline-sha256 "$KERNEL_BASELINE_SHA256"
    --build-args-sha256 "$EXPECTED_RELEASE_BUILD_ARGS_SHA256"
    --entrypoint-sha256 "$EXPECTED_RELEASE_ENTRYPOINT_SHA256"
    --oci-index-sha256 "$RELEASE_OCI_INDEX_SHA256"
    --work-dir /work
    --support-head "$SUPPORT_HEAD_START"
    --build-args /work/docker-build-args.txt
    --entrypoint /work/docker-build-inside.sh
    --oci-index /work/sp11-oci-index.json
    --build-manifest /work/artifacts/sp11-kernel-build-manifest.txt
    --apt-provenance /work/artifacts/sp11-kernel-apt-provenance.txt
    --apt-archives-dir /work/apt-archives
    --apt-lists-dir /work/apt-lists
    --apt-index-cache-dir /work/apt-indexes
    --apt-local-build-deps-dir /work/artifacts
    --apt-pre-inventory /work/sp11-apt-installed-pre.txt
    --apt-post-inventory /work/sp11-apt-installed-post.txt
    --output /work/artifacts/sp11-kernel-build-inputs.txt
    --apt-bootstrap-state /work/sp11-apt-bootstrap-state.txt
    --attestation-output /work/sp11-kernel-preseal-validation.txt
    --git-object-format "$RELEASE_GIT_OBJECT_FORMAT"
    --build-inputs-helper-sha256 "$RELEASE_BUILD_INPUTS_HELPER_SHA256"
    --build-inputs-helper-object-id "$RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID"
    --manifest-validator-sha256 "$RELEASE_MANIFEST_VALIDATOR_SHA256"
    --manifest-validator-object-id "$RELEASE_MANIFEST_VALIDATOR_OBJECT_ID"
  )
  RELEASE_VALIDATOR_ARGV_SHA256="$(
    "$RELEASE_PYTHON_BIN" -I -c '
import hashlib
import sys

arguments = sys.argv[1:]
if not 4 <= len(arguments) <= 128:
    raise SystemExit(1)
digest = hashlib.sha256()
for argument in arguments:
    encoded = argument.encode("ascii")
    if not encoded or len(encoded) > 8192 or b"\0" in encoded:
        raise SystemExit(1)
    digest.update(encoded)
    digest.update(b"\0")
print(digest.hexdigest())
' sp11-validator-vector "${release_validator_argv[@]}"
  )" || {
    echo "Could not derive the exact pre-seal validator argv digest." >&2
    exit 1
  }
  [[ "$RELEASE_VALIDATOR_ARGV_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Pre-seal validator argv digest is not canonical." >&2
    exit 1
  }
fi
if [ "$RELEASE_BUILD" = "true" ]; then
  if ! printf '%s\n' "$docker_entrypoint_text" |
      create_release_file_exclusive \
        "$BASELINE_CONTROL_DIR" "$BASELINE_CONTROL_IDENTITY" \
        "$BASELINE_CONTROL_FD" \
        docker-build-inside.sh 4194304 stdin; then
    echo "Could not exclusively create the private release entrypoint." >&2
    exit 1
  fi
else
  printf '%s\n' "$docker_entrypoint_text" > "$run_script"
  chmod 700 "$run_script"
fi
unset -f emit_docker_entrypoint

if [ "$RELEASE_BUILD" = "true" ]; then
  RELEASE_BUILD_ARGS_STATE="$(baseline_control_file_state "$args_file")" || {
    echo "Private release build arguments were unsafe or unstable at first capture." >&2
    exit 1
  }
  RELEASE_BUILD_ARGS_SHA256="${RELEASE_BUILD_ARGS_STATE##*:}"
  if [ "$RELEASE_BUILD_ARGS_SHA256" != "$EXPECTED_RELEASE_BUILD_ARGS_SHA256" ]; then
    echo "Private release build arguments differ from their in-memory authority." >&2
    exit 1
  fi
  RELEASE_ENTRYPOINT_STATE="$(baseline_control_file_state "$run_script")" || {
    echo "Private release entrypoint was unsafe or unstable at first capture." >&2
    exit 1
  }
  RELEASE_ENTRYPOINT_SHA256="${RELEASE_ENTRYPOINT_STATE##*:}"
  if [ "$RELEASE_ENTRYPOINT_SHA256" != "$EXPECTED_RELEASE_ENTRYPOINT_SHA256" ]; then
    echo "Private release entrypoint differs from its in-memory authority." >&2
    exit 1
  fi
  if [ -f "$oci_index_file" ] && [ ! -L "$oci_index_file" ]; then
    if [ "$(baseline_control_file_state "$oci_index_file")" != "$RELEASE_OCI_INDEX_STATE" ] ||
       [ "$RELEASE_OCI_INDEX_SHA256" != "$EXPECTED_RELEASE_OCI_INDEX_SHA256" ]; then
      echo "Private OCI index changed after its pinned semantic validation." >&2
      exit 1
    fi
  fi
  BASELINE_CONTROL_FINAL_STATE="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" || exit 1
  verify_release_control_state || exit 1
fi

if ! validate_legacy_control_paths; then
  exit 1
fi
if [ "$RELEASE_BUILD" = "true" ]; then
  if ! install_control_evidence_copy "$args_file" "$work_abs/docker-build-args.txt" ||
     ! install_control_evidence_copy "$run_script" "$work_abs/docker-build-inside.sh"; then
    exit 1
  fi
  if [ "$IMMUTABLE_APT" = "true" ] && [ "$DRY_RUN" != "true" ] &&
     ! install_control_evidence_copy "$oci_index_file" "$work_abs/sp11-oci-index.json"; then
    exit 1
  fi
  verify_release_control_state || exit 1
  verify_release_work_root_prebuild_membership || exit 1
else
  if ! install_control_file "$args_file" "$work_abs/docker-build-args.txt" ||
     ! install_control_file "$run_script" "$work_abs/docker-build-inside.sh"; then
    exit 1
  fi
  if [ "$IMMUTABLE_APT" = "true" ] && [ "$DRY_RUN" != "true" ] &&
     ! install_control_file "$oci_index_file" "$work_abs/sp11-oci-index.json"; then
    exit 1
  fi
  cleanup_control_dir
  CONTROL_DIR=""
fi

docker_args=(
  run
  --platform "$PLATFORM"
  -e "SP11_ENABLE_DEB_SRC=$ENABLE_DEB_SRC"
  -e "SP11_APT_SOURCES_NAME=$(basename "${APT_SOURCES_FILE:-sp11-qcom-x1e.sources}")"
  -e "SP11_BUILD_CONTAINER_IMAGE=$IMAGE"
  -e "SP11_BUILD_CONTAINER_PLATFORM=$PLATFORM"
  -e "SP11_CONTAINER_WORK_DIR=$CONTAINER_WORK_DIR"
)

if [ "$RELEASE_BUILD" = "true" ]; then
  [ -n "$COMMITTED_SUPPORT_DIR" ] || {
    echo "Release Docker run is missing its private committed support checkout." >&2
    exit 1
  }
  if [ "$DRY_RUN" = "true" ]; then
    RELEASE_STATE_VOLUME_NAME="sp11-release-state-dry-run"
  else
    RELEASE_STATE_VOLUME_TOKEN="$("$RELEASE_PYTHON_BIN" -I -c \
      'import secrets; print(secrets.token_hex(32))')"
    RELEASE_STATE_VOLUME_NAME="sp11-release-state-${RELEASE_STATE_VOLUME_TOKEN:0:32}"
  fi
  [[ "$RELEASE_STATE_VOLUME_NAME" =~ ^sp11-release-state-[0-9a-f]{32}$ ]] ||
    [ "$RELEASE_STATE_VOLUME_NAME" = "sp11-release-state-dry-run" ] || {
      echo "Could not derive a private Docker release-state volume name." >&2
      exit 1
    }
  if [ "$DRY_RUN" != "true" ]; then
    [[ "$RELEASE_STATE_VOLUME_TOKEN" =~ ^[0-9a-f]{64}$ ]] || exit 1
    export RELEASE_STATE_VOLUME_TOKEN
    if ! release_volume_created="$(run_release_command_bounded 4096 \
        "$DOCKER_BIN" volume create \
        --label "org.opencontainers.image.vendor=linux-surface-pro-11-oe" \
        --label "org.sp11.release-state-token=$RELEASE_STATE_VOLUME_TOKEN" \
        "$RELEASE_STATE_VOLUME_NAME")" ||
       [ "$release_volume_created" != "$RELEASE_STATE_VOLUME_NAME" ] ||
       ! release_volume_inspected="$(run_release_command_bounded 4096 \
          "$DOCKER_BIN" volume inspect --format \
          '{{.Name}} {{index .Labels "org.sp11.release-state-token"}}' \
          "$RELEASE_STATE_VOLUME_NAME")" ||
       [ "$release_volume_inspected" != \
         "$RELEASE_STATE_VOLUME_NAME $RELEASE_STATE_VOLUME_TOKEN" ]; then
      echo "Could not create and bind the private Docker release-state volume." >&2
      exit 1
    fi
  fi
  docker_args+=(
    --mount \
      "type=volume,source=$RELEASE_STATE_VOLUME_NAME,destination=/work,volume-nocopy"
    -e "SP11_EXPECTED_SUPPORT_COMMIT=$SUPPORT_HEAD_START"
    -e "SP11_PRIVATE_SUPPORT_SNAPSHOT=true"
    -e "SP11_EXPECTED_BUILD_ARGS_SHA256=$RELEASE_BUILD_ARGS_SHA256"
    -e "SP11_EXPECTED_ENTRYPOINT_SHA256=$RELEASE_ENTRYPOINT_SHA256"
    -e "SP11_EXPECTED_BASELINE_SHA256=$KERNEL_BASELINE_SHA256"
    -e "SP11_EXPECTED_GIT_OBJECT_FORMAT=$RELEASE_GIT_OBJECT_FORMAT"
    -e "SP11_EXPECTED_VALIDATOR_ARGV_SHA256=$RELEASE_VALIDATOR_ARGV_SHA256"
    -e "SP11_EXPECTED_BUILD_INPUTS_HELPER_SIZE=$RELEASE_BUILD_INPUTS_HELPER_SIZE"
    -e "SP11_EXPECTED_BUILD_INPUTS_HELPER_SHA256=$RELEASE_BUILD_INPUTS_HELPER_SHA256"
    -e "SP11_EXPECTED_BUILD_INPUTS_HELPER_OBJECT_ID=$RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID"
    -e "SP11_EXPECTED_MANIFEST_VALIDATOR_SIZE=$RELEASE_MANIFEST_VALIDATOR_SIZE"
    -e "SP11_EXPECTED_MANIFEST_VALIDATOR_SHA256=$RELEASE_MANIFEST_VALIDATOR_SHA256"
    -e "SP11_EXPECTED_MANIFEST_VALIDATOR_OBJECT_ID=$RELEASE_MANIFEST_VALIDATOR_OBJECT_ID"
    -v "$COMMITTED_SUPPORT_DIR:/repo:ro"
    -v "$BASELINE_CONTROL_DIR:/sp11-control:ro"
  )
  if [ -n "$RELEASE_OCI_INDEX_SHA256" ]; then
    docker_args+=(-e "SP11_EXPECTED_OCI_INDEX_SHA256=$RELEASE_OCI_INDEX_SHA256")
  fi
else
  docker_args+=(--rm -v "$work_abs:/work" -v "$repo_dir:/repo:ro")
fi
if [ "$IMMUTABLE_APT" = "true" ]; then
  docker_args+=(-e "SP11_IMMUTABLE_APT_REQUIRED=true")
fi

if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
  docker_args+=(-v "$LINUX_WORK_VOLUME:$CONTAINER_WORK_DIR")
fi

if [ -n "$APT_SOURCES_FILE" ]; then
  docker_args+=(-v "$APT_SOURCES_FILE:/tmp/sp11-apt-sources:ro")
fi

if [ "$RELEASE_BUILD" = "true" ]; then
  docker_args+=("$IMAGE" bash /sp11-control/docker-build-inside.sh)
else
  docker_args+=("$IMAGE" /work/docker-build-inside.sh)
fi

if [ "$DRY_RUN" = "true" ]; then
  if [ "$RELEASE_BUILD" = "true" ]; then
    printf 'Docker command:\n  docker create'
    printf ' %q' "${docker_args[@]:1}"
  else
    printf 'Docker command:\n  docker'
    printf ' %q' "${docker_args[@]}"
  fi
  printf '\n\nInner build args:\n'
  printf '  %s\n' "${inner_args[@]}"
  verify_release_control_state
  verify_release_support_stable
  verify_release_work_root_binding
  exit 0
fi

if [ "$CONTAINER_WORK_DIR" = "/work" ] &&
  [ "$SOURCE_MODE" = "apt" ] && [ "$RESET_SOURCE" != "true" ] &&
  [ -d "$work_abs/source" ] &&
  find "$work_abs/source" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
  echo "Existing apt source directories found under $work_abs/source." >&2
  echo "Rerun with --reset-source to avoid restarting Docker only to fail inside the container." >&2
  exit 1
fi

capture_docker_control_state
verify_release_control_state
verify_release_support_checkout
verify_release_work_root_binding
capture_release_companion_import_identities
set +e
if [ "$RELEASE_BUILD" = "true" ]; then
  verify_release_python_authority || exit 1
  run_bound_release_support_python \
    scripts/sp11-kernel-release-state.py 4194304 \
    "$RELEASE_STATE_HELPER_IDENTITY" "$RELEASE_STATE_HELPER_SHA256" \
    "$RELEASE_STATE_HELPER_OBJECT_ID" "$RELEASE_STATE_HELPER_MODE" \
    run-container \
    --docker-path "$DOCKER_BIN" \
    -- "$DOCKER_BIN" create "${docker_args[@]:1}"
else
  docker "${docker_args[@]}"
fi
docker_status=$?
set -e
verify_release_control_state
verify_release_support_checkout
verify_release_work_root_binding
if [ "$docker_status" -ne 0 ]; then
  echo "Docker kernel build failed; inspect the log above for the first build error." >&2
  echo "If the source tree was partially prepared, rerun with --reset-source after fixing the failure." >&2
  exit "$docker_status"
fi

verify_docker_control_state
verify_release_support_stable

if [ "$RELEASE_BUILD" = "true" ]; then
  release_exporter_args=(
    "$DOCKER_BIN"
    create
    --pull=never
    --network none
    --read-only
    --cap-drop ALL
    --security-opt no-new-privileges
    --pids-limit 64
    --user 0:0
    --platform "$PLATFORM"
    --mount \
      "type=volume,source=$RELEASE_STATE_VOLUME_NAME,destination=/work,readonly"
    -v "$COMMITTED_SUPPORT_DIR:/repo:ro"
    --entrypoint /bin/bash
    "$IMAGE"
    /repo/scripts/emit-sp11-kernel-release-state.sh
  )
  [ "${#WORK_ROOT_IMPORT_IDENTITY[@]}" -eq 5 ] &&
    [ "${#RELEASE_ARTIFACTS_IMPORT_IDENTITY[@]}" -eq 5 ] &&
    [ "${#RELEASE_BUILD_ARGS_IMPORT_IDENTITY[@]}" -eq 9 ] &&
    [ "${#RELEASE_ENTRYPOINT_IMPORT_IDENTITY[@]}" -eq 9 ] &&
    [ "${#RELEASE_OCI_INDEX_IMPORT_IDENTITY[@]}" -eq 9 ] || {
      echo "Release import identities are incomplete before publication." >&2
      exit 1
    }
  verify_release_control_state
  verify_release_support_checkout
  verify_release_python_authority || exit 1
  verify_release_work_root_binding
  # import-tar is the terminal commit boundary. It owns exporter supervision,
  # held publication authority, output scrubbing, the final collective recheck,
  # signal disposition, and the only post-commit success output.  Remove the
  # shell EXIT hook before replacing this process so Bash can never turn its
  # committed success into a later false failure.
  trap - EXIT
  exec_bound_release_support_python \
    scripts/sp11-kernel-release-state.py 4194304 \
    "$RELEASE_STATE_HELPER_IDENTITY" "$RELEASE_STATE_HELPER_SHA256" \
    "$RELEASE_STATE_HELPER_OBJECT_ID" "$RELEASE_STATE_HELPER_MODE" \
    import-tar \
    --work-root "$work_abs" \
    --work-root-identity "${WORK_ROOT_IMPORT_IDENTITY[@]}" \
    --artifacts-root "$work_abs/artifacts" \
    --artifacts-root-identity "${RELEASE_ARTIFACTS_IMPORT_IDENTITY[@]}" \
    --container-platform "$PLATFORM" \
    --build-args-identity "${RELEASE_BUILD_ARGS_IMPORT_IDENTITY[@]}" \
    --entrypoint-identity "${RELEASE_ENTRYPOINT_IMPORT_IDENTITY[@]}" \
    --oci-index-identity "${RELEASE_OCI_INDEX_IMPORT_IDENTITY[@]}" \
    --docker-path "$DOCKER_BIN" \
    --support-head "$SUPPORT_HEAD_START" \
    --baseline-sha256 "$KERNEL_BASELINE_SHA256" \
    --build-args-sha256 "$RELEASE_BUILD_ARGS_SHA256" \
    --entrypoint-sha256 "$RELEASE_ENTRYPOINT_SHA256" \
    --oci-index-sha256 "$RELEASE_OCI_INDEX_SHA256" \
    --container-image "$IMAGE" \
    --git-object-format "$RELEASE_GIT_OBJECT_FORMAT" \
    --validator-argv-sha256 "$RELEASE_VALIDATOR_ARGV_SHA256" \
    --build-inputs-helper-size "$RELEASE_BUILD_INPUTS_HELPER_SIZE" \
    --build-inputs-helper-sha256 "$RELEASE_BUILD_INPUTS_HELPER_SHA256" \
    --build-inputs-helper-object-id "$RELEASE_BUILD_INPUTS_HELPER_OBJECT_ID" \
    --manifest-validator-size "$RELEASE_MANIFEST_VALIDATOR_SIZE" \
    --manifest-validator-sha256 "$RELEASE_MANIFEST_VALIDATOR_SHA256" \
    --manifest-validator-object-id "$RELEASE_MANIFEST_VALIDATOR_OBJECT_ID" \
    --retained-volume-name "$RELEASE_STATE_VOLUME_NAME" \
    -- "${release_exporter_args[@]}"
fi

echo
echo "Docker host control/artifact directory: $work_abs"
if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
  echo "Docker Linux work volume: $LINUX_WORK_VOLUME mounted at $CONTAINER_WORK_DIR"
  echo "Generated package artifacts copied under: $work_abs/artifacts"
  generated_debs="$(find_qcom_kernel_debs "$work_abs/artifacts")"
else
  echo "Generated qcom-x1e kernel packages under: $work_abs"
  generated_debs="$(find_qcom_kernel_debs "$work_abs")"
fi
if [ -n "$generated_debs" ]; then
  printf '%s\n' "$generated_debs"
else
  echo "No qcom-x1e kernel packages found."
fi

if [ "$COPY_TO_PAYLOAD" = "true" ]; then
  if [ -z "$generated_debs" ]; then
    echo "Cannot copy to payload because no qcom-x1e kernel packages were found." >&2
    exit 1
  fi
  if ! create_validated_payload_dir || ! validate_payload_dir "$PAYLOAD_DIR"; then
    exit 1
  fi
  if ! payload_invalid_entries="$(find "$payload_abs" -maxdepth 1 -name '*.deb' ! -type f -print)"; then
    echo "Could not inspect --payload-dir safely: $payload_abs" >&2
    exit 1
  fi
  if [ -n "$payload_invalid_entries" ]; then
    echo "Refusing non-regular or symlinked .deb entries in --payload-dir: $payload_abs" >&2
    exit 1
  fi

  PAYLOAD_STAGE="$(mktemp -d "$payload_abs/.sp11-kernel-debs.XXXXXX")"
  chmod 700 "$PAYLOAD_STAGE"
  if [ -L "$PAYLOAD_STAGE" ] || [ ! -d "$PAYLOAD_STAGE" ]; then
    echo "Could not create a private payload staging directory safely." >&2
    exit 1
  fi

  while IFS= read -r deb; do
    deb_name=""
    [ -n "$deb" ] || continue
    deb_name="$(basename "$deb")"
    case "$deb_name" in
      ""|.|..|*/*)
        echo "Unsafe generated package basename: $deb" >&2
        exit 1
        ;;
    esac
    if [ -e "$PAYLOAD_STAGE/$deb_name" ] || [ -L "$PAYLOAD_STAGE/$deb_name" ]; then
      echo "Generated packages contain a duplicate basename: $deb_name" >&2
      exit 1
    fi
    if ! cp "$deb" "$PAYLOAD_STAGE/$deb_name" ||
       ! chmod 644 "$PAYLOAD_STAGE/$deb_name"; then
      exit 1
    fi
  done <<<"$generated_debs"

  # Revalidate after staging, then prune only once every replacement package is
  # safely present on the destination filesystem.
  if ! validate_payload_dir "$PAYLOAD_DIR" ||
     ! payload_invalid_entries="$(find "$payload_abs" -maxdepth 1 -name '*.deb' ! -type f -print)"; then
    echo "Could not revalidate --payload-dir before committing packages." >&2
    exit 1
  fi
  if [ -n "$payload_invalid_entries" ]; then
    echo "Refusing non-regular or symlinked .deb entries in --payload-dir: $payload_abs" >&2
    exit 1
  fi

  find "$payload_abs" -maxdepth 1 -type f -name '*.deb' -exec rm -f -- {} +
  while IFS= read -r staged_deb; do
    [ -n "$staged_deb" ] || continue
    deb_name="$(basename "$staged_deb")"
    if [ -e "$payload_abs/$deb_name" ] || [ -L "$payload_abs/$deb_name" ]; then
      echo "Payload package destination changed during commit: $deb_name" >&2
      exit 1
    fi
    mv "$staged_deb" "$payload_abs/$deb_name"
  done < <(find "$PAYLOAD_STAGE" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print | LC_ALL=C sort)
  rmdir "$PAYLOAD_STAGE"
  PAYLOAD_STAGE=""
  echo
  echo "Copied generated qcom-x1e .deb files to: $payload_abs"
  echo "Rebuild the live USB image so payload/kernel-debs is available on SP11DATA."
fi

# This is intentionally the final release-mode operation. The host-side APT
# envelope and any requested payload copy cannot make a changed support tree
# acceptable after its recorded HEAD and generated controls were validated.
verify_docker_control_state
verify_release_support_stable
