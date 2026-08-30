package build

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	// containerBuildTarget is the only Debian package target exposed by this CLI.
	containerBuildTarget = "binary-qcom-x1e"
	// containerMinimumFreeGiB preserves the established kernel free-space guard.
	containerMinimumFreeGiB = 40
	// containerRecipeTemplate is the complete container-side build policy template.
	containerRecipeTemplate = `#!/usr/bin/env bash
set -euo pipefail
umask 022

git_url="$1"
git_ref="$2"
jobs="$3"
reset_source="$4"
skip_clean="$5"
recipe_sha256="${LINUX_ARMER_RECIPE_SHA256:?}"

work_root=/linux-work
source_parent="$work_root/source"
source_dir="$source_parent/kernel"
artifact_dir=/exchange/artifacts
provenance_dir=/exchange/provenance

release_exchange_outputs() {
  chmod -R a+rwX "$artifact_dir" "$provenance_dir" 2>/dev/null || true
}
trap release_exchange_outputs EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates cpio debhelper devscripts dpkg-dev \
  dwarves equivs flex git kmod libelf-dev libssl-dev python3 python3-dev rsync

mkdir -p "$source_parent" "$artifact_dir" "$provenance_dir"
if [ -e "$source_dir" ] && [ ! -d "$source_dir" ]; then
  echo "Managed source path is not a directory: $source_dir" >&2
  exit 1
fi
if [ -d "$source_dir" ] && [ ! -d "$source_dir/.git" ]; then
  if [ "$reset_source" = true ]; then
    rm -rf -- "$source_dir"
  else
    echo "Managed source path is not a Git work tree; use --reset-source." >&2
    exit 1
  fi
fi
if [ ! -d "$source_dir" ]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init
  git -C "$source_dir" remote add origin "$git_url"
else
  actual_remote="$(git -C "$source_dir" remote get-url origin)"
  if [ "$actual_remote" != "$git_url" ]; then
    echo "Managed source remote differs from the requested HTTPS repository." >&2
    exit 1
  fi
  if [ "$reset_source" = true ]; then
    git -C "$source_dir" reset --hard
    git -C "$source_dir" clean -ffdx
  else
    git -C "$source_dir" diff --quiet
    git -C "$source_dir" diff --cached --quiet
    test -z "$(git -C "$source_dir" ls-files --others --exclude-standard)"
  fi
fi

ref_kind=""
if git ls-remote --exit-code --heads "$git_url" "refs/heads/$git_ref" >/dev/null; then
  ref_kind=branch
  git -C "$source_dir" fetch --force --depth=1 origin "refs/heads/$git_ref"
elif git ls-remote --exit-code --tags "$git_url" "refs/tags/$git_ref" >/dev/null; then
  ref_kind=tag
  git -C "$source_dir" fetch --force --depth=1 origin "refs/tags/$git_ref"
else
  echo "Requested Git ref is not a branch or tag: $git_ref" >&2
  exit 1
fi

revision="$(git -C "$source_dir" rev-parse --verify 'FETCH_HEAD^{commit}')"
if git -C "$source_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  local_commits="$(git -C "$source_dir" rev-list --count "$revision..HEAD")"
  if [ "$local_commits" != 0 ]; then
    echo "Managed source contains commits outside the requested remote ref; use --reset-source." >&2
    exit 1
  fi
fi
git -C "$source_dir" checkout --detach "$revision"
git -C "$source_dir" reset --hard "$revision"
test -z "$(git -C "$source_dir" status --porcelain)"

tree="$(git -C "$source_dir" rev-parse --verify 'HEAD^{tree}')"
commit_time="$(git -C "$source_dir" show -s --format=%cI HEAD)"
actual_remote="$(git -C "$source_dir" remote get-url origin)"
printf '%s' "$actual_remote" > "$provenance_dir/git-url"
printf '%s' "$git_ref" > "$provenance_dir/git-ref"
printf '%s' "$ref_kind" > "$provenance_dir/ref-kind"
printf '%s' "$revision" > "$provenance_dir/revision"
printf '%s' "$tree" > "$provenance_dir/tree"
printf '%s' "$commit_time" > "$provenance_dir/commit-time"
printf '%s' "$recipe_sha256" > "$provenance_dir/recipe-sha256"

available_kb="$(df -Pk "$work_root" | awk 'NR == 2 { print $4 }')"
required_kb=$(({{MINIMUM_FREE_GIB}} * 1024 * 1024))
if [ -n "$available_kb" ] && [ "$available_kb" -lt "$required_kb" ]; then
  echo "Kernel build requires at least {{MINIMUM_FREE_GIB}} GiB free in the managed Docker volume." >&2
  exit 1
fi

if [ "$jobs" = 0 ]; then
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi
case "$jobs" in
  ''|*[!0-9]*) echo "Invalid compiled job count." >&2; exit 1 ;;
esac
if [ "$jobs" -lt 1 ] || [ "$jobs" -gt 512 ]; then
  echo "Container job count is outside the compiled limit." >&2
  exit 1
fi

if [ -x "$source_dir/debian/rules" ]; then
  rules=debian/rules
elif [ -x "$source_dir/.debian/rules" ]; then
  rules=.debian/rules
else
  echo "Kernel source has no executable Debian rules file." >&2
  exit 1
fi

if [ ! -f "$source_dir/debian/control" ]; then
  (cd "$source_dir" && "$rules" debian/control)
fi
if [ ! -f "$source_dir/debian/control" ]; then
  echo "Kernel source did not produce debian/control." >&2
  exit 1
fi
dependency_dir="$(mktemp -d)"
(cd "$dependency_dir" && mk-build-deps --install --remove \
  --tool 'apt-get -y --no-install-recommends' "$source_dir/debian/control")
dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort | sha256sum | awk '{print $1}' > "$provenance_dir/toolchain-sha256"

export DEB_BUILD_OPTIONS="parallel=$jobs nocheck noautodbgsym"
if [ "$skip_clean" != true ]; then
  (cd "$source_dir" && "$rules" clean)
fi
find "$source_parent" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -delete
(cd "$source_dir" && "$rules" {{BUILD_TARGET}})

find "$source_parent" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print0 |
  sort -z |
  while IFS= read -r -d '' package; do
    name="$(basename "$package")"
    case "$name" in
      linux-image-unsigned-*) continue ;;
      linux-modules-extra-*) continue ;;
      linux-image-*-qcom-x1e_*_arm64.deb|\
      linux-modules-*-qcom-x1e_*_arm64.deb|\
      linux-headers-*-qcom-x1e_*_arm64.deb|\
      linux-qcom-x1e-headers-*_all.deb)
        destination="$artifact_dir/$name"
        if [ -e "$destination" ]; then
          cmp -s "$package" "$destination" || {
            echo "Conflicting generated package basename: $name" >&2
            exit 1
          }
        else
          install -m 0644 "$package" "$destination"
        fi
        ;;
    esac
  done
`
)

// containerRecipe is the immutable recipe produced from compiled policy values.
var containerRecipe = strings.NewReplacer(
	"{{BUILD_TARGET}}", containerBuildTarget,
	"{{MINIMUM_FREE_GIB}}", strconv.Itoa(containerMinimumFreeGiB),
).Replace(containerRecipeTemplate)

// compiledRecipeSHA256 returns the stable identity of the embedded build policy.
func compiledRecipeSHA256() string {
	digest := sha256.Sum256([]byte(containerRecipe))
	return hex.EncodeToString(digest[:])
}
