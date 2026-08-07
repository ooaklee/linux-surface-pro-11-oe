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

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline_file="${1:-$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env}"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/sp11-patch-smoke.*)
      rm -rf -- "$temporary_root"
      ;;
    *)
      echo "warning: refusing to remove unexpected temporary path: $temporary_root" >&2
      ;;
  esac
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

for tool in git awk sort mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

[ -f "$baseline_file" ] || die "baseline configuration not found: $baseline_file"

# shellcheck disable=SC1090
. "$baseline_file"

: "${SP11_KERNEL_UPSTREAM_URL:?baseline is missing SP11_KERNEL_UPSTREAM_URL}"
: "${SP11_KERNEL_UPSTREAM_REF:?baseline is missing SP11_KERNEL_UPSTREAM_REF}"
: "${SP11_KERNEL_UPSTREAM_COMMIT:?baseline is missing SP11_KERNEL_UPSTREAM_COMMIT}"
: "${SP11_KERNEL_PATCH_DIRS:?baseline is missing SP11_KERNEL_PATCH_DIRS}"

[[ "$SP11_KERNEL_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  die "baseline commit must be a full lowercase 40-hex object ID"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-patch-smoke.XXXXXX")"
source_dir="$temporary_root/source"
paths_file="$temporary_root/paths"
mkdir -p "$source_dir"
: > "$paths_file"

patch_count=0
for patch_dir in $SP11_KERNEL_PATCH_DIRS; do
  case "$patch_dir" in
    /*|*..*) die "patch directory must be a safe repository-relative path: $patch_dir" ;;
  esac
  [ -d "$repo_dir/$patch_dir" ] || die "patch directory not found: $patch_dir"
  for patch in "$repo_dir/$patch_dir"/*.patch; do
    [ -f "$patch" ] || continue
    patch_count=$((patch_count + 1))
    awk '
      /^(---|\+\+\+) [ab]\// {
        path = $2
        sub(/^[ab]\//, "", path)
        if (path != "/dev/null") print path
      }
    ' "$patch" >> "$paths_file"
  done
done

[ "$patch_count" -gt 0 ] || die "baseline contains no patch files"
sort -u -o "$paths_file" "$paths_file"
[ -s "$paths_file" ] || die "could not derive touched paths from patch headers"
if grep -Eq '(^/|(^|/)\.\.(/|$)|[[:space:]])' "$paths_file"; then
  die "patch set contains a path that is unsafe for sparse checkout"
fi

git -C "$source_dir" init --quiet
git -C "$source_dir" remote add origin "$SP11_KERNEL_UPSTREAM_URL"
git -C "$source_dir" -c protocol.version=2 fetch --quiet --depth=1 \
  --filter=blob:none origin "refs/tags/$SP11_KERNEL_UPSTREAM_REF"

resolved_commit="$(git -C "$source_dir" rev-parse --verify 'FETCH_HEAD^{commit}')"
if [ "$resolved_commit" != "$SP11_KERNEL_UPSTREAM_COMMIT" ]; then
  die "upstream ref resolved to $resolved_commit, expected $SP11_KERNEL_UPSTREAM_COMMIT"
fi

git -C "$source_dir" sparse-checkout init --no-cone
git -C "$source_dir" sparse-checkout set --no-cone --stdin < "$paths_file"
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD

for patch_dir in $SP11_KERNEL_PATCH_DIRS; do
  for patch in "$repo_dir/$patch_dir"/*.patch; do
    [ -f "$patch" ] || continue
    git -C "$source_dir" apply --check "$patch"
    git -C "$source_dir" apply "$patch"
    printf 'Applied %s/%s\n' "$patch_dir" "${patch##*/}"
  done
done

printf 'Validated %d patches against %s at %s\n' \
  "$patch_count" "$SP11_KERNEL_UPSTREAM_REF" "$resolved_commit"
