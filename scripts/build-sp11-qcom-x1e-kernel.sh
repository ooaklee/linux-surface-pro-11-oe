#!/usr/bin/env bash
set -euo pipefail

SOURCE_MODE="apt"
SOURCE_PACKAGE="installed"
SOURCE_VERSION="installed"
GIT_URL="https://git.launchpad.net/~ubuntu-concept/ubuntu/+source/linux/+git/resolute"
GIT_BRANCH="qcom-x1e-7.0"
BUILD_TARGET="binary-qcom-x1e"
WORK_DIR="${HOME}/sp11-qcom-x1e-kernel-build"
PATCH_DIR=""
PATCH_DIRS=""
MIN_FREE_GB=40
INSTALL_DEPS="false"
INSTALL_DEBS="false"
INSTALL_ONLY="false"
PREPARE_ONLY="false"
RESET_SOURCE="false"
ALLOW_NON_ARM64="false"
ALLOW_NO_FALLBACK="false"
SKIP_CLEAN="false"
NO_FAKEROOT="false"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
SOURCE_SPEC=""
RESOLVED_SOURCE_PACKAGE=""

usage() {
  cat <<EOF
Usage: $0 [options]

Builds an Ubuntu qcom-x1e kernel with Surface Pro 11 Wi-Fi rfkill patches.

Default source mode is apt, which derives the source package and version from
the running qcom-x1e kernel packages on the device.

Options:
  --source MODE          Source mode: apt or git, default $SOURCE_MODE.
  --source-package NAME  Source package for apt mode, default $SOURCE_PACKAGE
                         (derive from the running kernel).
  --source-version VER   apt source version: installed, candidate, or exact.
                         Default $SOURCE_VERSION.
  --git-url URL          Kernel git URL for git mode, default $GIT_URL.
  --git-branch BRANCH    Kernel git branch or tag for git mode, default $GIT_BRANCH.
  --patch-dir DIR        Patch directory, default repo patches/ubuntu-qcom-x1e-7.0.
  --patch-dirs "DIR1 DIR2 ..."
                        Space-separated list of patch directories. Patches from
                        each directory are applied in order.
  --work-dir DIR         Build work directory, default $WORK_DIR.
  --build-target TARGET  Kernel package target or quoted target list,
                         default $BUILD_TARGET.
  --jobs N              Parallel build jobs, default detected CPU count.
  --min-free-gb N        Required free space in work dir, default $MIN_FREE_GB.
  --install-deps        Install common build dependencies and apt build-deps.
  --install             Install generated qcom-x1e kernel debs after build.
  --install-only        Install existing generated qcom-x1e debs and exit.
  --prepare-only        Clone/download and apply patches, then stop.
  --reset-source        Remove existing source directory before preparing.
  --skip-clean          Skip debian/rules clean before building.
  --no-fakeroot         Run debian/rules directly when running as root.
  --allow-non-arm64     Allow prepare/build on a non-aarch64 host.
  --allow-no-fallback   Allow install with no older qcom-x1e kernel fallback.
  -h, --help            Show this help.

The build can take hours and needs substantial free disk space. Keep an older
known-good qcom-x1e kernel installed as a GRUB fallback.
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    require_tool sudo
    sudo "$@"
  fi
}

