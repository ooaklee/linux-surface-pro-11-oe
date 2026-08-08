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
RELEASE_WORK_DIR_NAMES=()
RELEASE_WORK_DIR_IDENTITIES=()
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
KERNEL_BASELINE_REL="config/kernel-baselines/7.2-rc5-jg-0.env"
KERNEL_BASELINE_VALIDATOR_REL="scripts/validate-sp11-kernel-baseline.sh"
BASELINE_CONTROL_DIR=""
BASELINE_CONTROL_PARENT=""
BASELINE_CONTROL_IDENTITY=""
BASELINE_CONTROL_INITIAL_STATE=""
BASELINE_CONTROL_FINAL_STATE=""
KERNEL_BASELINE_VALIDATOR=""
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
SUPPORT_SNAPSHOT_ROOT=""
SUPPORT_SNAPSHOT_PARENT=""
SUPPORT_SNAPSHOT_ROOT_IDENTITY=""
SUPPORT_SNAPSHOT_ROOT_STATE=""
COMMITTED_SUPPORT_DIR=""
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
  current="$(baseline_control_file_state "$KERNEL_BASELINE_VALIDATOR")" || {
    echo "Committed kernel baseline validator snapshot is missing, unsafe, or unstable." >&2
    return 1
  }
  if [ "$current" != "$KERNEL_BASELINE_VALIDATOR_STATE" ]; then
    echo "Committed kernel baseline validator snapshot changed after materialization." >&2
    return 1
  fi
}

verify_initial_baseline_control_state() {
  local current_directory_state

  [ "$RELEASE_BUILD" = "true" ] || return 0
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
}

cleanup_baseline_control_dir() {
  local current_identity baseline_control_file
  local expected_baseline_control_state current_baseline_control_state
  local expected_directory_state current_directory_state membership_phase

  [ -n "$BASELINE_CONTROL_DIR" ] || return 0
  case "$BASELINE_CONTROL_DIR" in
    "$BASELINE_CONTROL_PARENT"/sp11-kernel-baseline.*) ;;
    *)
      echo "warning: refusing to clean unexpected kernel baseline control directory: $BASELINE_CONTROL_DIR" >&2
      return 0
      ;;
  esac
  if [ "$(dirname "$BASELINE_CONTROL_DIR")" != "$BASELINE_CONTROL_PARENT" ] ||
     [ ! -d "$BASELINE_CONTROL_DIR" ] || [ -L "$BASELINE_CONTROL_DIR" ]; then
    echo "warning: refusing to follow changed kernel baseline control directory: $BASELINE_CONTROL_DIR" >&2
    return 0
  fi
  if ! current_identity="$(baseline_control_identity "$BASELINE_CONTROL_DIR")" ||
     [ "$current_identity" != "$BASELINE_CONTROL_IDENTITY" ]; then
    echo "warning: refusing to clean replaced kernel baseline control directory: $BASELINE_CONTROL_DIR" >&2
    return 0
  fi
  if [ -n "$BASELINE_CONTROL_FINAL_STATE" ]; then
    expected_directory_state="$BASELINE_CONTROL_FINAL_STATE"
    membership_phase=final
  else
    expected_directory_state="$BASELINE_CONTROL_INITIAL_STATE"
    membership_phase=initial
  fi
  if [ -z "$expected_directory_state" ] ||
     ! current_directory_state="$(baseline_control_directory_state "$BASELINE_CONTROL_DIR")" ||
     [ "$current_directory_state" != "$expected_directory_state" ] ||
     ! verify_baseline_control_membership "$membership_phase"; then
    echo "warning: preserving changed private release control directory: $BASELINE_CONTROL_DIR" >&2
    return 0
  fi
  if [ "$membership_phase" = final ] && ! verify_release_control_state; then
    echo "warning: preserving drifted private release control directory: $BASELINE_CONTROL_DIR" >&2
    return 0
  fi
  for baseline_control_file in \
    "$BASELINE_CONTROL_DIR/kernel-baseline.env" \
    "$BASELINE_CONTROL_DIR/validate-sp11-kernel-baseline.sh" \
    "$BASELINE_CONTROL_DIR/docker-build-args.txt" \
    "$BASELINE_CONTROL_DIR/docker-build-inside.sh" \
    "$BASELINE_CONTROL_DIR/sp11-oci-index.json"; do
    case "$baseline_control_file" in
      "$KERNEL_BASELINE") expected_baseline_control_state="$KERNEL_BASELINE_STATE" ;;
      "$KERNEL_BASELINE_VALIDATOR") expected_baseline_control_state="$KERNEL_BASELINE_VALIDATOR_STATE" ;;
      */docker-build-args.txt) expected_baseline_control_state="$RELEASE_BUILD_ARGS_STATE" ;;
      */docker-build-inside.sh) expected_baseline_control_state="$RELEASE_ENTRYPOINT_STATE" ;;
      */sp11-oci-index.json) expected_baseline_control_state="$RELEASE_OCI_INDEX_STATE" ;;
    esac
    [ -n "$expected_baseline_control_state" ] || continue
    if current_baseline_control_state="$(baseline_control_file_state "$baseline_control_file" 2>/dev/null)" &&
       [ "$current_baseline_control_state" = "$expected_baseline_control_state" ]; then
      if ! rm -f -- "$baseline_control_file"; then
        echo "warning: preserving remainder after private control cleanup failed: $baseline_control_file" >&2
        return 0
      fi
    else
      echo "warning: preserving changed kernel baseline control file: $baseline_control_file" >&2
      return 0
    fi
  done
  if [ ! -d "$BASELINE_CONTROL_DIR" ] || [ -L "$BASELINE_CONTROL_DIR" ] ||
     ! current_identity="$(baseline_control_identity "$BASELINE_CONTROL_DIR")" ||
     [ "$current_identity" != "$BASELINE_CONTROL_IDENTITY" ] ||
     find "$BASELINE_CONTROL_DIR" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    echo "warning: preserving changed private control directory after file cleanup: $BASELINE_CONTROL_DIR" >&2
    return 0
  fi
  if ! rmdir "$BASELINE_CONTROL_DIR"; then
    echo "warning: could not remove emptied private release control directory: $BASELINE_CONTROL_DIR" >&2
  fi
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
  local safe_support_dir

  safe_support_dir="$(cd "$COMMITTED_SUPPORT_DIR" && pwd -P)" || return 1
  GIT_OPTIONAL_LOCKS=0 git \
    -c "safe.directory=$safe_support_dir" \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -C "$COMMITTED_SUPPORT_DIR" "$@"
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
}

