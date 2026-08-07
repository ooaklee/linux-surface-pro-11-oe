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
SP11_APT_SNAPSHOT_ID
SP11_APT_SNAPSHOT_URI
SP11_APT_SNAPSHOT_SUITES
SP11_APT_SNAPSHOT_COMPONENTS
SP11_APT_SNAPSHOT_ARCHITECTURE
SP11_APT_ARCHIVE_KEYRING_SHA256
SP11_APT_ARCHIVE_SIGNING_FINGERPRINT
SP11_APT_INRELEASE_RESOLUTE_SHA256
SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256
SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256
SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256
SP11_APT_AUTHENTICATED_INDEX_COUNT
SP11_APT_BOOTSTRAP_PACKAGE_COUNT
SP11_APT_BOOTSTRAP_PACKAGE_1_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_1_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_2_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_2_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_3_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_3_SHA256
SP11_APT_BOOTSTRAP_PACKAGE_4_SPEC
SP11_APT_BOOTSTRAP_PACKAGE_4_SHA256
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

[[ "$SP11_APT_SNAPSHOT_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
  die "SP11_APT_SNAPSHOT_ID must be a UTC snapshot timestamp"
[ "$SP11_APT_SNAPSHOT_ID" = "20260807T000000Z" ] ||
  die "SP11_APT_SNAPSHOT_ID must match the reviewed 2026-08-07 snapshot"
[ "$SP11_APT_SNAPSHOT_URI" = "https://snapshot.ubuntu.com/ubuntu/$SP11_APT_SNAPSHOT_ID/" ] ||
  die "SP11_APT_SNAPSHOT_URI must be the direct dated Ubuntu snapshot URI"
[ "$SP11_APT_SNAPSHOT_SUITES" = "resolute resolute-updates resolute-backports resolute-security" ] ||
  die "SP11_APT_SNAPSHOT_SUITES must contain the reviewed Resolute pockets"
[ "$SP11_APT_SNAPSHOT_COMPONENTS" = "main universe restricted multiverse" ] ||
  die "SP11_APT_SNAPSHOT_COMPONENTS must contain the reviewed Ubuntu components"
[ "$SP11_APT_SNAPSHOT_ARCHITECTURE" = "arm64" ] ||
  die "SP11_APT_SNAPSHOT_ARCHITECTURE must be arm64"
[[ "$SP11_APT_ARCHIVE_KEYRING_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  die "SP11_APT_ARCHIVE_KEYRING_SHA256 must be a lowercase SHA-256"
[[ "$SP11_APT_ARCHIVE_SIGNING_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] ||
  die "SP11_APT_ARCHIVE_SIGNING_FINGERPRINT must be a 40-hex fingerprint"
[ "$SP11_APT_ARCHIVE_KEYRING_SHA256" = "80a36b0a6de2f69f49d2df75ef473ccde121e9e190b9ea01d20a4f63778d5c31" ] ||
  die "SP11_APT_ARCHIVE_KEYRING_SHA256 does not match the reviewed keyring"
[ "$SP11_APT_ARCHIVE_SIGNING_FINGERPRINT" = "F6ECB3762474EDA9D21B7022871920D1991BC93C" ] ||
  die "SP11_APT_ARCHIVE_SIGNING_FINGERPRINT does not match the reviewed archive key"

for variable in \
  SP11_APT_INRELEASE_RESOLUTE_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256; do
  value="${!variable}"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
    die "$variable must be a lowercase SHA-256"
done

[ "$SP11_APT_INRELEASE_RESOLUTE_SHA256" = "45f95ce276cdba3e41870516a130e03c58b8b7a79e9546b0efe9e526d255740c" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256" = "9553631dec5b79a35dcdc5173e56f384ca93abcb37726a161c1090c4acc481f0" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256" = "b5105f9b273e83dbaabe95cbbceb724264b375709b434af654023896dcc7f8ec" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256 does not match the reviewed snapshot"
[ "$SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256" = "439791ef018139c01e9c2b434f06a3362f9cc6787badeef5d7d9e7716217a1b9" ] ||
  die "SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256 does not match the reviewed snapshot"

[ "$SP11_APT_AUTHENTICATED_INDEX_COUNT" = "32" ] ||
  die "SP11_APT_AUTHENTICATED_INDEX_COUNT must cover the reviewed 4x4x2 index set"

[ "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" = "4" ] ||
  die "SP11_APT_BOOTSTRAP_PACKAGE_COUNT must be 4"
bootstrap_index=1
while [ "$bootstrap_index" -le "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ]; do
  spec_variable="SP11_APT_BOOTSTRAP_PACKAGE_${bootstrap_index}_SPEC"
  sha_variable="SP11_APT_BOOTSTRAP_PACKAGE_${bootstrap_index}_SHA256"
  spec="${!spec_variable:-}"
  sha="${!sha_variable:-}"
  [[ "$spec" =~ ^[a-z0-9][a-z0-9.+-]*=[0-9A-Za-z.+:~_-]+$ ]] ||
    die "$spec_variable must pin one exact package version"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "$sha_variable must be a lowercase SHA-256"
  bootstrap_index=$((bootstrap_index + 1))
done

[ "$SP11_APT_BOOTSTRAP_PACKAGE_1_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_1_SHA256" = \
  "ca-certificates=20260601~26.04.1:6077d27c6b6f8b23590cb01ff877ed8c804a67a5442cc32b5a33da10d2bd0e90" ] ||
  die "bootstrap package 1 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_2_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_2_SHA256" = \
  "openssl=3.5.5-1ubuntu3.3:d676e507c49f884f0c4582a32c4827d4cf94e0c4b2b1282c0e9c95693928856c" ] ||
  die "bootstrap package 2 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_3_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_3_SHA256" = \
  "libssl3t64=3.5.5-1ubuntu3.3:6f02fb682e7a873ac831da6066c856c982a51c08f2917cd90591b25663bd1feb" ] ||
  die "bootstrap package 3 does not match the reviewed snapshot"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_4_SPEC:$SP11_APT_BOOTSTRAP_PACKAGE_4_SHA256" = \
  "openssl-provider-legacy=3.5.5-1ubuntu3.3:365b59eb0d11c4b037709776a02618ecdab9a07f03804b48e425cec5b2f4325b" ] ||
  die "bootstrap package 4 does not match the reviewed snapshot"

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