run_rules() {
  local rules_file="$1"
  shift

  if [ "$(id -u)" -eq 0 ]; then
    "$rules_file" "$@"
    return
  fi

  if [ "$NO_FAKEROOT" = "true" ]; then
    echo "--no-fakeroot requires running as root." >&2
    exit 1
  fi

  fakeroot "$rules_file" "$@"
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE_MODE="$2"
      shift 2
      ;;
    --source-package)
      SOURCE_PACKAGE="$2"
      shift 2
      ;;
    --source-version)
      SOURCE_VERSION="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    --git-branch)
      GIT_BRANCH="$2"
      shift 2
      ;;
    --patch-dir)
      PATCH_DIR="$2"
      shift 2
      ;;
    --patch-dirs)
      PATCH_DIRS="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --build-target)
      BUILD_TARGET="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --min-free-gb)
      MIN_FREE_GB="$2"
      shift 2
      ;;
    --install-deps)
      INSTALL_DEPS="true"
      shift
      ;;
    --install)
      INSTALL_DEBS="true"
      shift
      ;;
    --install-only)
      INSTALL_ONLY="true"
      shift
      ;;
    --prepare-only)
      PREPARE_ONLY="true"
      shift
      ;;
    --reset-source)
      RESET_SOURCE="true"
      shift
      ;;
    --skip-clean)
      SKIP_CLEAN="true"
      shift
      ;;
    --no-fakeroot)
      NO_FAKEROOT="true"
      shift
      ;;
    --allow-non-arm64)
      ALLOW_NON_ARM64="true"
      shift
      ;;
    --allow-no-fallback)
      ALLOW_NO_FALLBACK="true"
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

if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [ "$JOBS" -lt 1 ]; then
  echo "--jobs must be a positive integer." >&2
  exit 2
fi

