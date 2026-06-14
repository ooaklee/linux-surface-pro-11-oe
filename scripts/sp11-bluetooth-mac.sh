#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CONFIG:-/etc/default/sp11-bluetooth-mac}"
HCI="hci0"
MAC=""
ACTION="apply"
HCI_SET="false"

usage() {
  cat <<EOF
Usage: sudo $0 [--apply] [--mac MAC] [--hci HCI]
       sudo $0 --write-config MAC [--hci HCI]
       sudo $0 --install-systemd

Configures a Surface Pro 11 Bluetooth public address with btmgmt.

The helper is intentionally config-driven. It does not invent an address.
Use the Bluetooth MAC address reported by Windows or another trusted source.

Options:
  --apply             Apply the configured or supplied MAC address (default).
  --mac MAC           MAC address to apply for this run.
  --hci HCI           Bluetooth controller, default hci0.
  --write-config MAC  Write /etc/default/sp11-bluetooth-mac.
  --install-systemd   Install the udev-triggered systemd service.
  --config FILE       Config path, default /etc/default/sp11-bluetooth-mac.
  -h, --help          Show this help.
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    echo "Install it with: sudo apt update && sudo apt install bluez" >&2
    exit 1
  fi
}

normalize_mac() {
  printf '%s\n' "$1" | tr '-' ':' | tr '[:lower:]' '[:upper:]'
}

validate_mac() {
  local value
  value="$(normalize_mac "$1")"
  if ! [[ "$value" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
    echo "Invalid Bluetooth MAC address: $1" >&2
    exit 2
  fi
  case "$value" in
    00:00:00:00:00:00|AA:AA:AA:AA:AA:AA|AA:BB:CC:DD:EE:FF|FF:FF:FF:FF:FF:FF)
      echo "Refusing placeholder Bluetooth MAC address: $value" >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$value"
}

write_config() {
  local value="$1"
  install -d -m 0755 "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<EOF
# Surface Pro 11 Bluetooth MAC address.
# Use the address reported by Windows or another trusted source.
SP11_BLUETOOTH_MAC="$value"
SP11_BLUETOOTH_HCI="$HCI"
EOF
  chmod 0644 "$CONFIG"
  echo "Wrote $CONFIG"
}

install_systemd() {
  local script_source

  script_source="${BASH_SOURCE[0]}"
  if command -v realpath >/dev/null 2>&1; then
    script_source="$(realpath "$script_source")"
  elif [[ "$script_source" != /* ]]; then
    script_source="$(pwd)/$script_source"
  fi
  if [ ! -f "$script_source" ]; then
    echo "Could not resolve this helper path for installation: ${BASH_SOURCE[0]}" >&2
    exit 1
  fi

  install -d -m 0755 /usr/local/sbin /etc/systemd/system /etc/udev/rules.d
  install -m 0755 "$script_source" /usr/local/sbin/sp11-bluetooth-mac

  cat > /etc/systemd/system/sp11-bluetooth-mac@.service <<'EOF'
[Unit]
Description=Set Surface Pro 11 Bluetooth public address on %I
ConditionPathExists=/etc/default/sp11-bluetooth-mac
After=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I
EOF

  cat > /etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="bluetooth", KERNEL=="hci[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}="sp11-bluetooth-mac@%k.service"
EOF

  systemctl daemon-reload
  udevadm control --reload || true
  echo "Installed sp11-bluetooth-mac systemd service and udev trigger."
  echo "Write $CONFIG before relying on the service."
}

load_config() {
  if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG"
    MAC="${MAC:-${SP11_BLUETOOTH_MAC:-}}"
    if [ "$HCI_SET" != "true" ]; then
      HCI="${SP11_BLUETOOTH_HCI:-hci0}"
    fi
  fi
}

apply_mac() {
  local value="$1" attempt

  require_tool btmgmt
  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock bluetooth || true
  fi

  for attempt in 1 2 3 4 5; do
    btmgmt -i "$HCI" power off >/dev/null 2>&1 || true
    sleep 1
    if btmgmt -i "$HCI" public-addr "$value"; then
      if ! btmgmt -i "$HCI" power on; then
        echo "Bluetooth address was configured, but $HCI did not power on." >&2
        exit 1
      fi
      echo "Configured Bluetooth public address for $HCI."
      return 0
    fi
    sleep 1
  done

  echo "Failed to configure Bluetooth public address for $HCI." >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      ACTION="apply"
      shift
      ;;
    --mac)
      if [ "$#" -lt 2 ]; then
        echo "--mac requires a value." >&2
        exit 2
      fi
      MAC="$2"
      shift 2
      ;;
    --hci)
      if [ "$#" -lt 2 ]; then
        echo "--hci requires a value." >&2
        exit 2
      fi
      HCI="$2"
      HCI_SET="true"
      shift 2
      ;;
    --write-config)
      if [ "$#" -lt 2 ]; then
        echo "--write-config requires a MAC address." >&2
        exit 2
      fi
      ACTION="write-config"
      MAC="$2"
      shift 2
      ;;
    --install-systemd)
      ACTION="install-systemd"
      shift
      ;;
    --config)
      if [ "$#" -lt 2 ]; then
        echo "--config requires a path." >&2
        exit 2
      fi
      CONFIG="$2"
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

require_root

case "$ACTION" in
  write-config)
    MAC="$(validate_mac "$MAC")"
    write_config "$MAC"
    ;;
  install-systemd)
    install_systemd
    ;;
  apply)
    load_config
    if [ -z "$MAC" ]; then
      echo "No Bluetooth MAC configured." >&2
      echo "Run: sudo $0 --write-config <your-bluetooth-mac>" >&2
      exit 2
    fi
    MAC="$(validate_mac "$MAC")"
    apply_mac "$MAC"
    ;;
esac