cleanup_release_support_checkout() {
  local index path current_state current_identity

  [ -n "$SUPPORT_SNAPSHOT_ROOT" ] || return 0
  case "$SUPPORT_SNAPSHOT_ROOT" in
    "$SUPPORT_SNAPSHOT_PARENT"/sp11-kernel-support.*) ;;
    *)
      echo "warning: preserving unexpected private support snapshot path: $SUPPORT_SNAPSHOT_ROOT" >&2
      return 0
      ;;
  esac
  if ! verify_release_support_checkout; then
    echo "warning: preserving changed private committed support snapshot: $SUPPORT_SNAPSHOT_ROOT" >&2
    return 0
  fi
  index=$((${#SUPPORT_SNAPSHOT_PATHS[@]} - 1))
  while [ "$index" -ge 0 ]; do
    path="$SUPPORT_SNAPSHOT_ROOT/${SUPPORT_SNAPSHOT_PATHS[$index]}"
    case "${SUPPORT_SNAPSHOT_TYPES[$index]}" in
      file)
        if ! current_state="$(baseline_control_file_state "$path")" ||
           [ "$current_state" != "${SUPPORT_SNAPSHOT_STATES[$index]}" ] ||
           ! current_identity="$(baseline_control_identity "$path")" ||
           [ "$current_identity" != "${SUPPORT_SNAPSHOT_NODE_IDENTITIES[$index]}" ]; then
          echo "warning: preserving private support snapshot after file drift at cleanup: $path" >&2
          return 0
        fi
        if ! rm -f -- "$path"; then
          echo "warning: preserving remainder after private support file cleanup failed: $path" >&2
          return 0
        fi
        ;;
      directory)
        if [ ! -d "$path" ] || [ -L "$path" ] ||
           ! current_identity="$(baseline_control_identity "$path")" ||
           [ "$current_identity" != "${SUPPORT_SNAPSHOT_NODE_IDENTITIES[$index]}" ]; then
          echo "warning: preserving private support snapshot after directory drift at cleanup: $path" >&2
          return 0
        fi
        if ! rmdir "$path"; then
          echo "warning: preserving remainder after private support directory cleanup failed: $path" >&2
          return 0
        fi
        ;;
    esac
    index=$((index - 1))
  done
  if [ ! -d "$SUPPORT_SNAPSHOT_ROOT" ] || [ -L "$SUPPORT_SNAPSHOT_ROOT" ] ||
     ! current_identity="$(baseline_control_identity "$SUPPORT_SNAPSHOT_ROOT")" ||
     [ "$current_identity" != "$SUPPORT_SNAPSHOT_ROOT_IDENTITY" ] ||
     find "$SUPPORT_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    echo "warning: preserving changed private support snapshot root after child cleanup: $SUPPORT_SNAPSHOT_ROOT" >&2
    return 0
  fi
  if ! rmdir "$SUPPORT_SNAPSHOT_ROOT"; then
    echo "warning: could not remove emptied private support snapshot root: $SUPPORT_SNAPSHOT_ROOT" >&2
  fi
}