if ! [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || [ "$MIN_FREE_GB" -lt 1 ]; then
  echo "--min-free-gb must be a positive integer." >&2
  exit 2
fi

PATCH_DIR="${PATCH_DIR:-$repo_dir/patches/ubuntu-qcom-x1e-7.0}"
if [ -n "$PATCH_DIRS" ]; then
  for pd in $PATCH_DIRS; do
    if [ ! -d "$pd" ]; then
      echo "Patch directory not found: $pd" >&2
      exit 1
    fi
  done
elif [ "$INSTALL_ONLY" != "true" ] && [ ! -d "$PATCH_DIR" ]; then
  echo "Patch directory not found: $PATCH_DIR" >&2
  exit 1
fi

host_os="$(uname -s)"
host_arch="$(uname -m)"
if [ "$PREPARE_ONLY" != "true" ] && [ "$ALLOW_NON_ARM64" != "true" ]; then
  if [ "$host_os" != "Linux" ] || { [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ]; }; then
    echo "Kernel build should run on a Linux aarch64 host, ideally the installed Surface Pro 11." >&2
    echo "Pass --prepare-only to only validate patch application on this host." >&2
    exit 1
  fi
fi

if [ "$SOURCE_MODE" = "apt" ] && [ "$host_os" != "Linux" ]; then
  echo "apt source mode requires Linux apt tooling." >&2
  echo "Use --source git for prepare-only patch validation on this host." >&2
  exit 1
fi

if [ "$INSTALL_ONLY" != "true" ]; then
  require_tool git
fi

mkdir -p "$WORK_DIR"
work_dir="$(cd "$WORK_DIR" && pwd)"
source_parent="$work_dir/source"
source_dir=""
mkdir -p "$source_parent"

install_dependencies() {
  require_tool dpkg-query

  local deps source_pkg
  deps=(
    bc
    bison
    build-essential
    cpio
    debhelper
    devscripts
    dpkg-dev
    dwarves
    equivs
    flex
    git
    kmod
    libelf-dev
    libssl-dev
    python3
    python3-dev
    rsync
  )

  if [ "$(id -u)" -ne 0 ] && [ "$NO_FAKEROOT" != "true" ]; then
    deps+=(fakeroot)
  fi

  as_root apt-get update
  as_root apt-get install -y --no-install-recommends "${deps[@]}"

  if [ "$SOURCE_MODE" = "apt" ]; then
    source_pkg="$(resolve_apt_source_package)"
    if ! as_root apt-get build-dep -y "$source_pkg"; then
      echo "apt build-dep failed for $source_pkg." >&2
      echo "Enable matching deb-src entries for the repositories that provide the qcom-x1e source package, then rerun apt update." >&2
      echo "For bring-up without matching source repositories, retry with --source git." >&2
      exit 1
    fi
  fi
}

install_source_build_dependencies() {
  local control_file="$source_dir/debian/control" rules_file

  [ "$INSTALL_DEPS" = "true" ] || return 0
  [ "$SOURCE_MODE" = "git" ] || return 0

  if [ ! -f "$control_file" ]; then
    rules_file="$(find_rules_file)"
    (
      cd "$source_dir"
      run_rules "$rules_file" debian/control
    )
  fi

  if [ ! -f "$control_file" ]; then
    echo "Cannot install git source build dependencies; missing $control_file." >&2
    exit 1
  fi

  (
    cd "$work_dir"
    as_root mk-build-deps \
      --install \
      --remove \
      --tool "apt-get -y --no-install-recommends" \
      "$control_file"
  )
}

check_free_space() {
  local available_kb required_kb
  available_kb="$(df -Pk "$work_dir" | awk 'NR == 2 { print $4 }')"
  required_kb=$((MIN_FREE_GB * 1024 * 1024))
  if [ -n "$available_kb" ] && [ "$available_kb" -lt "$required_kb" ]; then
    echo "Not enough free space for a kernel build under $work_dir." >&2
    echo "Available: $((available_kb / 1024 / 1024)) GiB; required: ${MIN_FREE_GB} GiB." >&2
    exit 1
  fi
}

installed_kernel_package_field() {
  local field release pkg value
  field="$1"
  release="$(uname -r 2>/dev/null || true)"
  [ -n "$release" ] || return 0

  for pkg in \
    "linux-modules-$release" \
    "linux-headers-$release" \
    "linux-image-unsigned-$release" \
    "linux-image-$release"; do
    value="$(dpkg-query -W -f="\${$field}" "$pkg" 2>/dev/null || true)"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
}

resolve_apt_source_package() {
  local source_pkg

  if [ "$SOURCE_PACKAGE" != "installed" ]; then
    printf '%s\n' "$SOURCE_PACKAGE"
    return 0
  fi

  source_pkg="$(installed_kernel_package_field 'source:Package')"
  if [ -n "$source_pkg" ]; then
    printf '%s\n' "$source_pkg"
    return 0
  fi

  echo "Could not derive the running kernel source package; falling back to linux." >&2
  printf '%s\n' "linux"
}

resolve_installed_source_version() {
  installed_kernel_package_field 'source:Version'
}

ensure_clean_source() {
  local dir="$1"

  if [ ! -d "$dir" ]; then
    return 0
  fi

  if [ "$RESET_SOURCE" = "true" ]; then
    if [ -d "$dir/.git" ]; then
      git -C "$dir" reset --hard
      git -C "$dir" clean -ffdx
    else
      rm -rf "$dir"
    fi
    return 0
  fi

  if [ -d "$dir/.git" ]; then
    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
      echo "Existing source tree has local changes: $dir" >&2
      echo "Commit/stash them or rerun with --reset-source." >&2
      exit 1
    fi
    if [ -n "$(git -C "$dir" ls-files --others --exclude-standard)" ]; then
      echo "Existing source tree has untracked files: $dir" >&2
      echo "Remove them or rerun with --reset-source." >&2
      exit 1
    fi
  else
    echo "Existing non-git source directory found: $dir" >&2
    echo "Move it away or rerun with --reset-source." >&2
    exit 1
  fi
}

prepare_git_source() {
  local safe_branch dir local_commits ref_kind
  safe_branch="${GIT_BRANCH//\//-}"
  dir="$source_parent/git-$safe_branch"
  ref_kind=""

  ensure_clean_source "$dir"
  if [ ! -d "$dir" ]; then
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$dir"
  else
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$GIT_BRANCH"; then
      ref_kind="head"
    elif git -C "$dir" show-ref --verify --quiet "refs/tags/$GIT_BRANCH"; then
      ref_kind="tag"
    elif git ls-remote --exit-code --heads "$GIT_URL" "$GIT_BRANCH" >/dev/null 2>&1; then
      ref_kind="head"
    elif git ls-remote --exit-code --tags "$GIT_URL" "$GIT_BRANCH" >/dev/null 2>&1; then
      ref_kind="tag"
    else
      echo "Git ref not found as a branch or tag: $GIT_BRANCH" >&2
      echo "Remote: $GIT_URL" >&2
      exit 1
    fi
    if [ "$ref_kind" = "head" ]; then
      git -C "$dir" fetch origin "$GIT_BRANCH"
      git -C "$dir" checkout "$GIT_BRANCH"
      local_commits="$(git -C "$dir" rev-list --count "origin/$GIT_BRANCH..HEAD" 2>/dev/null || echo 0)"
      if [ "$local_commits" != "0" ]; then
        echo "Existing source tree has local commits not present in origin/$GIT_BRANCH: $dir" >&2
        echo "Move them away or rerun with --reset-source." >&2
        exit 1
      fi
      git -C "$dir" reset --hard "origin/$GIT_BRANCH"
    else
      if ! git -C "$dir" show-ref --verify --quiet "refs/tags/$GIT_BRANCH"; then
        git -C "$dir" fetch --force origin "refs/tags/$GIT_BRANCH:refs/tags/$GIT_BRANCH"
      fi
      git -C "$dir" checkout --detach "refs/tags/$GIT_BRANCH"
      git -C "$dir" reset --hard "refs/tags/$GIT_BRANCH"
    fi
  fi

  source_dir="$dir"
}

prepare_apt_source() {
  require_tool apt-get
  require_tool apt-cache
  require_tool dpkg-query

  local before after new_dirs source_spec version source_pkg
  before="$(mktemp)"
  after="$(mktemp)"
  source_pkg="$(resolve_apt_source_package)"
  RESOLVED_SOURCE_PACKAGE="$source_pkg"

  if [ "$RESET_SOURCE" = "true" ]; then
    rm -rf "$source_parent"
    mkdir -p "$source_parent"
  elif find "$source_parent" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    echo "Existing apt source directories found under $source_parent." >&2
    echo "Rerun with --reset-source to avoid rebuilding from stale or modified source trees." >&2
    exit 1
  fi

  case "$SOURCE_VERSION" in
    installed)
      version="$(resolve_installed_source_version)"
      if [ -z "$version" ]; then
        echo "Could not derive the running kernel source version; apt source will use the default source candidate." >&2
      fi
      ;;
    candidate)
      version="$(apt-cache showsrc "$source_pkg" 2>/dev/null | awk '/^Version:/ { print $2; exit }')"
      ;;
    "")
      version=""
      ;;
    *)
      version="$SOURCE_VERSION"
      ;;
  esac

  if [ -n "$version" ]; then
    source_spec="$source_pkg=$version"
  else
    source_spec="$source_pkg"
  fi
  SOURCE_SPEC="$source_spec"

  find "$source_parent" -mindepth 1 -maxdepth 1 -type d -print | sort > "$before"
  if ! (
    cd "$source_parent"
    apt-get source "$source_spec"
  ); then
    rm -f "$before" "$after"
    echo "apt source failed for $source_spec." >&2
    echo "Enable matching deb-src entries for the repositories that provide the running qcom-x1e kernel packages, then rerun sudo apt update." >&2
    if [ "$SOURCE_VERSION" = "installed" ]; then
      echo "The requested version was derived from the installed kernel package source metadata." >&2
      echo "If that source version is no longer available, retry with --source-version candidate." >&2
    fi
    exit 1
  fi
  find "$source_parent" -mindepth 1 -maxdepth 1 -type d -print | sort > "$after"
  new_dirs="$(comm -13 "$before" "$after")"
  rm -f "$before" "$after"

  if [ -z "$new_dirs" ]; then
    source_dir="$(find "$source_parent" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 { sub(/^[^ ]+ /, ""); print }')"
  else
    source_dir="$(printf '%s\n' "$new_dirs" | head -n 1)"
  fi

  if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
    echo "Could not find unpacked apt source under $source_parent." >&2
    echo "If apt source failed, enable deb-src entries for the running qcom-x1e kernel source." >&2
    exit 1
  fi

  echo "Using apt source: $source_spec"
}

