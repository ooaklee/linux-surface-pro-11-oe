#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/}"
PAYLOAD=""

usage() {
  cat <<EOF
Usage: sudo $0 [--root DIR] [--payload DIR]

Installs a verified payload produced by build-sp11-iptsd-docker.sh.

  --root DIR       Target root, default /.
  --payload DIR    Payload directory containing SHA256SUMS and bin/.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="$2"
      shift 2
      ;;
    --payload)
      PAYLOAD="$2"
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

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
integration_dir="$repo_dir/userspace/iptsd-sp11"

if [ -z "$PAYLOAD" ]; then
  for candidate in \
    "$repo_dir/payload/iptsd-sp11" \
    "$repo_dir/../payload/iptsd-sp11"; do
    if [ -f "$candidate/SHA256SUMS" ]; then
      PAYLOAD="$candidate"
      break
    fi
  done
fi

if [ ! -f "$PAYLOAD/SHA256SUMS" ]; then
  echo "Missing verified SP11 iptsd payload: ${PAYLOAD:-not found}" >&2
  echo "Build it with scripts/build-sp11-iptsd-docker.sh --copy-to-payload." >&2
  exit 1
fi
if [ ! -d "$integration_dir/packaging" ]; then
  echo "Missing SP11 iptsd integration assets: $integration_dir" >&2
  exit 1
fi
if [ ! -x "$repo_dir/scripts/validate-sp11-iptsd-payload.sh" ]; then
  echo "Missing SP11 iptsd payload validator." >&2
  exit 1
fi

"$repo_dir/scripts/validate-sp11-iptsd-payload.sh" \
  --payload "$PAYLOAD" --integration "$integration_dir"

target() {
  local rel="${1#/}"
  printf '%s/%s' "${ROOT%/}" "$rel"
}

generic_iptsd_mask="$(target /etc/systemd/system/iptsd@.service)"
if [ -e "$generic_iptsd_mask" ] || [ -L "$generic_iptsd_mask" ]; then
  if [ ! -L "$generic_iptsd_mask" ] ||
     [ "$(readlink "$generic_iptsd_mask")" != "/dev/null" ]; then
    echo "Refusing to replace custom unit: $generic_iptsd_mask" >&2
    echo "Remove or relocate it before installing the SP11-specific service." >&2
    exit 1
  fi
fi

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

sed \
  -e 's|@IPTSD@|/usr/local/libexec/sp11-iptsd|g' \
  -e 's|@CHECKER@|/usr/local/libexec/sp11-iptsd-check-device|g' \
  -e 's|@SYSTEMCTL@|/usr/bin/systemctl|g' \
  -e 's|@SYSTEMD_ESCAPE@|/usr/bin/systemd-escape|g' \
  "$integration_dir/packaging/sp11-iptsd@.service.in" \
  > "$render_dir/sp11-iptsd@.service"
sed \
  -e 's|@CHECKER@|/usr/local/libexec/sp11-iptsd-check-device|g' \
  -e 's|@SYSTEMD_ESCAPE@|/usr/bin/systemd-escape|g' \
  "$integration_dir/packaging/70-sp11-iptsd.rules.in" \
  > "$render_dir/70-sp11-iptsd.rules"
sed \
  -e 's|@IPTSD@|/usr/local/libexec/sp11-iptsd|g' \
  -e 's|@CHECKER@|/usr/local/libexec/sp11-iptsd-check-device|g' \
  -e 's|@SYSTEMCTL@|/usr/bin/systemctl|g' \
  -e 's|@SYSTEMD_ESCAPE@|/usr/bin/systemd-escape|g' \
  "$integration_dir/packaging/sp11-iptsd-restart.in" \
  > "$render_dir/sp11-iptsd-restart"

install -d \
  "$(target /usr/local/libexec)" \
  "$(target /usr/local/share/iptsd)" \
  "$(target /usr/local/share/doc/sp11-iptsd)" \
  "$(target /etc/systemd/system)" \
  "$(target /etc/udev/rules.d)" \
  "$(target /usr/lib/systemd/system-sleep)"

install -m 0755 "$PAYLOAD/bin/sp11-iptsd" \
  "$(target /usr/local/libexec/sp11-iptsd)"
install -m 0755 "$PAYLOAD/bin/sp11-iptsd-check-device" \
  "$(target /usr/local/libexec/sp11-iptsd-check-device)"
install -m 0644 "$integration_dir/config/surface-pro-11-0c80.conf" \
  "$(target /usr/local/share/iptsd/surface-pro-11-0c80.conf)"
install -m 0644 "$integration_dir/config/surface-pro-11-0c83.conf" \
  "$(target /usr/local/share/iptsd/surface-pro-11-0c83.conf)"
install -m 0644 "$render_dir/sp11-iptsd@.service" \
  "$(target /etc/systemd/system/sp11-iptsd@.service)"
install -m 0644 "$render_dir/70-sp11-iptsd.rules" \
  "$(target /etc/udev/rules.d/70-sp11-iptsd.rules)"
install -m 0755 "$render_dir/sp11-iptsd-restart" \
  "$(target /usr/lib/systemd/system-sleep/sp11-iptsd-restart)"
install -m 0644 "$integration_dir/README.md" \
  "$(target /usr/local/share/doc/sp11-iptsd/README.md)"
install -m 0644 "$PAYLOAD/SOURCE.env" "$PAYLOAD/BUILD.env" \
  "$PAYLOAD/SHA256SUMS" "$(target /usr/local/share/doc/sp11-iptsd/)"
install -m 0644 "$PAYLOAD/licenses/"* \
  "$(target /usr/local/share/doc/sp11-iptsd/)"

# The raw HEAT diagnostic daemon and iptsd are mutually exclusive consumers.
if [ "$ROOT" = "/" ]; then
  systemctl disable --now g6-pen.service 2>/dev/null || true
  systemctl stop 'iptsd@*.service' 2>/dev/null || true
  systemctl mask iptsd@.service
  systemctl daemon-reload
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=hidraw --action=change
  udevadm settle --timeout=5 || true
else
  rm -f "$(target /etc/systemd/system/multi-user.target.wants/g6-pen.service)"
  if [ ! -L "$generic_iptsd_mask" ]; then
    ln -s /dev/null "$generic_iptsd_mask"
  fi
fi

echo "Installed the SP11 iptsd pen integration into $ROOT"