trap 'cleanup_baseline_control_dir; cleanup_release_support_checkout; cleanup_control_dir; cleanup_payload_stage' EXIT

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
  current_identity="$(baseline_control_identity .)" || return 1
  if [ "$current_identity" != "$WORK_ROOT_IDENTITY" ] ||
     [ ! -d "$work_abs" ] || [ -L "$work_abs" ] ||
     [ "$(baseline_control_identity "$work_abs")" != "$WORK_ROOT_IDENTITY" ]; then
    echo "Release work root changed from its pinned directory." >&2
    return 1
  fi
}

capture_release_work_root_identity() {
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
  local index name current_identity

  index=0
  while [ "$index" -lt "${#RELEASE_WORK_DIR_NAMES[@]}" ]; do
    name="${RELEASE_WORK_DIR_NAMES[$index]}"
    case "$name" in
      apt-archives|apt-indexes|apt-lists|artifacts) ;;
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
    index=$((index + 1))
  done
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

    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
      echo "Release Docker evidence path is unsafe: $display_target" >&2
      exit 1
    fi
    source_state="$(baseline_control_file_state "$source")" || {
      echo "Private Docker control input is unsafe before evidence copy: $source" >&2
      exit 1
    }
    if [ -e "$target" ]; then
      installed_state="$(baseline_control_file_state "$target")" || exit 1
      if [ "${installed_state##*:}" != "${source_state##*:}" ]; then
        echo "Existing release Docker evidence differs from its private authority: $display_target" >&2
        exit 1
      fi
    else
      if ! (
        set -o noclobber
        umask 077
        cat "$source" > "$target" || exit 1
      ); then
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
  (
    cd "$SUPPORT_SNAPSHOT_ROOT"
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
      if [ -e ./.git/objects/info/alternates ] ||
         { [ -d ./.git/hooks ] &&
           find ./.git/hooks -mindepth 1 -print | grep -q .; }; then
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
      if find . -path ./.git -prune -o -type d -empty -print | grep -q .; then
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

  [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
    echo "Refusing an existing committed-support snapshot path: $destination" >&2
    return 1
  }
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
  if ! (
    set -o noclobber
    umask 077
    committed_support_git cat-file blob "$object_id" > "$destination" || exit 1
  ); then
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
  local created_dir root_mode

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
  KERNEL_BASELINE="$BASELINE_CONTROL_DIR/kernel-baseline.env"
  KERNEL_BASELINE_VALIDATOR="$BASELINE_CONTROL_DIR/validate-sp11-kernel-baseline.sh"
  (
    cd "$BASELINE_CONTROL_DIR"
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
    bash "$KERNEL_BASELINE_VALIDATOR" \
      --repo-dir "$COMMITTED_SUPPORT_DIR" \
      --emit-release-values \
      "$KERNEL_BASELINE"
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
  verify_initial_baseline_control_state || exit 1
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
  if [ -n "$APT_SOURCES_FILE" ]; then
    echo "--release-build cannot use mutable --apt-sources input." >&2
    exit 2
  fi
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

if [ "$IMMUTABLE_APT" = "true" ]; then
  require_tool python3
  require_apt_list_decoder
fi

if [ "$DRY_RUN" != "true" ]; then
  require_tool docker
fi

if [ "$IMMUTABLE_APT" = "true" ] && [ "$DRY_RUN" != "true" ]; then
  if ! release_dir_records="$(
    cd "$work_abs" || exit 1
    verify_pinned_work_root_cwd || exit 1
    for release_name in apt-archives apt-indexes apt-lists artifacts; do
      release_dir="./$release_name"
      display_release_dir="$work_abs/$release_name"
      if [ -L "$release_dir" ] ||
         { [ -e "$release_dir" ] && [ ! -d "$release_dir" ]; }; then
        echo "Refusing unsafe release-build directory: $display_release_dir" >&2
        exit 1
      fi
      if [ ! -e "$release_dir" ]; then
        mkdir -m 700 "$release_dir" || exit 1
      fi
      if [ ! -d "$release_dir" ] || [ -L "$release_dir" ]; then
        echo "Release-build directory is not a real directory: $display_release_dir" >&2
        exit 1
      fi
      if find "$release_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
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
  done <<< "$release_dir_records"
  [ "${#RELEASE_WORK_DIR_NAMES[@]}" -eq 4 ] || {
    echo "Release work-directory identity set is not exact." >&2
    exit 1
  }
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
  if ! (
    cd "$BASELINE_CONTROL_DIR"
    verify_pinned_baseline_control_cwd || exit 1
    set -o noclobber
    umask 077
    docker buildx imagetools inspect --raw "$IMAGE" > ./sp11-oci-index.json || exit 1
    verify_pinned_baseline_control_cwd || exit 1
  ); then
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
  python3 "$COMMITTED_SUPPORT_DIR/scripts/validate-sp11-oci-index.py" \
    --raw-index "$oci_index_file" \
    --index-ref "$RELEASE_BASELINE_DOCKER_IMAGE" \
    --platform "$RELEASE_BASELINE_DOCKER_PLATFORM" \
    --expected-platform-manifest "$RELEASE_BASELINE_DOCKER_PLATFORM_MANIFEST"
  if [ "$(baseline_control_file_state "$oci_index_file")" != "$RELEASE_OCI_INDEX_STATE" ]; then
    echo "Private OCI index changed during semantic validation." >&2
    exit 1
  fi
  verify_release_support_checkout
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
  if ! (
    cd "$BASELINE_CONTROL_DIR"
    verify_pinned_baseline_control_cwd || exit 1
    set -o noclobber
    umask 077
    printf '%s\n' "$release_build_args_text" > ./docker-build-args.txt || exit 1
    verify_pinned_baseline_control_cwd || exit 1
  ); then
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
       END {
         exit !(repo_count == 1 && repo_ro == 1 && repo_nested == 0 &&
                control_count == 1 && control_ro == 1 && control_nested == 0)
       }
     ' /proc/self/mountinfo; then
    echo "Immutable release build requires exact unshadowed read-only /repo and /sp11-control mounts." >&2
    exit 1
  fi
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
  if find "$artifact_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
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
fi
if [ "$RELEASE_BUILD" = "true" ]; then
  if ! (
    cd "$BASELINE_CONTROL_DIR"
    verify_pinned_baseline_control_cwd || exit 1
    set -o noclobber
    umask 077
    printf '%s\n' "$docker_entrypoint_text" > ./docker-build-inside.sh || exit 1
    verify_pinned_baseline_control_cwd || exit 1
  ); then
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
  --rm
  --platform "$PLATFORM"
  -e "SP11_ENABLE_DEB_SRC=$ENABLE_DEB_SRC"
  -e "SP11_APT_SOURCES_NAME=$(basename "${APT_SOURCES_FILE:-sp11-qcom-x1e.sources}")"
  -e "SP11_BUILD_CONTAINER_IMAGE=$IMAGE"
  -e "SP11_BUILD_CONTAINER_PLATFORM=$PLATFORM"
  -e "SP11_CONTAINER_WORK_DIR=$CONTAINER_WORK_DIR"
  -v "$work_abs:/work"
)

if [ "$RELEASE_BUILD" = "true" ]; then
  [ -n "$COMMITTED_SUPPORT_DIR" ] || {
    echo "Release Docker run is missing its private committed support checkout." >&2
    exit 1
  }
  docker_args+=(
    -e "SP11_EXPECTED_SUPPORT_COMMIT=$SUPPORT_HEAD_START"
    -e "SP11_PRIVATE_SUPPORT_SNAPSHOT=true"
    -e "SP11_EXPECTED_BUILD_ARGS_SHA256=$RELEASE_BUILD_ARGS_SHA256"
    -e "SP11_EXPECTED_ENTRYPOINT_SHA256=$RELEASE_ENTRYPOINT_SHA256"
    -e "SP11_EXPECTED_BASELINE_SHA256=$KERNEL_BASELINE_SHA256"
    -v "$COMMITTED_SUPPORT_DIR:/repo:ro"
    -v "$BASELINE_CONTROL_DIR:/sp11-control:ro"
  )
  if [ -n "$RELEASE_OCI_INDEX_SHA256" ]; then
    docker_args+=(-e "SP11_EXPECTED_OCI_INDEX_SHA256=$RELEASE_OCI_INDEX_SHA256")
  fi
else
  docker_args+=(-v "$repo_dir:/repo:ro")
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
  printf 'Docker command:\n  docker'
  printf ' %q' "${docker_args[@]}"
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
set +e
docker "${docker_args[@]}"
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
  if [ "$IMMUTABLE_APT" = "true" ] || [ "$CONTAINER_WORK_DIR" != "/work" ]; then
    completed_manifest="$work_abs/artifacts/sp11-kernel-build-manifest.txt"
  else
    completed_manifest="$work_abs/sp11-kernel-build-manifest.txt"
  fi
  if [ ! -f "$completed_manifest" ] || [ -L "$completed_manifest" ] ||
     ! grep -Fxq 'Provenance schema: sp11-kernel-build-v2' "$completed_manifest" ||
     ! grep -Fxq 'Release build: true' "$completed_manifest" ||
     ! grep -Fxq 'Build completed: true' "$completed_manifest"; then
    echo "Docker release build completed without a valid final schema-v2 manifest." >&2
    exit 1
  fi
  if [ "$IMMUTABLE_APT" = "true" ]; then
    apt_provenance="$work_abs/artifacts/sp11-kernel-apt-provenance.txt"
    build_inputs="$work_abs/artifacts/sp11-kernel-build-inputs.txt"
    if [ ! -f "$apt_provenance" ] || [ -L "$apt_provenance" ]; then
      echo "Docker release build completed without immutable APT provenance." >&2
      exit 1
    fi
    verify_release_control_state
    verify_release_support_checkout
    python3 "$COMMITTED_SUPPORT_DIR/scripts/sp11-kernel-build-inputs.py" write \
      --baseline "$KERNEL_BASELINE" \
      --baseline-sha256 "$KERNEL_BASELINE_SHA256" \
      --build-args-sha256 "$RELEASE_BUILD_ARGS_SHA256" \
      --entrypoint-sha256 "$RELEASE_ENTRYPOINT_SHA256" \
      --oci-index-sha256 "$RELEASE_OCI_INDEX_SHA256" \
      --work-dir "$work_abs" \
      --support-head "$SUPPORT_HEAD_START" \
      --build-args "$work_abs/docker-build-args.txt" \
      --entrypoint "$work_abs/docker-build-inside.sh" \
      --oci-index "$work_abs/sp11-oci-index.json" \
      --build-manifest "$completed_manifest" \
      --apt-provenance "$apt_provenance" \
      --apt-archives-dir "$work_abs/apt-archives" \
      --apt-lists-dir "$work_abs/apt-lists" \
      --apt-index-cache-dir "$work_abs/apt-indexes" \
      --apt-local-build-deps-dir "$work_abs/artifacts" \
      --apt-pre-inventory "$work_abs/sp11-apt-installed-pre.txt" \
      --apt-post-inventory "$work_abs/sp11-apt-installed-post.txt" \
      --output "$build_inputs"
    verify_release_control_state
    verify_release_support_checkout
    python3 "$COMMITTED_SUPPORT_DIR/scripts/sp11-kernel-build-inputs.py" validate \
      --baseline "$KERNEL_BASELINE" \
      --baseline-sha256 "$KERNEL_BASELINE_SHA256" \
      --build-args-sha256 "$RELEASE_BUILD_ARGS_SHA256" \
      --entrypoint-sha256 "$RELEASE_ENTRYPOINT_SHA256" \
      --oci-index-sha256 "$RELEASE_OCI_INDEX_SHA256" \
      --work-dir "$work_abs" \
      --support-head "$SUPPORT_HEAD_START" \
      --build-args "$work_abs/docker-build-args.txt" \
      --entrypoint "$work_abs/docker-build-inside.sh" \
      --oci-index "$work_abs/sp11-oci-index.json" \
      --build-manifest "$completed_manifest" \
      --apt-provenance "$apt_provenance" \
      --apt-archives-dir "$work_abs/apt-archives" \
      --apt-lists-dir "$work_abs/apt-lists" \
      --apt-index-cache-dir "$work_abs/apt-indexes" \
      --apt-local-build-deps-dir "$work_abs/artifacts" \
      --apt-pre-inventory "$work_abs/sp11-apt-installed-pre.txt" \
      --apt-post-inventory "$work_abs/sp11-apt-installed-post.txt" \
      --output "$build_inputs"
    verify_release_control_state
    verify_release_support_checkout
    for required_artifact in "$completed_manifest" "$apt_provenance" "$build_inputs"; do
      [ -f "$required_artifact" ] && [ ! -L "$required_artifact" ] || {
        echo "Release build is missing a required provenance artifact: $required_artifact" >&2
        exit 1
      }
    done
    verify_docker_control_state
    echo "Publication remains blocked: outer release validation and independent real-build, signing, and licence gates must pass."
  fi
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
