#!/usr/bin/env bash
set -euo pipefail

DMESG_LINES=160
SHOW_CONFIG="false"
SHOW_ADDRESSES="false"
CONFIG="${CONFIG:-/etc/default/sp11-bluetooth-mac}"
CONFIG_HCI="hci0"

usage() {
  cat <<EOF
Usage: $0 [--show-config] [--show-addresses] [--dmesg-lines N]

Collects Surface Pro 11 Bluetooth diagnostics.

By default this script redacts the configured Bluetooth MAC address if present.
It also redacts MAC-like addresses from command output unless --show-addresses
is used.

Options:
  --show-config   Show the configured Bluetooth MAC address without redaction.
  --show-addresses
                  Show hardware addresses in command output.
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
    --show-addresses)
      SHOW_ADDRESSES="true"
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
    "$@" 2>&1 | maybe_redact_addresses || true
  else
    echo "Missing tool: $tool"
  fi
}

run_or_note_bounded() {
  local seconds="$1" tool="$2"
  shift 2
  if ! have "$tool"; then
    echo "Missing tool: $tool"
    return 0
  fi
  if have timeout; then
    timeout --kill-after=2s "${seconds}s" "$@" 2>&1 |
      maybe_redact_addresses ||
      echo "$tool command failed or timed out after ${seconds}s."
  else
    echo "Missing tool: timeout; running $tool without a timeout."
    "$@" 2>&1 | maybe_redact_addresses || true
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
    *) printf 'not-available\n' ;;
  esac
}

maybe_redact_addresses() {
  if [ "$SHOW_ADDRESSES" = "true" ]; then
    cat
  else
    sed -E \
      -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<mac-redacted>/g' \
      -e 's/([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}/<mac-redacted>/g'
  fi
}

is_suspicious_bt_address() {
  local value
  value="$(normalize_mac "$1")"
  case "$value" in
    00:00:00:00:*|00:00:00:00:00:00|AA:AA:AA:AA:AA:AA|AA:BB:CC:DD:EE:FF|FF:FF:FF:FF:FF:FF)
      return 0
      ;;
  esac
  return 1
}

format_address_for_output() {
  if [ "$SHOW_ADDRESSES" = "true" ]; then
    normalize_mac "$1"
  else
    redact_mac "$1"
  fi
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
  CONFIG_HCI="${SP11_BLUETOOTH_HCI:-hci0}"
  echo "Config: $CONFIG"
  echo "SP11_BLUETOOTH_HCI=$CONFIG_HCI"
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
    printf '  address=%s\n' "$(format_address_for_output "$(cat "$hci/address")")"
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

section "Bluetooth Address Check"
found_hci=0
for hci in /sys/class/bluetooth/hci*; do
  [ -d "$hci" ] || continue
  found_hci=1
  hci_name="$(basename "$hci")"
  addr=""
  if [ -r "$hci/address" ]; then
    addr="$(cat "$hci/address")"
  elif have hciconfig; then
    addr="$(hciconfig "$hci_name" 2>/dev/null | awk '/BD Address:/ { print $3; exit }')"
  fi

  if [ -z "$addr" ]; then
    echo "$hci_name: no controller address found"
    continue
  fi

  echo "$hci_name: address=$(format_address_for_output "$addr")"
  if is_suspicious_bt_address "$addr"; then
    echo "$hci_name: suspicious controller address; use the Windows Bluetooth MAC with sp11-bluetooth-mac."
  else
    echo "$hci_name: controller address does not match the known invalid placeholder patterns."
  fi
done
if [ "$found_hci" = "0" ]; then
  echo "No /sys/class/bluetooth/hci* controller found."
fi

section "btmgmt"
run_or_note_bounded 8 btmgmt btmgmt info

section "hciconfig"
run_or_note hciconfig hciconfig -a

section "bluetoothctl"
if have bluetoothctl; then
  bluetoothctl list 2>&1 | maybe_redact_addresses || true
  bluetoothctl show 2>&1 | maybe_redact_addresses || true
else
  echo "Missing tool: bluetoothctl"
fi

section "systemd"
if have systemctl; then
  systemctl --no-pager --full status bluetooth.service 2>&1 | maybe_redact_addresses || true
  systemctl --no-pager --full status "sp11-bluetooth-mac@$CONFIG_HCI.service" 2>&1 | maybe_redact_addresses || true
else
  echo "Missing tool: systemctl"
fi

section "journal"
if have journalctl; then
  journalctl -b --no-pager -u bluetooth.service -u 'sp11-bluetooth-mac@*.service' |
    tail -n 120 |
    maybe_redact_addresses || true
else
  echo "Missing tool: journalctl"
fi

section "dmesg"
if have dmesg; then
  dmesg -T 2>/dev/null |
    grep -iE 'bluetooth|btusb|btqca|hci[0-9]+|wcn|qca|rfkill|firmware|address|mac' |
    tail -n "$DMESG_LINES" |
    maybe_redact_addresses || true
else
  echo "Missing tool: dmesg"
fi
