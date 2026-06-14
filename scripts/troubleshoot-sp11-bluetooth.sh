#!/usr/bin/env bash
set -euo pipefail

DMESG_LINES=160
SHOW_CONFIG="false"
CONFIG="${CONFIG:-/etc/default/sp11-bluetooth-mac}"

usage() {
  cat <<EOF
Usage: $0 [--show-config] [--dmesg-lines N]

Collects Surface Pro 11 Bluetooth diagnostics.

By default this script redacts the configured Bluetooth MAC address if present.
Other tool output can still include hardware addresses; redact before sharing.

Options:
  --show-config   Show the configured Bluetooth MAC address without redaction.
  --dmesg-lines N Number of filtered dmesg lines to print, default 160.
  -h, --help      Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --show-config)
      SHOW_CONFIG="true"
      shift
      ;;
    --dmesg-lines)
      if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
        echo "--dmesg-lines requires a positive integer." >&2
        exit 2
      fi
      DMESG_LINES="$2"
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

section() {
  printf '\n## %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run_or_note() {
  local tool="$1"
  shift
  if have "$tool"; then
    "$@" || true
  else
    echo "Missing tool: $tool"
  fi
}

normalize_mac() {
  printf '%s\n' "$1" | tr '-' ':' | tr '[:lower:]' '[:upper:]'
}

redact_mac() {
  local value
  value="$(normalize_mac "$1")"
  case "$value" in
    ??:??:??:??:??:??) printf '%s:xx:xx:xx\n' "${value%:*:*:*}" ;;
    *) printf 'configured-but-invalid-format\n' ;;
  esac
}

section "System"
echo "Kernel: $(uname -r)"
if [ -r /proc/device-tree/model ]; then
  printf 'Device tree model: '
  tr -d '\0' < /proc/device-tree/model
  printf '\n'
fi
if [ -r /proc/device-tree/compatible ]; then
  printf 'Compatible: '
  tr '\0' ' ' < /proc/device-tree/compatible
  printf '\n'
fi

section "rfkill"
run_or_note rfkill rfkill list

section "Bluetooth Config"
if [ -f "$CONFIG" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG"
  echo "Config: $CONFIG"
  echo "SP11_BLUETOOTH_HCI=${SP11_BLUETOOTH_HCI:-hci0}"
  if [ -n "${SP11_BLUETOOTH_MAC:-}" ]; then
    if [ "$SHOW_CONFIG" = "true" ]; then
      echo "SP11_BLUETOOTH_MAC=$SP11_BLUETOOTH_MAC"
    else
      echo "SP11_BLUETOOTH_MAC=$(redact_mac "$SP11_BLUETOOTH_MAC")"
    fi
  else
    echo "SP11_BLUETOOTH_MAC is not set"
  fi
else
  echo "No config found at $CONFIG"
fi

section "Bluetooth sysfs"
for hci in /sys/class/bluetooth/hci*; do
  [ -d "$hci" ] || continue
  printf '%s\n' "$hci"
  if [ -r "$hci/address" ]; then
    printf '  address=%s\n' "$(cat "$hci/address")"
  fi
  if [ -r "$hci/name" ]; then
    printf '  name=%s\n' "$(cat "$hci/name")"
  fi
  for rfkill in "$hci"/rfkill*; do
    [ -d "$rfkill" ] || continue
    printf '  rfkill=%s soft=%s hard=%s\n' \
      "$(basename "$rfkill")" \
      "$(cat "$rfkill/soft" 2>/dev/null || true)" \
      "$(cat "$rfkill/hard" 2>/dev/null || true)"
  done
done

section "btmgmt"
run_or_note btmgmt btmgmt info

section "hciconfig"
run_or_note hciconfig hciconfig -a

section "bluetoothctl"
if have bluetoothctl; then
  bluetoothctl list || true
  bluetoothctl show || true
else
  echo "Missing tool: bluetoothctl"
fi

section "systemd"
if have systemctl; then
  systemctl --no-pager --full status bluetooth.service || true
  systemctl --no-pager --full status 'sp11-bluetooth-mac@hci0.service' || true
else
  echo "Missing tool: systemctl"
fi

section "journal"
if have journalctl; then
  journalctl -b --no-pager -u bluetooth.service -u 'sp11-bluetooth-mac@*.service' | tail -n 120 || true
else
  echo "Missing tool: journalctl"
fi

section "dmesg"
if have dmesg; then
  dmesg -T 2>/dev/null |
    grep -iE 'bluetooth|btusb|btqca|hci0|wcn|qca|rfkill|firmware|address|mac' |
    tail -n "$DMESG_LINES" || true
else
  echo "Missing tool: dmesg"
fi
