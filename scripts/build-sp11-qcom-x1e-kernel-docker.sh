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

IMAGE=""
IMAGE_EXPLICIT="false"
PLATFORM="linux/arm64"
PLATFORM_EXPLICIT="false"
WORK_DIR="build/docker-sp11-qcom-x1e-kernel"
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
          "$CONTROL_DIR/docker-build-inside.sh"
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

validate_legacy_control_paths() {
  local control_path

  for control_path in \
    "$work_abs/docker-build-args.txt" \
    "$work_abs/docker-build-inside.sh"; do
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
  git -c "safe.directory=$repo_dir" -C "$repo_dir" "$@"
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

repo_container_path() {
  local abs rel
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
  /repo|/repo/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/etc|/etc/*|\
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

if [ -n "$PATCH_DIRS" ]; then
  for pd in $PATCH_DIRS; do
    patch_dir_abs="$(repo_abs_path "$pd")"
    if [ ! -d "$patch_dir_abs" ]; then
      echo "Patch directory not found: $patch_dir_abs" >&2
      exit 1
    fi
  done
elif [ -n "$PATCH_DIR" ]; then
  patch_dir_abs="$(repo_abs_path "$PATCH_DIR")"
  if [ ! -d "$patch_dir_abs" ]; then
    echo "Patch directory not found: $patch_dir_abs" >&2
    exit 1
  fi
fi

if ! work_abs="$(ensure_safe_work_dir "$WORK_DIR")"; then
  exit 1
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

if [ "$DRY_RUN" != "true" ]; then
  require_tool docker
fi

if ! validate_legacy_control_paths; then
  exit 1
fi
CONTROL_DIR="$(mktemp -d "$work_abs/.sp11-docker-control.XXXXXX")"
chmod 700 "$CONTROL_DIR"
if [ -L "$CONTROL_DIR" ] || [ ! -d "$CONTROL_DIR" ]; then
  echo "Could not create a private Docker control directory safely." >&2
  exit 1
fi
trap 'cleanup_control_dir; cleanup_payload_stage' EXIT

args_file="$CONTROL_DIR/docker-build-args.txt"
run_script="$CONTROL_DIR/docker-build-inside.sh"

inner_args=(
  --source "$SOURCE_MODE"
  --work-dir "$CONTAINER_WORK_DIR"
  --install-deps
  --no-fakeroot
)
[ "$RELEASE_BUILD" = "true" ] && inner_args+=(--release-build)

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

printf '%s\n' "${inner_args[@]}" > "$args_file"
chmod 600 "$args_file"

cat > "$run_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

artifact_dir=/work/artifacts
echo "Cleaning copied artifact shuttle directory: $artifact_dir"
rm -rf "$artifact_dir"
mkdir -p "$artifact_dir"

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

if [ -f /tmp/sp11-apt-sources ]; then
  case "${SP11_APT_SOURCES_NAME:-sp11-qcom-x1e.sources}" in
    *.sources) install -m 0644 /tmp/sp11-apt-sources /etc/apt/sources.list.d/sp11-qcom-x1e.sources ;;
    *) install -m 0644 /tmp/sp11-apt-sources /etc/apt/sources.list.d/sp11-qcom-x1e.list ;;
  esac
fi

if [ "${SP11_ENABLE_DEB_SRC:-true}" = "true" ]; then
  enable_deb_src
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates git dpkg-dev

build_args=()
while IFS= read -r build_arg; do
  build_args+=("$build_arg")
done < /work/docker-build-args.txt
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
if [ "$container_work_dir" != "/work" ]; then
  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    cp -f "$deb" "$artifact_dir/"
  done < <(find_qcom_kernel_debs "$container_work_dir")

  for manifest in \
    "$container_work_dir/sp11-kernel-build-manifest.txt" \
    "$container_work_dir/sp11-kernel-debs.txt"; do
    [ -f "$manifest" ] && cp -f "$manifest" "$artifact_dir/"
  done
fi
EOF
chmod 700 "$run_script"

if ! validate_legacy_control_paths; then
  exit 1
fi
if ! install_control_file "$args_file" "$work_abs/docker-build-args.txt" ||
   ! install_control_file "$run_script" "$work_abs/docker-build-inside.sh"; then
  exit 1
fi
cleanup_control_dir
CONTROL_DIR=""
args_file="$work_abs/docker-build-args.txt"
run_script="$work_abs/docker-build-inside.sh"

docker_args=(
  run
  --rm
  --platform "$PLATFORM"
  -e "SP11_ENABLE_DEB_SRC=$ENABLE_DEB_SRC"
  -e "SP11_APT_SOURCES_NAME=$(basename "${APT_SOURCES_FILE:-sp11-qcom-x1e.sources}")"
  -e "SP11_BUILD_CONTAINER_IMAGE=$IMAGE"
  -e "SP11_BUILD_CONTAINER_PLATFORM=$PLATFORM"
  -e "SP11_CONTAINER_WORK_DIR=$CONTAINER_WORK_DIR"
  -v "$repo_dir:/repo:ro"
  -v "$work_abs:/work"
)

if [ "$RELEASE_BUILD" = "true" ]; then
  docker_args+=(-e "SP11_EXPECTED_SUPPORT_COMMIT=$SUPPORT_HEAD_START")
fi

if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
  docker_args+=(-v "$LINUX_WORK_VOLUME:$CONTAINER_WORK_DIR")
fi

if [ -n "$APT_SOURCES_FILE" ]; then
  docker_args+=(-v "$APT_SOURCES_FILE:/tmp/sp11-apt-sources:ro")
fi

docker_args+=("$IMAGE" /work/docker-build-inside.sh)

if [ "$DRY_RUN" = "true" ]; then
  printf 'Docker command:\n  docker'
  printf ' %q' "${docker_args[@]}"
  printf '\n\nInner build args:\n'
  printf '  %s\n' "${inner_args[@]}"
  verify_release_support_stable
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

set +e
docker "${docker_args[@]}"
docker_status=$?
set -e
if [ "$docker_status" -ne 0 ]; then
  echo "Docker kernel build failed; inspect the log above for the first build error." >&2
  echo "If the source tree was partially prepared, rerun with --reset-source after fixing the failure." >&2
  exit "$docker_status"
fi

verify_release_support_stable

if [ "$RELEASE_BUILD" = "true" ]; then
  if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
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
