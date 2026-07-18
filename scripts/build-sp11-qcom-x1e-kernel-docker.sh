#!/usr/bin/env bash
set -euo pipefail

IMAGE=""
PLATFORM="linux/arm64"
WORK_DIR="build/docker-sp11-qcom-x1e-kernel"
CONTAINER_WORK_DIR="/linux-work"
LINUX_WORK_VOLUME="sp11-qcom-x1e-kernel-build"
METADATA=""
SOURCE_MODE="apt"
SOURCE_PACKAGE=""
SOURCE_VERSION=""
GIT_URL=""
GIT_BRANCH=""
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
  --image IMAGE          Docker image. Defaults to ubuntu:26.04 for apt mode
                         and ubuntu:25.10 for git mode.
  --platform PLATFORM    Docker platform, default $PLATFORM.
  --work-dir DIR         Host control/artifact directory, default $WORK_DIR.
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
  --payload-dir DIR      Payload directory; also enables --copy-to-payload.
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
    -print | sort -u
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

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

if [ -z "$IMAGE" ]; then
  case "$SOURCE_MODE" in
    git)
      case "$GIT_BRANCH" in
        jg/ubuntu-qcom-x1e-7.1.1-*) IMAGE="ubuntu:26.04" ;;
        *) IMAGE="ubuntu:25.10" ;;
      esac
      ;;
    *) IMAGE="ubuntu:26.04" ;;
  esac
fi

case "$CONTAINER_WORK_DIR" in
  /*) ;;
  *)
    echo "--container-work-dir must be an absolute container path." >&2
    exit 2
    ;;
esac

case "$CONTAINER_WORK_DIR" in
  /work/*)
    echo "--container-work-dir must not be nested under /work." >&2
    echo "Use /work for the host-mounted work dir or keep the default /linux-work volume." >&2
    exit 2
    ;;
esac

if [ "$CONTAINER_WORK_DIR" != "/work" ] && [ -z "$LINUX_WORK_VOLUME" ]; then
  echo "--linux-work-volume must not be empty when --container-work-dir is not /work." >&2
  exit 2
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

mkdir -p "$WORK_DIR"
work_abs="$(abs_path "$WORK_DIR")"

if [ "$CONTAINER_WORK_DIR" = "/work" ] && is_case_insensitive_dir "$work_abs"; then
  echo "Refusing to build Linux kernel source on a case-insensitive host work directory:" >&2
  echo "  $work_abs" >&2
  echo "Use the default Docker Linux work volume, or pass a case-sensitive host filesystem." >&2
  exit 1
fi

if [ "$DRY_RUN" != "true" ]; then
  require_tool docker
fi

args_file="$work_abs/docker-build-args.txt"
run_script="$work_abs/docker-build-inside.sh"

inner_args=(
  --source "$SOURCE_MODE"
  --work-dir "$CONTAINER_WORK_DIR"
  --install-deps
  --no-fakeroot
)

case "$SOURCE_MODE" in
  apt)
    inner_args+=(--source-package "$SOURCE_PACKAGE" --source-version "$SOURCE_VERSION")
    ;;
  git)
    [ -n "$GIT_URL" ] && inner_args+=(--git-url "$GIT_URL")
    [ -n "$GIT_BRANCH" ] && inner_args+=(--git-branch "$GIT_BRANCH")
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

mapfile -t build_args < /work/docker-build-args.txt
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
    -print | sort -u
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
chmod +x "$run_script"

docker_args=(
  run
  --rm
  --platform "$PLATFORM"
  -e "SP11_ENABLE_DEB_SRC=$ENABLE_DEB_SRC"
  -e "SP11_APT_SOURCES_NAME=$(basename "${APT_SOURCES_FILE:-sp11-qcom-x1e.sources}")"
  -e "SP11_CONTAINER_WORK_DIR=$CONTAINER_WORK_DIR"
  -v "$repo_dir:/repo:ro"
  -v "$work_abs:/work"
)

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
  payload_abs="$(repo_abs_path "$PAYLOAD_DIR")"
  mkdir -p "$payload_abs"
  if [ -z "$generated_debs" ]; then
    echo "Cannot copy to payload because no qcom-x1e kernel packages were found." >&2
    exit 1
  fi
  find "$payload_abs" -maxdepth 1 -type f -name '*.deb' -delete
  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    cp -f "$deb" "$payload_abs/"
  done <<<"$generated_debs"
  echo
  echo "Copied generated qcom-x1e .deb files to: $payload_abs"
  echo "Rebuild the live USB image so payload/kernel-debs is available on SP11DATA."
fi
