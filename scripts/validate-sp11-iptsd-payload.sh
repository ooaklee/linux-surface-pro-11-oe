#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="${SP11_IPTSD_PAYLOAD:-$repo_dir/payload/iptsd-sp11}"
INTEGRATION="${SP11_IPTSD_INTEGRATION:-$repo_dir/userspace/iptsd-sp11}"

usage() {
  cat <<EOF
Usage: $0 [--payload DIR] [--integration DIR]

Validates an SP11 iptsd payload against its checked-in release manifest,
source pin, architecture, build provenance, fallback sources, and licenses.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload)
      PAYLOAD="$2"
      shift 2
      ;;
    --integration)
      INTEGRATION="$2"
      shift 2
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

fail() {
  echo "SP11 iptsd payload validation failed: $*" >&2
  exit 1
}

for tool in awk cmp find grep od sed sha256sum sort tr; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

[ -d "$PAYLOAD" ] || fail "payload directory not found: $PAYLOAD"
[ -d "$INTEGRATION" ] || fail "integration directory not found: $INTEGRATION"

for file in \
  "$PAYLOAD/SHA256SUMS" \
  "$PAYLOAD/SOURCE.env" \
  "$PAYLOAD/BUILD.env" \
  "$PAYLOAD/SBOM.dpkg.tsv" \
  "$PAYLOAD/APT.sources.txt" \
  "$PAYLOAD/bin/sp11-iptsd" \
  "$PAYLOAD/bin/sp11-iptsd-check-device" \
  "$INTEGRATION/SOURCE.env" \
  "$INTEGRATION/PAYLOAD.sha256"; do
  [ -f "$file" ] || fail "required file not found: $file"
done

cmp -s "$PAYLOAD/SOURCE.env" "$INTEGRATION/SOURCE.env" ||
  fail "payload source identity differs from the integration pin"
cmp -s "$PAYLOAD/SHA256SUMS" "$INTEGRATION/PAYLOAD.sha256" ||
  fail "payload checksum manifest differs from the pinned release manifest"

(
  cd "$PAYLOAD"
  sha256sum -c SHA256SUMS
)

manifest_files="$(mktemp)"
actual_files="$(mktemp)"
expected_files="$(mktemp)"
actual_names="$(mktemp)"
trap 'rm -f "$manifest_files" "$actual_files" "$expected_files" "$actual_names"' EXIT

awk '{print $2}' "$PAYLOAD/SHA256SUMS" |
  sed 's#^\./##' | LC_ALL=C sort > "$manifest_files"
(
  cd "$PAYLOAD"
  find . -type f ! -name SHA256SUMS -print |
    sed 's#^\./##' | LC_ALL=C sort
) > "$actual_files"
cmp -s "$manifest_files" "$actual_files" ||
  fail "checksum manifest does not cover the exact payload file set"

# SOURCE.env is trusted only after the byte-for-byte comparison above.
# shellcheck disable=SC1090
source "$INTEGRATION/SOURCE.env"
[[ "$IPTSD_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit pin"
[[ "$IPTSD_TREE" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source tree pin"

check_exact_names() {
  local directory="$1"
  shift
  : > "$expected_files"
  printf '%s\n' "$@" | LC_ALL=C sort > "$expected_files"
  : > "$actual_names"
  for file in "$directory"/*; do
    [ -f "$file" ] || continue
    basename "$file" >> "$actual_names"
  done
  LC_ALL=C sort -o "$actual_names" "$actual_names"
  cmp -s "$expected_files" "$actual_names" ||
    fail "unexpected file set under $directory"
}

check_exact_names "$PAYLOAD/sources" \
  "CLI11-2.6.1.tar.gz" \
  "GSL-4.2.0.zip" \
  "cli11.wrap" \
  "eigen-5.0.1.tar.bz2" \
  "eigen.wrap" \
  "eigen_5.0.1-1_patch.zip" \
  "fmt-12.0.0.tar.gz" \
  "fmt.wrap" \
  "fmt_12.0.0-1_patch.zip" \
  "inih-r62.tar.gz" \
  "inih.wrap" \
  "iptsd-$IPTSD_COMMIT.tar.gz" \
  "microsoft-gsl.wrap" \
  "microsoft-gsl_4.2.0-1_patch.zip" \
  "spdlog-1.15.3.tar.gz" \
  "spdlog.wrap" \
  "spdlog_1.15.3-5_patch.zip"

check_exact_names "$PAYLOAD/licenses" \
  "COPYING.Eigen.APACHE" \
  "COPYING.Eigen.BSD" \
  "COPYING.Eigen.MINPACK" \
  "COPYING.Eigen.MPL2" \
  "COPYING.Eigen.README" \
  "LICENSE.CLI11" \
  "LICENSE.Eigen" \
  "LICENSE.Eigen.build" \
  "LICENSE.Microsoft-GSL" \
  "LICENSE.Microsoft-GSL.build" \
  "LICENSE.fmt" \
  "LICENSE.fmt.build" \
  "LICENSE.inih" \
  "LICENSE.integration" \
  "LICENSE.iptsd" \
  "LICENSE.spdlog" \
  "LICENSE.spdlog.build"

check_aarch64_elf() {
  local binary="$1" magic machine
  [ -x "$binary" ] || fail "binary is not executable: $binary"
  magic="$(od -An -tx1 -N6 "$binary" | tr -d '[:space:]')"
  machine="$(od -An -tx1 -j18 -N2 "$binary" | tr -d '[:space:]')"
  [ "$magic" = "7f454c460201" ] || fail "not a 64-bit little-endian ELF: $binary"
  [ "$machine" = "b700" ] || fail "not an AArch64 ELF: $binary"
}

check_aarch64_elf "$PAYLOAD/bin/sp11-iptsd"
check_aarch64_elf "$PAYLOAD/bin/sp11-iptsd-check-device"

grep -qx 'BUILD_ARCH=aarch64' "$PAYLOAD/BUILD.env" ||
  fail "BUILD.env does not identify an AArch64 build"
grep -Eq '^BUILD_IMAGE_ID=sha256:[0-9a-f]{64}$' "$PAYLOAD/BUILD.env" ||
  fail "BUILD.env does not pin the container image ID"
grep -Eq '^BUILD_IMAGE_DIGEST=.*@sha256:[0-9a-f]{64}' "$PAYLOAD/BUILD.env" ||
  fail "BUILD.env does not record the container repository digest"
grep -Eq '^MESON_OPTIONS=.*-Dforce_access_checks=true' "$PAYLOAD/BUILD.env" ||
  fail "payload was not built with forced access checks"

for package in binutils build-essential g++ libc6-dev meson ninja-build; do
  awk -F '\t' -v expected="$package" '
    {
      name = $1
      sub(/:.*/, "", name)
      if (name == expected) {
        found = 1
        exit
      }
    }
    END { exit !found }
  ' "$PAYLOAD/SBOM.dpkg.tsv" || fail "SBOM omits build package: $package"
done

echo "SP11 iptsd payload matches the pinned release."
