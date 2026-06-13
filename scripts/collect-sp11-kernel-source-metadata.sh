#!/usr/bin/env bash
set -euo pipefail

OUT=""

usage() {
  cat <<EOF
Usage: $0 [--out FILE]

Collects the running qcom-x1e kernel source metadata needed for an off-device
Docker kernel build. Run this on the installed Surface Pro 11.

Options:
  --out FILE  Write shell metadata to FILE instead of stdout.
  -h, --help  Show this help.
EOF
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      require_arg "$1" "${2:-}"
      OUT="$2"
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

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

kernel_package_field() {
  local field release pkg value
  field="$1"
  release="$2"

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

require_tool dpkg-query

kernel_release="$(uname -r)"
case "$kernel_release" in
  *-qcom-x1e*)
    ;;
  *)
    echo "Running kernel is not a qcom-x1e kernel: $kernel_release" >&2
    echo "Boot the installed Surface Pro 11 qcom-x1e kernel before collecting source metadata." >&2
    exit 1
    ;;
esac

source_package="$(kernel_package_field 'source:Package' "$kernel_release")"
source_version="$(kernel_package_field 'source:Version' "$kernel_release")"

if [ -z "$source_package" ] || [ -z "$source_version" ]; then
  echo "Could not derive source metadata from running kernel package metadata." >&2
  echo "Kernel release: $kernel_release" >&2
  exit 1
fi

metadata="$(
  cat <<EOF
# Surface Pro 11 qcom-x1e kernel source metadata.
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ).
SP11_KERNEL_RELEASE=$(shell_quote "$kernel_release")
SP11_SOURCE_PACKAGE=$(shell_quote "$source_package")
SP11_SOURCE_VERSION=$(shell_quote "$source_version")
SP11_BUILD_TARGET='binary-qcom-x1e'
EOF
)"

if [ -n "$OUT" ]; then
  install -d "$(dirname "$OUT")"
  printf '%s\n' "$metadata" > "$OUT"
  echo "Wrote kernel source metadata: $OUT"
else
  printf '%s\n' "$metadata"
fi
