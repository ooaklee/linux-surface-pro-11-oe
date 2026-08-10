#!/usr/bin/env bash
set -euo pipefail

EXPECTED=""
ACTUAL=""
MODE="touchscreen"
temporary_root=""

usage() {
  echo "Usage: $0 --expected FILE --actual FILE [--kernel-only]" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "${TMPDIR:-/tmp}"/sp11-payload-identities.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected identity-list temp path: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected) [ "$#" -ge 2 ] || { usage; exit 2; }; EXPECTED="$2"; shift 2 ;;
    --actual) [ "$#" -ge 2 ] || { usage; exit 2; }; ACTUAL="$2"; shift 2 ;;
    --kernel-only) MODE="kernel-only"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for tool in awk cmp mktemp sed sort uniq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
for input in "$EXPECTED" "$ACTUAL"; do
  [ -s "$input" ] && [ -f "$input" ] && [ ! -L "$input" ] ||
    die "identity list must be a non-empty regular, non-symlinked file: $input"
done

validate_list() {
  local file="$1" label="$2" sha name extra
  local deb_count=0 gpi_count=0 spi_count=0 touch_count=0 certificate_count=0 manifest_count=0
  while read -r sha name extra; do
    [ -z "${extra:-}" ] && [[ "$sha" =~ ^[0-9a-f]{64}$ ]] ||
      die "$label identity list contains an invalid record"
    case "$name" in
      *[!A-Za-z0-9._+-]*) die "$label identity list contains an unsafe filename: $name" ;;
    esac
    case "$name" in
      linux-*.deb) deb_count=$((deb_count + 1)) ;;
      gpi.ko) gpi_count=$((gpi_count + 1)) ;;
      spi-geni-qcom.ko) spi_count=$((spi_count + 1)) ;;
      mshw0485_touch.ko) touch_count=$((touch_count + 1)) ;;
      sp11-module-signing-cert.x509) certificate_count=$((certificate_count + 1)) ;;
      sp11-touchscreen-modules-manifest.txt) manifest_count=$((manifest_count + 1)) ;;
      *) die "$label identity list contains an unexpected payload file: $name" ;;
    esac
  done < "$file"
  if [ "$MODE" = "kernel-only" ]; then
    [ "$deb_count" -ge 1 ] && [ "$gpi_count" -eq 0 ] && [ "$spi_count" -eq 0 ] &&
      [ "$touch_count" -eq 0 ] && [ "$certificate_count" -eq 0 ] &&
      [ "$manifest_count" -eq 0 ] ||
      die "$label identity list does not contain an exact kernel-only payload"
  else
    [ "$deb_count" -ge 1 ] && [ "$gpi_count" -eq 1 ] && [ "$spi_count" -eq 1 ] &&
      [ "$touch_count" -eq 1 ] && [ "$certificate_count" -eq 1 ] &&
      [ "$manifest_count" -eq 1 ] ||
      die "$label identity list does not contain the exact signed module/certificate/manifest roles"
  fi
  duplicate="$(awk '{print $2}' "$file" | LC_ALL=C sort | uniq -d | sed -n '1p')"
  [ -z "$duplicate" ] || die "$label identity list repeats filename: $duplicate"
}

validate_list "$EXPECTED" expected
validate_list "$ACTUAL" actual
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-payload-identities.XXXXXX")"
LC_ALL=C sort "$EXPECTED" > "$temporary_root/expected"
LC_ALL=C sort "$ACTUAL" > "$temporary_root/actual"
if ! cmp -s "$temporary_root/expected" "$temporary_root/actual"; then
  die "actual image payload identities do not exactly match the bound manifest identities"
fi

echo "Image payload identity list matches exactly."