apply_patches() {
  local patch_dir_list

  if [ -n "$PATCH_DIRS" ]; then
    patch_dir_list="$PATCH_DIRS"
  else
    patch_dir_list="$PATCH_DIR"
  fi

  for pd in $patch_dir_list; do
    echo "Applying patches from $pd"

    for patch in "$pd"/*.patch; do
      [ -f "$patch" ] || continue

      case "$(basename "$patch")" in
        0001-wifi-ath12k-add-disable-rfkill-devicetree.patch)
          if grep -q 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
            "$source_dir/drivers/net/wireless/ath/ath12k/core.c"; then
            echo "Already satisfied: $(basename "$patch")"
            continue
          fi
          ;;
        0002-arm64-dts-qcom-x1-denali-disable-rfkill-for-wifi.patch)
          if grep -q 'disable-rfkill;' \
            "$source_dir/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"; then
            echo "Already satisfied: $(basename "$patch")"
            continue
          fi
          ;;
      esac

      if git -C "$source_dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "Already applied: $(basename "$patch")"
        continue
      fi

      echo "Applying: $(basename "$patch")"
      git -C "$source_dir" apply --check "$patch"
      git -C "$source_dir" apply "$patch"
    done
  done

  grep -q 'of_property_read_bool(ab->dev->of_node, "disable-rfkill")' \
    "$source_dir/drivers/net/wireless/ath/ath12k/core.c"
  grep -q 'disable-rfkill;' \
    "$source_dir/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi"
}

find_rules_file() {
  if [ -x "$source_dir/debian/rules" ]; then
    printf '%s\n' "debian/rules"
  elif [ -x "$source_dir/.debian/rules" ]; then
    printf '%s\n' ".debian/rules"
  else
    echo "Could not find executable debian/rules or .debian/rules in $source_dir." >&2
    exit 1
  fi
}

write_manifest() {
  local manifest="$work_dir/sp11-kernel-build-manifest.txt"

  {
    echo "Source mode: $SOURCE_MODE"
    if [ "$SOURCE_MODE" = "apt" ]; then
      echo "Requested source package: $SOURCE_PACKAGE"
      echo "Resolved source package: $RESOLVED_SOURCE_PACKAGE"
      echo "Source version mode: $SOURCE_VERSION"
      echo "Apt source spec: $SOURCE_SPEC"
    fi
    echo "Source directory: $source_dir"
    if [ -d "$source_dir/.git" ]; then
      echo "Source HEAD: $(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [ -n "$PATCH_DIRS" ]; then
      echo "Patch directories: $PATCH_DIRS"
      for pd in $PATCH_DIRS; do
        echo "Patches in $pd:"
        for patch in "$pd"/*.patch; do
          [ -f "$patch" ] && echo "  - $(basename "$patch")"
        done
      done
    else
      echo "Patch directory: $PATCH_DIR"
      echo "Patches:"
      for patch in "$PATCH_DIR"/*.patch; do
        [ -f "$patch" ] && echo "  - $(basename "$patch")"
      done
    fi
    echo "Build target: $BUILD_TARGET"
    echo "Jobs: $JOBS"
    if [ "$(id -u)" -eq 0 ]; then
      echo "Rules runner: direct-root"
    elif [ "$NO_FAKEROOT" = "true" ]; then
      echo "Rules runner: no-fakeroot-requested-non-root"
    else
      echo "Rules runner: fakeroot"
    fi
  } > "$manifest"

  echo "Wrote build manifest: $manifest"
}

collect_kernel_debs() {
  {
    find "$source_parent" -maxdepth 2 -type f \
      \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
      -o -name 'linux-image-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
      -o -name 'linux-headers-*-qcom-x1e_*.deb' \
      -o -name 'linux-qcom-x1e-headers-*_*.deb' \
      -o -name 'linux-qcom-x1e_*.deb' \
      -o -name 'linux-image-qcom-x1e_*.deb' \
      -o -name 'linux-headers-qcom-x1e_*.deb' \)
    find "$work_dir" -maxdepth 2 -type f \
      \( -name 'linux-image-unsigned-*-qcom-x1e_*.deb' \
      -o -name 'linux-image-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-*-qcom-x1e_*.deb' \
      -o -name 'linux-modules-extra-*-qcom-x1e_*.deb' \
      -o -name 'linux-headers-*-qcom-x1e_*.deb' \
      -o -name 'linux-qcom-x1e-headers-*_*.deb' \
      -o -name 'linux-qcom-x1e_*.deb' \
      -o -name 'linux-image-qcom-x1e_*.deb' \
      -o -name 'linux-headers-qcom-x1e_*.deb' \)
  } |
    sort -u
}

deb_kernel_abi() {
  local base abi
  base="$(basename "$1")"

  case "$base" in
    linux-image-unsigned-*-qcom-x1e_*.deb)
      abi="${base#linux-image-unsigned-}"
      abi="${abi%%_*}"
      ;;
    linux-image-*-qcom-x1e_*.deb)
      abi="${base#linux-image-}"
      abi="${abi%%_*}"
      ;;
    *)
      return 0
      ;;
  esac

  case "$abi" in
    [0-9]*-qcom-x1e) printf '%s\n' "$abi" ;;
  esac
}

installed_kernel_abis() {
  local status pkg abi

  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
    'linux-image-*-qcom-x1e' \
    'linux-image-unsigned-*-qcom-x1e' 2>/dev/null |
    while read -r status pkg; do
      case "$status" in
        ?i*) ;;
        *) continue ;;
      esac
      case "$pkg" in
        linux-image-unsigned-*)
          abi="${pkg#linux-image-unsigned-}"
          ;;
        linux-image-*)
          abi="${pkg#linux-image-}"
          ;;
        *)
          continue
          ;;
      esac
      case "$abi" in
        [0-9]*-qcom-x1e) printf '%s\n' "$abi" ;;
      esac
    done |
    sort -u
}

ensure_kernel_fallback() {
  local target_abis installed_abis fallback_abi deb abi

  [ "$ALLOW_NO_FALLBACK" = "true" ] && return 0

  target_abis="$(
    for deb in "$@"; do
      deb_kernel_abi "$deb"
    done | sort -u
  )"
  # Headers/modules-only transactions do not replace a bootable kernel image.
  [ -n "$target_abis" ] || return 0

  installed_abis="$(installed_kernel_abis || true)"
  fallback_abi=""
  while IFS= read -r abi; do
    [ -n "$abi" ] || continue
    if ! printf '%s\n' "$target_abis" | grep -Fxq "$abi"; then
      fallback_abi="$abi"
      break
    fi
  done <<<"$installed_abis"

  if [ -z "$fallback_abi" ]; then
    echo "Refusing to install generated qcom-x1e kernel packages without an installed fallback ABI." >&2
    echo "Generated image ABI/ABIs:" >&2
    printf '%s\n' "$target_abis" | sed 's/^/  - /' >&2
    echo "Installed qcom-x1e image ABI/ABIs:" >&2
    if [ -n "$installed_abis" ]; then
      printf '%s\n' "$installed_abis" | sed 's/^/  - /' >&2
    else
      echo "  - none detected" >&2
    fi
    echo "Keep or install an older known-good qcom-x1e kernel first, or pass --allow-no-fallback if you accept live-USB recovery as the fallback." >&2
    exit 1
  fi

  echo "Found installed fallback qcom-x1e kernel ABI: $fallback_abi"
}

ensure_header_dependencies_present() {
  local deb base abi common_pkg common_found

  for deb in "$@"; do
    base="$(basename "$deb")"
    case "$base" in
      linux-headers-*-qcom-x1e_*.deb)
        abi="${base#linux-headers-}"
        abi="${abi%%-qcom-x1e_*}"
        common_pkg="linux-qcom-x1e-headers-${abi}_"
        common_found="false"
        for candidate in "$@"; do
          case "$(basename "$candidate")" in
            "${common_pkg}"*_all.deb)
              common_found="true"
              break
              ;;
          esac
        done
        if [ "$common_found" != "true" ]; then
          echo "Missing common qcom-x1e headers package for $base." >&2
          echo "Expected a local package matching: ${common_pkg}*_all.deb" >&2
          echo "Rebuild the payload with:" >&2
          echo "  --build-target \"binary-indep binary-qcom-x1e\"" >&2
          echo "For boot-only recovery, install the linux-image and linux-modules packages without linux-headers." >&2
          exit 1
        fi
        ;;
    esac
  done
}

write_deb_manifest() {
  collect_kernel_debs > "$work_dir/sp11-kernel-debs.txt"
}

build_kernel() {
  local rules_file target build_targets=()
  rules_file="$(find_rules_file)"
  read -r -a build_targets <<<"$BUILD_TARGET"
  if [ "${#build_targets[@]}" -eq 0 ]; then
    echo "No build target specified." >&2
    exit 2
  fi

  (
    cd "$source_dir"
    export DEB_BUILD_OPTIONS="parallel=$JOBS nocheck noautodbgsym"
    if [ "$SKIP_CLEAN" != "true" ]; then
      run_rules "$rules_file" clean
    fi
    for target in "${build_targets[@]}"; do
      run_rules "$rules_file" "$target"
    done
  )
}

install_kernel_debs() {
  require_tool dpkg-query

  local debs=()
  if [ -f "$work_dir/sp11-kernel-debs.txt" ]; then
    while IFS= read -r deb; do
      [ -f "$deb" ] && debs+=("$deb")
    done < "$work_dir/sp11-kernel-debs.txt"
  fi
  if [ "${#debs[@]}" -eq 0 ]; then
    while IFS= read -r deb; do
      debs+=("$deb")
    done < <(collect_kernel_debs)
  fi

  if [ "${#debs[@]}" -eq 0 ]; then
    echo "No qcom-x1e kernel debs found under $work_dir." >&2
    exit 1
  fi

  printf 'Installing generated kernel debs:\n'
  printf '  %s\n' "${debs[@]}"
  ensure_header_dependencies_present "${debs[@]}"
  ensure_kernel_fallback "${debs[@]}"
  as_root apt install --reinstall "${debs[@]}"

  if [ -x "$repo_dir/scripts/install-sp11-support.sh" ]; then
    as_root "$repo_dir/scripts/install-sp11-support.sh" --installed-system
  elif command -v /usr/local/sbin/sp11-grub-inject-dtb >/dev/null 2>&1; then
    as_root update-grub
    as_root /usr/local/sbin/sp11-grub-inject-dtb
  fi
}

if [ "$INSTALL_ONLY" = "true" ]; then
  install_kernel_debs
  exit 0
fi

if [ "$INSTALL_DEPS" = "true" ]; then
  install_dependencies
fi

if [ "$PREPARE_ONLY" != "true" ]; then
  check_free_space
fi

case "$SOURCE_MODE" in
  apt) prepare_apt_source ;;
  git) prepare_git_source ;;
esac

echo "Using source tree: $source_dir"
apply_patches
install_source_build_dependencies
write_manifest

if [ "$PREPARE_ONLY" = "true" ]; then
  echo "Prepare-only mode complete."
  exit 0
fi

build_kernel
write_deb_manifest

echo
echo "Generated kernel packages:"
generated_debs=()
while IFS= read -r deb; do
  generated_debs+=("$deb")
done < <(collect_kernel_debs)
if [ "${#generated_debs[@]}" -gt 0 ]; then
  ls -lh "${generated_debs[@]}"
else
  echo "No qcom-x1e kernel packages found under $work_dir."
fi

if [ "$INSTALL_DEBS" = "true" ]; then
  install_kernel_debs
else
  echo
  echo "Review the generated debs, then install the qcom-x1e image/modules/header packages."
  echo "Reboot into the patched kernel and rerun scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock."
fi
