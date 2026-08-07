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

# Regenerate the debian.qcom-x1e annotations patch for a jg/ubuntu-qcom-x1e
# kernel branch. Runs the export -> olddefconfig -> import cycle from
# patches/jglathe-qcom-x1e-<version>/README.md inside an ubuntu:26.04 Docker
# container, then writes the patch back to the host patch directory.
#
# Use this whenever a new jg tag fails check-config with "N config options have
# been changed" because the upstream annotations were authored against a
# different toolchain (e.g. an older rustc/LLVM) than ubuntu:26.04 provides.

IMAGE="ubuntu:26.04"
PLATFORM="linux/arm64"
WORK_DIR=""
CONTAINER_WORK_DIR="/linux-work"
LINUX_WORK_VOLUME="sp11-qcom-x1e-kernel-build"
GIT_URL=""
GIT_BRANCH=""
VERSION_TOKEN=""
BASE_VERSION=""
PATCH_DIR=""
RESET_SOURCE="false"
KEEP_SOURCE="false"
DRY_RUN="false"
CONTROL_DIR=""
PATCH_STAGE=""

usage() {
  cat <<EOF
Usage: $0 [options]

Regenerates the debian.qcom-x1e/config/annotations patch for a
jg/ubuntu-qcom-x1e kernel branch by running the export -> olddefconfig ->
import cycle inside an ubuntu:26.04 Docker container.

The result is written to the host patch directory as
0001-debian-qcom-x1e-update-annotations-for-<version>.patch, replacing any
existing 0001-*.patch there. Other patches in the directory are left alone.

Options:
  --git-url URL          Kernel git URL. Required unless --keep-source.
  --git-branch BRANCH    Kernel git branch or tag. Always required so the source
                         directory and output identity are unambiguous.
  --version-token TOKEN  Full version token (e.g. "7.2-rc5-jg-0"). Defaults to
                         --git-branch minus the jg/ubuntu-qcom-x1e- prefix.
                         Set this when the branch name does not encode the full
                         version (e.g. branch jg/ubuntu-qcom-x1e-7.2rc for
                         kernel version 7.2-rc5-jg-0).
  --base-version BASE    Base version without the -jg-<n> suffix (e.g.
                         "7.2-rc5"). Defaults to --version-token minus the
                         -jg-<n> suffix. Used for the patch directory name and
                         the CONFIG_VERSION_SIGNATURE value.
  --patch-dir DIR        Host patch directory to write the regenerated patch
                         into. Defaults to patches/jglathe-qcom-x1e-<base-version>
                         derived from --git-branch.
  --work-dir DIR         Host control/artifact directory, default
                         build/docker-sp11-qcom-x1e-annotations.
  --container-work-dir DIR
                         Container build directory, default $CONTAINER_WORK_DIR.
  --linux-work-volume NAME
                         Docker volume for --container-work-dir, default
                         $LINUX_WORK_VOLUME. Ignored when --container-work-dir
                         is /work.
  --image IMAGE          Docker image, default $IMAGE.
  --platform PLATFORM    Docker platform, default $PLATFORM.
  --reset-source         Reset existing source tree in the build work dir before
                         cloning. Required if the existing tree has local
                         changes; recommended when reusing a Docker volume from
                         a failed build.
  --keep-source          Reuse an existing source tree already on the Docker
                         volume without cloning or resetting. Use this only if
                         you have already reverted any prior 0001-* annotations
                         patches from the tree; otherwise the regenerated patch
                         will be relative to the patched annotations, not
                         upstream. The recommended mode is --reset-source.
  --dry-run              Print the Docker command and exit.
  -h, --help             Show this help.

Example:
  $0 \\
    --git-url https://github.com/jglathe/linux_ms_dev_kit.git \\
    --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \\
    --reset-source
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

reject_unsafe_path_spelling() {
  local value="$1" label="$2"

  case "$value" in
    ""|*$'\n'*|*$'\r'*|*$'\t'*|*[!A-Za-z0-9._+/-]*)
      echo "$label must use a canonical path without control or unsafe characters: $value" >&2
      return 1
      ;;
    *//*|*/|./*|*/./*)
      echo "$label must use a canonical path without duplicate, dot, or trailing separators: $value" >&2
      return 1
      ;;
  esac
  case "/$value/" in
    */../*)
      echo "$label must not contain a '..' path component: $value" >&2
      return 1
      ;;
  esac
}

ensure_safe_work_dir() {
  local requested="$1" candidate normalized current component
  local -a components=()

  reject_unsafe_path_spelling "$requested" "--work-dir" || return 1
  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$repo_dir/$requested" ;;
  esac
  if ! normalized="$(normalize_absolute_path "$candidate")"; then
    echo "Could not normalize --work-dir safely: $requested" >&2
    return 1
  fi
  if [ "$candidate" != "$normalized" ]; then
    echo "--work-dir must use its exact canonical path: $requested" >&2
    return 1
  fi
  case "$normalized" in
    "$repo_dir/build"/*) ;;
    *)
      echo "--work-dir must be a dedicated descendant of this repository's build/ directory: $requested" >&2
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

resolve_safe_patch_dir() {
  local requested="$1" candidate normalized current component
  local -a components=()

  reject_unsafe_path_spelling "$requested" "--patch-dir" || return 1
  case "$requested" in
    /*) candidate="$requested" ;;
    *) candidate="$repo_dir/$requested" ;;
  esac
  if ! normalized="$(normalize_absolute_path "$candidate")"; then
    echo "Could not normalize --patch-dir safely: $requested" >&2
    return 1
  fi
  if [ "$candidate" != "$normalized" ]; then
    echo "--patch-dir must use its exact canonical path: $requested" >&2
    return 1
  fi
  case "$normalized" in
    "$repo_dir/patches"/*) ;;
    *)
      echo "--patch-dir must be a dedicated child of this repository's patches/ directory: $requested" >&2
      return 1
      ;;
  esac

  current=""
  IFS='/' read -r -a components <<< "${normalized#/}"
  for component in "${components[@]}"; do
    [ -n "$component" ] || continue
    current="$current/$component"
    if [ -L "$current" ]; then
      echo "--patch-dir must not contain symlink components: $requested" >&2
      return 1
    fi
    if [ ! -d "$current" ]; then
      echo "--patch-dir component is not an existing directory: $current" >&2
      return 1
    fi
  done
  if [ "$(cd "$normalized" && pwd -P)" != "$normalized" ]; then
    echo "--patch-dir did not resolve to its exact non-symlink path: $requested" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

validate_public_git_url() {
  local url="$1" authority path

  case "$url" in
    https://*) ;;
    *) echo "--git-url must be a public HTTPS URL." >&2; return 1 ;;
  esac
  if [ "${#url}" -gt 2048 ]; then
    echo "--git-url exceeds the supported length." >&2
    return 1
  fi
  case "$url" in
    *[[:space:]]*|*\?*|*\#*|*@*)
      echo "--git-url must not contain credentials, controls, shell metacharacters, a query, or a fragment." >&2
      return 1
      ;;
  esac
  case "$url" in
    *\'*|*\"*|*\`*|*\$*|*\\*)
      echo "--git-url must not contain credentials, controls, shell metacharacters, a query, or a fragment." >&2
      return 1
      ;;
  esac
  case "$url" in
    *[!A-Za-z0-9._~:/%+-]*)
      echo "--git-url contains unsupported characters." >&2
      return 1
      ;;
  esac
  authority="${url#https://}"
  authority="${authority%%/*}"
  case "$authority" in
    ""|.*|*.|*[!A-Za-z0-9.-]*)
      echo "--git-url has an unsafe host." >&2
      return 1
      ;;
  esac
  case "$authority" in
    localhost|localhost.*|*.localhost|*.local|*.internal|*.invalid|*.test|*.example|*.onion|127.*|0.*)
      echo "--git-url must name a public host." >&2
      return 1
      ;;
  esac
  case "$authority" in
    *[!0-9.]*) ;;
    *) echo "--git-url must use a public DNS host, not a numeric address." >&2; return 1 ;;
  esac
  case "$authority" in
    *.*) ;;
    *) echo "--git-url must name a fully qualified public host." >&2; return 1 ;;
  esac
  path="${url#https://$authority}"
  case "$path" in
    /?*) ;;
    *) echo "--git-url must include a repository path." >&2; return 1 ;;
  esac
}

validate_git_ref() {
  local value="$1"

  if [ "${#value}" -gt 255 ] ||
     ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+~/-]*$ ]] ||
     [[ "$value" == *..* ]] ||
     ! git check-ref-format "refs/heads/$value" >/dev/null 2>&1; then
    echo "--git-branch must be a safe full Git ref name: $value" >&2
    return 1
  fi
}

validate_version_token() {
  local value="$1" label="$2"

  if [ "${#value}" -gt 128 ] ||
     ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] ||
     [[ "$value" == *..* ]]; then
    echo "$label must be a safe version token without slashes, controls, or '..': $value" >&2
    return 1
  fi
}

validate_container_storage() {
  local normalized

  case "$CONTAINER_WORK_DIR" in
    *$'\n'*|*$'\r'*|*$'\t'*|*[!A-Za-z0-9._+/-]*)
      echo "--container-work-dir must not contain controls or unsafe characters." >&2
      return 1
      ;;
  esac
  if ! normalized="$(normalize_absolute_path "$CONTAINER_WORK_DIR")" ||
     [ "$normalized" != "$CONTAINER_WORK_DIR" ]; then
    echo "--container-work-dir must use a canonical absolute path without '.', '..', duplicate, or trailing separators." >&2
    return 1
  fi
  case "$CONTAINER_WORK_DIR" in
    /work/*)
      echo "--container-work-dir must not be nested under /work." >&2
      return 1
      ;;
    /repo|/repo/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/etc|/etc/*|\
    /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|\
    /run|/run/*|/tmp|/tmp/*|/var|/var/*|/boot|/boot/*|/home|/home/*|\
    /root|/root/*|/opt|/opt/*|/mnt|/mnt/*|/media|/media/*|/srv|/srv/*|/)
      echo "--container-work-dir must not overlap a protected container path: $CONTAINER_WORK_DIR" >&2
      return 1
      ;;
  esac
  if [ "${#LINUX_WORK_VOLUME}" -gt 128 ] ||
     ! [[ "$LINUX_WORK_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "--linux-work-volume must be a Docker named volume, not a host path or mount specification." >&2
    return 1
  fi
}

validate_docker_tokens() {
  if [ "${#IMAGE}" -gt 255 ] ||
     ! [[ "$IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] ||
     [[ "$IMAGE" == *..* ]]; then
    echo "--image must be a safe Docker image reference." >&2
    return 1
  fi
  if [ "${#PLATFORM}" -gt 64 ] ||
     ! [[ "$PLATFORM" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
     [[ "$PLATFORM" == *..* ]]; then
    echo "--platform must be a safe Docker platform token." >&2
    return 1
  fi
}

file_sha256() {
  local path="$1"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

file_mode() {
  local path="$1" mode

  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -f '%Lp' "$path"
  fi
}

validate_control_tripwire() {
  local target="$1"

  if [ -L "$target" ]; then
    echo "Refusing symlinked annotations control-file tripwire: $target" >&2
    return 1
  fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    echo "Refusing non-regular annotations control-file tripwire: $target" >&2
    return 1
  fi
}

cleanup_control_dir() {
  [ -n "$CONTROL_DIR" ] || return 0
  case "$CONTROL_DIR" in
    "$work_abs"/.sp11-annotations-control.*)
      if [ -d "$CONTROL_DIR" ] && [ ! -L "$CONTROL_DIR" ]; then
        rm -f -- "$CONTROL_DIR/docker-regenerate-inside.sh"
        rmdir "$CONTROL_DIR" 2>/dev/null || true
      else
        echo "warning: refusing to follow changed annotations control directory: $CONTROL_DIR" >&2
      fi
      ;;
    *) echo "warning: refusing to clean unexpected annotations control directory: $CONTROL_DIR" >&2 ;;
  esac
}

cleanup_patch_stage() {
  [ -n "$PATCH_STAGE" ] || return 0
  case "$PATCH_STAGE" in
    "$patch_dir_abs"/.sp11-annotations-patch.*) rm -f -- "$PATCH_STAGE" ;;
    *) echo "warning: refusing to clean unexpected annotations patch stage: $PATCH_STAGE" >&2 ;;
  esac
}

cleanup() {
  cleanup_control_dir
  cleanup_patch_stage
}

install_control_file() {
  local source="$1" target="$2"

  validate_control_tripwire "$target" || return 1
  if ! mv "$source" "$target"; then
    echo "Could not atomically install annotations control evidence: $target" >&2
    return 1
  fi
  if [ -L "$target" ] || [ ! -f "$target" ]; then
    echo "Annotations control evidence is not a regular file after install: $target" >&2
    return 1
  fi
  if [ "$(file_mode "$target")" != "700" ]; then
    echo "Annotations control evidence does not have mode 0700: $target" >&2
    return 1
  fi
}

validate_container_output_tripwire() {
  local path="$1"

  if [ -L "$path" ]; then
    echo "Refusing symlinked annotations output tripwire: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "Refusing non-regular annotations output tripwire: $path" >&2
    return 1
  fi
}

prepare_container_output_path() {
  local path="$1"

  validate_container_output_tripwire "$path" || return 1
  [ ! -e "$path" ] || rm -f -- "$path"
}

validate_generated_patch() {
  local path="$1"

  if [ ! -s "$path" ] || [ ! -f "$path" ] || [ -L "$path" ]; then
    echo "Generated annotations patch must be a nonempty regular, non-symlinked file: $path" >&2
    return 1
  fi
  if ! grep -Iq . "$path" || ! grep -q '^diff --git ' "$path"; then
    echo "Generated annotations patch is not a nonempty textual Git patch: $path" >&2
    return 1
  fi
}

preflight_patch_leaves() {
  local candidate

  shopt -s nullglob
  for candidate in "$patch_dir_abs"/0001-*.patch; do
    if [ -L "$candidate" ]; then
      shopt -u nullglob
      echo "Refusing symlinked annotations patch leaf: $candidate" >&2
      return 1
    fi
    if [ -e "$candidate" ] && [ ! -f "$candidate" ]; then
      shopt -u nullglob
      echo "Refusing non-regular annotations patch leaf: $candidate" >&2
      return 1
    fi
  done
  shopt -u nullglob
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    --version-token)
      require_arg "$1" "${2:-}"
      VERSION_TOKEN="$2"
      shift 2
      ;;
    --base-version)
      require_arg "$1" "${2:-}"
      BASE_VERSION="$2"
      shift 2
      ;;
    --patch-dir)
      require_arg "$1" "${2:-}"
      PATCH_DIR="$2"
      shift 2
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
    --image)
      require_arg "$1" "${2:-}"
      IMAGE="$2"
      shift 2
      ;;
    --platform)
      require_arg "$1" "${2:-}"
      PLATFORM="$2"
      shift 2
      ;;
    --reset-source)
      RESET_SOURCE="true"
      shift
      ;;
    --keep-source)
      KEEP_SOURCE="true"
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

if [ "$KEEP_SOURCE" = "true" ] && [ "$RESET_SOURCE" = "true" ]; then
  echo "--keep-source and --reset-source are mutually exclusive." >&2
  exit 2
fi

if [ -z "$GIT_BRANCH" ]; then
  echo "--git-branch is required in both fresh-source and --keep-source modes." >&2
  exit 2
fi
if [ "$KEEP_SOURCE" != "true" ] && [ -z "$GIT_URL" ]; then
  echo "--git-url is required unless --keep-source is used." >&2
  exit 2
fi

require_tool git
require_tool grep
require_tool mktemp
require_tool awk
require_tool stat
if ! command -v shasum >/dev/null 2>&1 &&
   ! command -v sha256sum >/dev/null 2>&1; then
  echo "Missing required SHA-256 tool: shasum or sha256sum" >&2
  exit 1
fi

validate_git_ref "$GIT_BRANCH" || exit 2
if [ -n "$GIT_URL" ]; then
  validate_public_git_url "$GIT_URL" || exit 2
fi
validate_container_storage || exit 2
validate_docker_tokens || exit 2

# Derive the short version token (e.g. "7.1.3-jg-1") from the branch name.
# Branches look like jg/ubuntu-qcom-x1e-<version>, e.g.
#   jg/ubuntu-qcom-x1e-7.1.3-jg-1  ->  7.1.3-jg-1
# Some branches do not encode the full version (e.g. jg/ubuntu-qcom-x1e-7.2rc
# for kernel 7.2-rc5-jg-0); pass --version-token for those.
if [ -n "$VERSION_TOKEN" ]; then
  version_token="$VERSION_TOKEN"
elif [ -n "$GIT_BRANCH" ]; then
  version_token="${GIT_BRANCH#jg/ubuntu-qcom-x1e-}"
  if [ "$version_token" = "$GIT_BRANCH" ]; then
    echo "Could not derive version token from --git-branch: $GIT_BRANCH" >&2
    echo "Expected a branch named jg/ubuntu-qcom-x1e-<version>." >&2
    exit 2
  fi
else
  version_token=""
fi

validate_version_token "$version_token" "--version-token" || exit 2

# Branches follow jg/ubuntu-qcom-x1e-<base>-jg-<n>, e.g.
#   jg/ubuntu-qcom-x1e-7.1.3-jg-1  ->  base "7.1.3",  full "7.1.3-jg-1"
# The patch directory is keyed off <base> (patches/jglathe-qcom-x1e-<base>),
# matching the existing jglathe-qcom-x1e-7.1.1 and ...-7.1.3 directories.
# Pass --base-version when the branch name does not encode it (e.g. 7.2rc ->
# base "7.2-rc5").
if [ -n "$BASE_VERSION" ]; then
  base_version="$BASE_VERSION"
else
  base_version="${version_token%-jg-*}"
  if [ "$base_version" = "$version_token" ]; then
    echo "Could not split base version from --git-branch: $GIT_BRANCH" >&2
    echo "Expected a branch named jg/ubuntu-qcom-x1e-<base>-jg-<n> or pass --base-version." >&2
    exit 2
  fi
fi
validate_version_token "$base_version" "--base-version" || exit 2

if [ -z "$PATCH_DIR" ]; then
  if [ -z "$version_token" ]; then
    echo "Cannot derive --patch-dir without --git-branch; pass --patch-dir explicitly." >&2
    exit 2
  fi
  PATCH_DIR="patches/jglathe-qcom-x1e-${base_version}"
fi

patch_dir_abs="$(resolve_safe_patch_dir "$PATCH_DIR")" || exit 1
preflight_patch_leaves || exit 1

if [ -z "$WORK_DIR" ]; then
  WORK_DIR="build/docker-sp11-qcom-x1e-annotations-${version_token}"
fi
work_abs="$(ensure_safe_work_dir "$WORK_DIR")" || exit 1

# Source directory name under CONTAINER_WORK_DIR/source mirrors what
# build-sp11-qcom-x1e-kernel.sh's prepare_git_source() uses:
#   git-<branch with / replaced by ->
safe_branch="${GIT_BRANCH//\//-}"
expected_source_dir="${CONTAINER_WORK_DIR}/source/git-${safe_branch}"

patch_basename="0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"
src_patch="$work_abs/$patch_basename"
annotations_after="$work_abs/annotations.after"
control_target="$work_abs/docker-regenerate-inside.sh"
dst_patch="$patch_dir_abs/$patch_basename"

# Validate every predictable host leaf before creating any control or output
# file. In particular, never let the root container follow a host symlink.
validate_control_tripwire "$control_target" || exit 1
validate_container_output_tripwire "$src_patch" || exit 1
validate_container_output_tripwire "$annotations_after" || exit 1

CONTROL_DIR="$(mktemp -d "$work_abs/.sp11-annotations-control.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
chmod 700 "$CONTROL_DIR"
if [ -L "$CONTROL_DIR" ] || [ ! -d "$CONTROL_DIR" ] ||
   [ "$(file_mode "$CONTROL_DIR")" != "700" ]; then
  echo "Could not create a private annotations control directory safely." >&2
  exit 1
fi

run_script="$CONTROL_DIR/docker-regenerate-inside.sh"
cat > "$run_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_WORK_TREE
  for variable_name in "\${!GIT_CONFIG_KEY_@}" "\${!GIT_CONFIG_VALUE_@}"; do
    unset "\$variable_name"
  done
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_ATTR_NOSYSTEM=1
  export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \\
  bc bison build-essential ca-certificates cpio debhelper devscripts dpkg-dev \\
  dwarves equivs flex gcc-15 gcc-15-aarch64-linux-gnu git kmod libelf-dev \\
  libssl-dev python3 python3-dev rsync

# Install the same gcc-15 toolchain the kernel build uses, so that Kconfig
# cc-option probes during olddefconfig resolve identically to a real build.
# gcc-15 is in ubuntu:26.04 main; gcc-15-aarch64-linux-gnu (the cross compiler
# package, which provides the aarch64-linux-gnu-gcc-15 executable) is in
# universe.

container_work="${CONTAINER_WORK_DIR}"
source_root="\$container_work/source"
src="${expected_source_dir}"

if [ ! -d "\$container_work" ] || [ -L "\$container_work" ] ||
   [ "\$(cd "\$container_work" && pwd -P)" != "\$container_work" ]; then
  echo "Container work mount is not an exact physical directory: \$container_work" >&2
  exit 1
fi
if [ -L "\$source_root" ] || { [ -e "\$source_root" ] && [ ! -d "\$source_root" ]; }; then
  echo "Refusing unsafe source-root tripwire: \$source_root" >&2
  exit 1
fi
mkdir -p "\$source_root"
if [ -L "\$source_root" ] || [ ! -d "\$source_root" ] ||
   [ "\$(cd "\$source_root" && pwd -P)" != "\$source_root" ]; then
  echo "Source root did not resolve to its exact physical path: \$source_root" >&2
  exit 1
fi
if [ -L "\$src" ] || { [ -e "\$src" ] && [ ! -d "\$src" ]; }; then
  echo "Refusing unsafe kernel source tripwire: \$src" >&2
  exit 1
fi
if [ -d "\$src" ] && [ "\$(cd "\$src" && pwd -P)" != "\$src" ]; then
  echo "Kernel source did not resolve to its exact physical path: \$src" >&2
  exit 1
fi

require_clean_git_source() {
  local status_output

  if ! git -C "\$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Existing source is not a Git worktree: \$src" >&2
    return 1
  fi
  if ! status_output="\$(git -C "\$src" status --porcelain --untracked-files=all)"; then
    echo "Could not inspect the existing source worktree: \$src" >&2
    return 1
  fi
  if [ -n "\$status_output" ]; then
    echo "Existing source has tracked or untracked changes: \$src" >&2
    echo "Preserve them, or rerun with the explicit --reset-source option." >&2
    return 1
  fi
}

if [ "\${SP11_KEEP_SOURCE:-false}" = "true" ]; then
  if [ ! -d "\$src" ]; then
    echo "Source tree not found for --keep-source: \$src" >&2
    exit 1
  fi
  require_clean_git_source || exit 1
  head_commit="\$(git -C "\$src" rev-parse --verify 'HEAD^{commit}')"
  declared_ref_matches=false
  for candidate_ref in \
    "refs/heads/${GIT_BRANCH}" \
    "refs/tags/${GIT_BRANCH}" \
    "refs/remotes/origin/${GIT_BRANCH}"; do
    if candidate_commit="\$(git -C "\$src" rev-parse --verify "\${candidate_ref}^{commit}" 2>/dev/null)" &&
       [ "\$candidate_commit" = "\$head_commit" ]; then
      declared_ref_matches=true
      break
    fi
  done
  if [ "\$declared_ref_matches" != "true" ]; then
    echo "--keep-source HEAD is not the declared --git-branch ref: ${GIT_BRANCH}" >&2
    exit 1
  fi
else
  if [ "\${SP11_RESET_SOURCE:-false}" = "true" ]; then
    rm -rf "\$src"
  fi
  if [ ! -d "\$src" ]; then
    mkdir -p "\$(dirname "\$src")"
    git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_URL}" "\$src"
  else
    require_clean_git_source || exit 1
    origin_url="\$(git -C "\$src" remote get-url origin 2>/dev/null || true)"
    if [ "\$origin_url" != "${GIT_URL}" ]; then
      echo "Existing source origin does not match --git-url." >&2
      echo "Expected: ${GIT_URL}" >&2
      echo "Actual:   \${origin_url:-<missing>}" >&2
      echo "Use --reset-source to create a checkout from the requested origin." >&2
      exit 1
    fi

    # Resolve the declared ref at the validated URL, fetch that exact namespace,
    # then detach at FETCH_HEAD. Never trust a pre-existing origin ref silently.
    ref_kind=""
    if git ls-remote --exit-code --heads "${GIT_URL}" "${GIT_BRANCH}" >/dev/null 2>&1; then
      ref_kind="head"
    elif git ls-remote --exit-code --tags "${GIT_URL}" "${GIT_BRANCH}" >/dev/null 2>&1; then
      ref_kind="tag"
    else
      echo "Git ref not found as a branch or tag: ${GIT_BRANCH}" >&2
      echo "Remote: ${GIT_URL}" >&2
      exit 1
    fi
    if [ "\$ref_kind" = "head" ]; then
      git -C "\$src" fetch --force "${GIT_URL}" "refs/heads/${GIT_BRANCH}"
    else
      git -C "\$src" fetch --force "${GIT_URL}" "refs/tags/${GIT_BRANCH}"
    fi
    fetched_commit="\$(git -C "\$src" rev-parse --verify 'FETCH_HEAD^{commit}')"
    git -C "\$src" checkout --detach "\$fetched_commit"
  fi
  require_clean_git_source || exit 1
fi

# Install the source package's complete build dependency set. Kconfig probes
# Rust, bindgen, stubble, and other build tools, so a reduced dependency set can
# produce an annotations patch that still fails the real package build.
if [ ! -f "\$src/debian/control" ]; then
  echo "Generating debian/control"
  (cd "\$src" && ./debian/rules debian/control)
fi
(
  cd /tmp
  mk-build-deps \\
    --install \\
    --remove \\
    --tool "apt-get -y --no-install-recommends" \\
    "\$src/debian/control"
)

build_dir=/tmp/annotations-build
rm -rf "\$build_dir"
mkdir -p "\$build_dir"

echo "Exporting annotations to .config"
python3 "\$src/debian/scripts/misc/annotations" \\
  -f "\$src/debian.qcom-x1e/config/annotations" \\
  --export --arch arm64 --flavour qcom-x1e > "\$build_dir/.config"

# Match the CONFIG_VERSION_SIGNATURE value that the kernel build would inject.
sed -i 's/.*CONFIG_VERSION_SIGNATURE.*/CONFIG_VERSION_SIGNATURE="Ubuntu ${version_token}-qcom-x1e ${base_version}"/' "\$build_dir/.config"

echo "Running olddefconfig"
# Use the same toolchain flags and Rust availability probe as debian/rules.d so
# Kconfig resolves identically to the real qcom-x1e package build.
make_args=(
  -C "\$src"
  O="\$build_dir"
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  HOSTCC=aarch64-linux-gnu-gcc-15
  CC=aarch64-linux-gnu-gcc-15
  RUSTC=rustc
  HOSTRUSTC=rustc
  RUSTFMT=rustfmt
  BINDGEN=bindgen
  KERNELRELEASE="${version_token}-qcom-x1e"
  CONFIG_DEBUG_SECTION_MISMATCH=y
  KBUILD_BUILD_VERSION=1
  CFLAGS_MODULE=-DPKG_ABI=1
  PYTHON=python3
)
make "\${make_args[@]}" rustavailable || true
make "\${make_args[@]}" olddefconfig

echo "Importing generated .config back into annotations"
python3 "\$src/debian/scripts/misc/annotations" \\
  -f "\$src/debian.qcom-x1e/config/annotations" \\
  --arch arm64 --flavour qcom-x1e --import "\$build_dir/.config"

echo "Capturing diff as 0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"
git -C "\$src" diff -- debian.qcom-x1e/config/annotations \\
  > /work/0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch

# Also drop the post-import annotations file for inspection.
cp "\$src/debian.qcom-x1e/config/annotations" /work/annotations.after

echo
echo "Regenerated patch written to:"
echo "  /work/0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"
echo "Diffstat:"
git -C "\$src" diff --stat -- debian.qcom-x1e/config/annotations || true
EOF
chmod 700 "$run_script"
if [ -L "$run_script" ] || [ ! -f "$run_script" ] ||
   [ "$(file_mode "$run_script")" != "700" ]; then
  echo "Could not create private annotations control evidence safely." >&2
  exit 1
fi
validate_control_tripwire "$control_target" || exit 1
install_control_file "$run_script" "$control_target" || exit 1
cleanup_control_dir
CONTROL_DIR=""
run_script="$control_target"
control_sha="$(file_sha256 "$control_target")"

docker_args=(
  run
  --rm
  --platform "$PLATFORM"
  -e "SP11_RESET_SOURCE=$RESET_SOURCE"
  -e "SP11_KEEP_SOURCE=$KEEP_SOURCE"
  -v "$repo_dir:/repo:ro"
  -v "$work_abs:/work"
)

if [ "$CONTAINER_WORK_DIR" != "/work" ]; then
  docker_args+=(-v "$LINUX_WORK_VOLUME:$CONTAINER_WORK_DIR")
fi

docker_args+=("$IMAGE" /work/docker-regenerate-inside.sh)

if [ "$DRY_RUN" = "true" ]; then
  printf 'Docker command:\n  docker'
  printf ' %q' "${docker_args[@]}"
  printf '\n\nHost work dir: %s\n' "$work_abs"
  printf 'Patch will be written to: %s/0001-debian-qcom-x1e-update-annotations-for-%s.patch\n' \
    "$patch_dir_abs" "$version_token"
  exit 0
fi

prepare_container_output_path "$src_patch" || exit 1
prepare_container_output_path "$annotations_after" || exit 1
require_tool docker

set +e
docker "${docker_args[@]}"
docker_status=$?
set -e
if [ "$docker_status" -ne 0 ]; then
  echo "Docker annotations regeneration failed; inspect the log above." >&2
  exit "$docker_status"
fi

validate_generated_patch "$src_patch" || exit 1
if [ -L "$annotations_after" ] ||
   { [ -e "$annotations_after" ] && [ ! -f "$annotations_after" ]; }; then
  echo "Generated annotations evidence must be a regular, non-symlinked file: $annotations_after" >&2
  exit 1
fi
validate_control_tripwire "$control_target" || exit 1
if [ ! -f "$control_target" ] || [ "$(file_mode "$control_target")" != "700" ] ||
   [ "$(file_sha256 "$control_target")" != "$control_sha" ]; then
  echo "Annotations control evidence changed type, mode, or bytes during Docker execution: $control_target" >&2
  exit 1
fi

# Copy the generated patch into a private unpredictable leaf on the destination
# filesystem. Validate the staged bytes before replacing any exact 0001 leaf.
preflight_patch_leaves || exit 1
src_sha_before="$(file_sha256 "$src_patch")"
PATCH_STAGE="$(mktemp "$patch_dir_abs/.sp11-annotations-patch.XXXXXX")"
if [ -L "$PATCH_STAGE" ] || [ ! -f "$PATCH_STAGE" ]; then
  echo "Could not create a regular annotations patch stage safely." >&2
  exit 1
fi
cp "$src_patch" "$PATCH_STAGE"
chmod 644 "$PATCH_STAGE"
validate_generated_patch "$PATCH_STAGE" || exit 1
src_sha_after="$(file_sha256 "$src_patch")"
stage_sha="$(file_sha256 "$PATCH_STAGE")"
if [ "$src_sha_before" != "$src_sha_after" ] ||
   [ "$src_sha_before" != "$stage_sha" ]; then
  echo "Generated annotations patch changed while it was being staged." >&2
  exit 1
fi

# Recheck every managed leaf immediately before the atomic destination rename.
# mv replaces a regular or symlink leaf itself and never opens its contents.
preflight_patch_leaves || exit 1
if ! mv -f "$PATCH_STAGE" "$dst_patch"; then
  echo "Could not atomically install regenerated annotations patch: $dst_patch" >&2
  exit 1
fi
PATCH_STAGE=""
if [ -L "$dst_patch" ] || [ ! -f "$dst_patch" ] ||
   [ "$(file_sha256 "$dst_patch")" != "$stage_sha" ]; then
  echo "Installed annotations patch failed its post-rename identity check: $dst_patch" >&2
  exit 1
fi

# Remove stale exact annotations leaves only after the new patch is safely in
# place. Files with any other name are deliberately outside this script's scope.
preflight_patch_leaves || exit 1
shopt -s nullglob
for old in "$patch_dir_abs"/0001-*.patch; do
  if [ "$old" != "$dst_patch" ]; then
    echo "Removing stale annotations patch: $old"
    rm -f "$old"
  fi
done
shopt -u nullglob

echo
echo "Installed regenerated patch:"
echo "  $dst_patch"
echo
echo "Next steps:"
echo "  Rerun your build-sp11-qcom-x1e-kernel-docker.sh command with --reset-source."
echo "  The new patch will be picked up automatically from $PATCH_DIR."
