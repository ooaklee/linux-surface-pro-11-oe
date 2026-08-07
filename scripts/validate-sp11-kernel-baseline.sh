#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="${1:-$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env}"
ledger="$repo_dir/config/source-ledger.tsv"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -f "$baseline" ] || die "kernel baseline not found: $baseline"

# shellcheck disable=SC1090
. "$baseline"

required_variables="
SP11_KERNEL_BASELINE_ID
SP11_KERNEL_UPSTREAM_URL
SP11_KERNEL_UPSTREAM_REF
SP11_KERNEL_UPSTREAM_COMMIT
SP11_KERNEL_FORK_URL
SP11_KERNEL_FORK_BASE_REF
SP11_KERNEL_FORK_BASE_COMMIT
SP11_KERNEL_FORK_INTEGRATION_REF
SP11_KERNEL_FORK_INTEGRATION_COMMIT
SP11_KERNEL_DOCKER_IMAGE
SP11_KERNEL_DOCKER_PLATFORM
SP11_KERNEL_DOCKER_PLATFORM_MANIFEST
SP11_KERNEL_BUILD_TARGET
SP11_KERNEL_PATCH_DIRS
SP11_KERNEL_RECOVERY_ABI
"
for variable in $required_variables; do
  [ -n "${!variable:-}" ] || die "baseline variable is empty or missing: $variable"
done

[[ "$SP11_KERNEL_DOCKER_IMAGE" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] ||
  die "SP11_KERNEL_DOCKER_IMAGE must include an immutable sha256 digest"
[ "$SP11_KERNEL_DOCKER_PLATFORM" = "linux/arm64/v8" ] ||
  die "SP11_KERNEL_DOCKER_PLATFORM must be linux/arm64/v8"
[[ "$SP11_KERNEL_DOCKER_PLATFORM_MANIFEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die "SP11_KERNEL_DOCKER_PLATFORM_MANIFEST must be a sha256 digest"

for variable in SP11_KERNEL_UPSTREAM_COMMIT SP11_KERNEL_FORK_BASE_COMMIT \
  SP11_KERNEL_FORK_INTEGRATION_COMMIT; do
  value="${!variable}"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] ||
    die "$variable must be a full lowercase 40-hex commit"
done

for variable in SP11_KERNEL_UPSTREAM_URL SP11_KERNEL_FORK_URL; do
  value="${!variable}"
  [[ "$value" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]] ||
    die "$variable must be a canonical HTTPS GitHub clone URL"
done

case "$SP11_KERNEL_RECOVERY_ABI" in
  *-qcom-x1e) ;;
  *) die "SP11_KERNEL_RECOVERY_ABI must end in -qcom-x1e" ;;
esac

for patch_dir in $SP11_KERNEL_PATCH_DIRS; do
  case "$patch_dir" in
    /*|*..*) die "unsafe patch directory in baseline: $patch_dir" ;;
  esac
  [ -d "$repo_dir/$patch_dir" ] || die "baseline patch directory not found: $patch_dir"
done

[ -f "$ledger" ] || die "source ledger not found: $ledger"
upstream_row="$(awk -F '\t' '$1 == "jg-kernel" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_upstream="${SP11_KERNEL_UPSTREAM_URL}"$'\t'"${SP11_KERNEL_UPSTREAM_REF}"$'\t'"${SP11_KERNEL_UPSTREAM_COMMIT}"
[ "$upstream_row" = "$expected_upstream" ] ||
  die "jg-kernel ledger row does not match the kernel baseline"

fork_base_row="$(awk -F '\t' '$1 == "sp11-kernel-fork-base" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_fork_base="${SP11_KERNEL_FORK_URL}"$'\t'"${SP11_KERNEL_FORK_BASE_REF}"$'\t'"${SP11_KERNEL_FORK_BASE_COMMIT}"
[ "$fork_base_row" = "$expected_fork_base" ] ||
  die "sp11-kernel-fork-base ledger row does not match the kernel baseline"

fork_integration_row="$(awk -F '\t' '$1 == "sp11-kernel-integration" {print $2 "\t" $3 "\t" $4}' "$ledger")"
expected_fork_integration="${SP11_KERNEL_FORK_URL}"$'\t'"${SP11_KERNEL_FORK_INTEGRATION_REF}"$'\t'"${SP11_KERNEL_FORK_INTEGRATION_COMMIT}"
[ "$fork_integration_row" = "$expected_fork_integration" ] ||
  die "sp11-kernel-integration ledger row does not match the kernel baseline"

printf 'Validated kernel baseline %s at %s\n' \
  "$SP11_KERNEL_BASELINE_ID" "$SP11_KERNEL_UPSTREAM_COMMIT"
