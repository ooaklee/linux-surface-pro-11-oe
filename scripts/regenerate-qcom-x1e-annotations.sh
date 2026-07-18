#!/usr/bin/env bash
set -euo pipefail

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
PATCH_DIR=""
RESET_SOURCE="false"
KEEP_SOURCE="false"
DRY_RUN="false"

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
  --git-branch BRANCH    Kernel git branch or tag. Required unless --keep-source.
  --patch-dir DIR        Host patch directory to write the regenerated patch
                         into. Defaults to patches/jglathe-qcom-x1e-<version>
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

abs_path() {
  local path="$1"
  if [ -d "$path" ]; then
    (cd "$path" && pwd)
  else
    (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd)" "$(basename "$path")")
  fi
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

if [ "$KEEP_SOURCE" != "true" ]; then
  if [ -z "$GIT_URL" ] || [ -z "$GIT_BRANCH" ]; then
    echo "Either --git-url and --git-branch, or --keep-source, is required." >&2
    usage >&2
    exit 2
  fi
fi

if [ "$KEEP_SOURCE" = "true" ] && [ "$RESET_SOURCE" = "true" ]; then
  echo "--keep-source and --reset-source are mutually exclusive." >&2
  exit 2
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

# Derive the short version token (e.g. "7.1.3-jg-1") from the branch name.
# Branches look like jg/ubuntu-qcom-x1e-<version>, e.g.
#   jg/ubuntu-qcom-x1e-7.1.3-jg-1  ->  7.1.3-jg-1
if [ -n "$GIT_BRANCH" ]; then
  version_token="${GIT_BRANCH#jg/ubuntu-qcom-x1e-}"
  if [ "$version_token" = "$GIT_BRANCH" ]; then
    echo "Could not derive version token from --git-branch: $GIT_BRANCH" >&2
    echo "Expected a branch named jg/ubuntu-qcom-x1e-<version>." >&2
    exit 2
  fi
else
  version_token=""
fi

# --keep-source reuses an existing checked-out tree but still needs the branch
# to locate the source dir and name the output patch.
if [ "$KEEP_SOURCE" = "true" ] && [ -z "$version_token" ]; then
  echo "--keep-source requires --git-branch too (used to locate the source dir and name the patch)." >&2
  exit 2
fi

# Branches follow jg/ubuntu-qcom-x1e-<base>-jg-<n>, e.g.
#   jg/ubuntu-qcom-x1e-7.1.3-jg-1  ->  base "7.1.3",  full "7.1.3-jg-1"
# The patch directory is keyed off <base> (patches/jglathe-qcom-x1e-<base>),
# matching the existing jglathe-qcom-x1e-7.1.1 and ...-7.1.3 directories.
base_version="${version_token%-jg-*}"
if [ "$base_version" = "$version_token" ]; then
  echo "Could not split base version from --git-branch: $GIT_BRANCH" >&2
  echo "Expected a branch named jg/ubuntu-qcom-x1e-<base>-jg-<n>." >&2
  exit 2
fi

if [ -z "$PATCH_DIR" ]; then
  if [ -z "$version_token" ]; then
    echo "Cannot derive --patch-dir without --git-branch; pass --patch-dir explicitly." >&2
    exit 2
  fi
  PATCH_DIR="patches/jglathe-qcom-x1e-${base_version}"
fi

patch_dir_abs="$(abs_path "$PATCH_DIR")"
case "$patch_dir_abs" in
  "$repo_dir"/*) ;;
  *)
    echo "--patch-dir must be inside this repository so Docker can write back to it." >&2
    exit 1
    ;;
esac

if [ ! -d "$patch_dir_abs" ]; then
  echo "Patch directory not found: $patch_dir_abs" >&2
  echo "Create it first (it should hold the other patches for this branch)." >&2
  exit 1
fi

if [ -z "$WORK_DIR" ]; then
  WORK_DIR="build/docker-sp11-qcom-x1e-annotations-${version_token}"
fi
mkdir -p "$WORK_DIR"
work_abs="$(abs_path "$WORK_DIR")"

# Source directory name under CONTAINER_WORK_DIR/source mirrors what
# build-sp11-qcom-x1e-kernel.sh's prepare_git_source() uses:
#   git-<branch with / replaced by ->
safe_branch="${GIT_BRANCH//\//-}"
expected_source_dir="${CONTAINER_WORK_DIR}/source/git-${safe_branch}"

run_script="$work_abs/docker-regenerate-inside.sh"
cat > "$run_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

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

src="${expected_source_dir}"

if [ "\${SP11_KEEP_SOURCE:-false}" = "true" ]; then
  if [ ! -d "\$src" ]; then
    echo "Source tree not found for --keep-source: \$src" >&2
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
    # Detect head vs tag the same way build-sp11-qcom-x1e-kernel.sh does, so
    # refs that are actually tags (like the jg/... refs) don't fail when
    # origin/\$GIT_BRANCH doesn't exist.
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
      git -C "\$src" fetch origin "${GIT_BRANCH}"
      git -C "\$src" checkout "${GIT_BRANCH}"
      git -C "\$src" reset --hard "origin/${GIT_BRANCH}"
    else
      git -C "\$src" fetch --force origin "refs/tags/${GIT_BRANCH}:refs/tags/${GIT_BRANCH}"
      git -C "\$src" checkout --detach "refs/tags/${GIT_BRANCH}"
      git -C "\$src" reset --hard "refs/tags/${GIT_BRANCH}"
    fi
  fi
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
chmod +x "$run_script"

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

require_tool docker

set +e
docker "${docker_args[@]}"
docker_status=$?
set -e
if [ "$docker_status" -ne 0 ]; then
  echo "Docker annotations regeneration failed; inspect the log above." >&2
  exit "$docker_status"
fi

src_patch="$work_abs/0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"
dst_patch="$patch_dir_abs/0001-debian-qcom-x1e-update-annotations-for-${version_token}.patch"

if [ ! -f "$src_patch" ]; then
  echo "Expected regenerated patch not found: $src_patch" >&2
  echo "The container may have failed before writing it." >&2
  exit 1
fi

if [ ! -s "$src_patch" ]; then
  echo "Regenerated patch is empty (no annotations changes): $src_patch" >&2
  echo "olddefconfig produced no diff vs. upstream annotations for ${version_token}." >&2
  echo "The existing patch in $patch_dir_abs is left untouched." >&2
  exit 1
fi

# Remove any prior 0001-debian-qcom-x1e-update-annotations-for-*.patch so a
# stale patch for an older version doesn't linger alongside the new one.
shopt -s nullglob
for old in "$patch_dir_abs"/0001-debian-qcom-x1e-update-annotations-for-*.patch; do
  if [ "$old" != "$dst_patch" ]; then
    echo "Removing stale annotations patch: $old"
    rm -f "$old"
  fi
done
shopt -u nullglob

cp -f "$src_patch" "$dst_patch"
echo
echo "Installed regenerated patch:"
echo "  $dst_patch"
echo
echo "Next steps:"
echo "  Rerun your build-sp11-qcom-x1e-kernel-docker.sh command with --reset-source."
echo "  The new patch will be picked up automatically from $PATCH_DIR."
