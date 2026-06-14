#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CONFIG:-/etc/default/sp11-bluetooth-mac}"
HCI="hci0"
MAC=""
ACTION="apply"
HCI_SET="false"
ATTEMPTS="${SP11_BLUETOOTH_ATTEMPTS:-5}"
SETTLE_SECONDS="${SP11_BLUETOOTH_SETTLE_SECONDS:-5}"
BTMGMT_TIMEOUT="${SP11_BLUETOOTH_BTMGMT_TIMEOUT:-8}"
ATTEMPTS_SET="false"
SETTLE_SECONDS_SET="false"
BTMGMT_TIMEOUT_SET="false"
RESTART_BLUETOOTH_BEFORE="${SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE:-false}"
RESTART_BLUETOOTH_BEFORE_SET="false"
SHOW_ADDRESSES="false"
NO_BATCH="${SP11_BLUETOOTH_NO_BATCH:-false}"

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
  --status            Show configured and current controller state.
  --show-addresses    Show exact hardware addresses in --status output.
  --attempts N        Number of btmgmt attempts, default $ATTEMPTS.
  --settle-seconds N  Seconds to wait for HCI readiness before applying,
                      default $SETTLE_SECONDS.
  --btmgmt-timeout N  Seconds before a btmgmt command is stopped,
                      default $BTMGMT_TIMEOUT.
  --restart-bluetooth-before
                      Restart bluetooth.service before applying the address.
                      Used by the cold-boot systemd unit.
  --no-batch           Skip the interactive btmgmt batch fallback. Only issue
                      the indexed btmgmt -i public-addr command. Used by the
                      cold-boot systemd unit to avoid stdin hang.
  --write-config MAC  Write /etc/default/sp11-bluetooth-mac.
  --install-systemd   Install the udev-triggered systemd service.
  --uninstall-systemd Remove the systemd service and udev trigger.
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
    case "$1" in
      btmgmt) echo "Install it with: sudo apt update && sudo apt install bluez" >&2 ;;
      timeout) echo "Install it with: sudo apt update && sudo apt install coreutils" >&2 ;;
    esac
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
    00:00:00:00:*|AA:AA:AA:AA:AA:AA|AA:BB:CC:DD:EE:FF|FF:FF:FF:FF:FF:FF)
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
SP11_BLUETOOTH_ATTEMPTS="$ATTEMPTS"
SP11_BLUETOOTH_SETTLE_SECONDS="$SETTLE_SECONDS"
SP11_BLUETOOTH_BTMGMT_TIMEOUT="$BTMGMT_TIMEOUT"
SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE="$RESTART_BLUETOOTH_BEFORE"
SP11_BLUETOOTH_NO_BATCH="$NO_BATCH"
EOF
  chmod 0600 "$CONFIG"
  echo "Wrote $CONFIG"
}

remove_bluetooth_wants_links() {
  local wants_dir

  for wants_dir in \
    /etc/systemd/system/bluetooth.service.wants \
    /run/systemd/system/bluetooth.service.wants \
    /lib/systemd/system/bluetooth.service.wants \
    /usr/lib/systemd/system/bluetooth.service.wants; do
    [ -d "$wants_dir" ] || continue
    find "$wants_dir" -maxdepth 1 -name 'sp11-bluetooth-mac@*.service' -exec rm -f {} +
  done
}

stop_existing_systemd_instances() {
  local unit

  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      systemctl stop "$unit" >/dev/null 2>&1 || true
    done < <(
      systemctl list-units --all --no-legend --plain 'sp11-bluetooth-mac@*.service' 2>/dev/null |
        awk '{ print $1 }' || true
    )
  fi
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
  if [ "$script_source" != "/usr/local/sbin/sp11-bluetooth-mac" ]; then
    install -m 0755 "$script_source" /usr/local/sbin/sp11-bluetooth-mac
  fi
  remove_bluetooth_wants_links

  cat > /etc/systemd/system/sp11-bluetooth-mac@.service <<'EOF'
[Unit]
Description=Set Surface Pro 11 Bluetooth public address on %I
ConditionPathExists=/etc/default/sp11-bluetooth-mac
Wants=bluetooth.service
After=bluetooth.service
StartLimitIntervalSec=5min
StartLimitBurst=3

[Service]
Type=oneshot
TimeoutStartSec=30min
# On cold boot, btmgmt blocks in D-state during firmware download
# (timeout cannot kill D-state processes). Instead, poll the sysfs
# address file (non-blocking read); once the kernel enumerates hci0,
# stop bluetoothd, apply the address, and ExecStartPost restarts
# bluetoothd. Use --settle-seconds 1 to give the controller a
# heartbeat after enumeration. Use --no-batch to skip the interactive
# btmgmt fallback (which would also hang in D-state during boot).
ExecStart=/usr/local/sbin/sp11-bluetooth-mac --apply --hci %I --no-batch --attempts 3 --settle-seconds 1 --btmgmt-timeout 15
ExecStartPost=-/usr/bin/systemctl restart bluetooth.service
EOF

  cat > /etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="bluetooth", ENV{DEVTYPE}=="host", KERNEL=="hci[0-9]*", TAG+="systemd", ENV{SYSTEMD_WANTS}="sp11-bluetooth-mac@%k.service"
EOF

  systemctl daemon-reload
  udevadm control --reload || true
  echo "Installed sp11-bluetooth-mac systemd service and udev trigger."
  echo "The helper now runs from udev after bluetooth.service is available."
  echo "Write $CONFIG before relying on the service."
}

uninstall_systemd() {
  load_config
  stop_existing_systemd_instances
  systemctl stop "sp11-bluetooth-mac@$HCI.service" >/dev/null 2>&1 || true
  systemctl disable "sp11-bluetooth-mac@$HCI.service" >/dev/null 2>&1 || true
  remove_bluetooth_wants_links
  rm -f \
    /etc/systemd/system/sp11-bluetooth-mac@.service \
    /etc/udev/rules.d/99-surface-pro-11-bluetooth-mac.rules
  systemctl daemon-reload
  udevadm control --reload || true
  echo "Removed sp11-bluetooth-mac systemd service and udev trigger."
}

load_config() {
  if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG"
    MAC="${MAC:-${SP11_BLUETOOTH_MAC:-}}"
    if [ "$ATTEMPTS_SET" != "true" ]; then
      ATTEMPTS="${SP11_BLUETOOTH_ATTEMPTS:-$ATTEMPTS}"
    fi
    if [ "$SETTLE_SECONDS_SET" != "true" ]; then
      SETTLE_SECONDS="${SP11_BLUETOOTH_SETTLE_SECONDS:-$SETTLE_SECONDS}"
    fi
    if [ "$BTMGMT_TIMEOUT_SET" != "true" ]; then
      BTMGMT_TIMEOUT="${SP11_BLUETOOTH_BTMGMT_TIMEOUT:-$BTMGMT_TIMEOUT}"
    fi
    if [ "$HCI_SET" != "true" ]; then
      HCI="${SP11_BLUETOOTH_HCI:-hci0}"
    fi
    if [ "$RESTART_BLUETOOTH_BEFORE_SET" != "true" ]; then
      RESTART_BLUETOOTH_BEFORE="${SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE:-$RESTART_BLUETOOTH_BEFORE}"
    fi
    if [ "$NO_BATCH" != "true" ]; then
      NO_BATCH="${SP11_BLUETOOTH_NO_BATCH:-false}"
    fi
  fi
}

validate_positive_integer() {
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    echo "$name must be a positive integer." >&2
    exit 2
  fi
}

validate_boolean() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *)
      echo "$name must be true or false." >&2
      exit 2
      ;;
  esac
}

BTMGMT_OUTPUT=""
run_btmgmt() {
  local show_output="$1" status
  shift

  validate_positive_integer "--btmgmt-timeout" "$BTMGMT_TIMEOUT"
  require_tool timeout

  set +e
  BTMGMT_OUTPUT="$(timeout --kill-after=2s "${BTMGMT_TIMEOUT}s" btmgmt -i "$HCI" "$@" 2>&1)"
  status=$?
  set -e

  if [ "$show_output" = "true" ] && [ -n "$BTMGMT_OUTPUT" ]; then
    printf '%s\n' "$BTMGMT_OUTPUT" | maybe_redact_addresses >&2
  fi

  case "$status" in
    124|137)
      echo "btmgmt command timed out after ${BTMGMT_TIMEOUT}s." >&2
      ;;
  esac

  return "$status"
}

run_btmgmt_batch() {
  local show_output="$1" commands="$2" status

  validate_positive_integer "--btmgmt-timeout" "$BTMGMT_TIMEOUT"
  require_tool timeout

  set +e
  # The SP11 community workaround uses interactive btmgmt without -i. Keep the
  # batch shape intact and reserve indexed btmgmt for the fallback path.
  BTMGMT_OUTPUT="$(printf '%s\n' "$commands" | timeout --kill-after=2s "${BTMGMT_TIMEOUT}s" btmgmt 2>&1)"
  status=$?
  set -e

  if [ "$show_output" = "true" ] && [ -n "$BTMGMT_OUTPUT" ]; then
    printf '%s\n' "$BTMGMT_OUTPUT" | maybe_redact_addresses >&2
  fi

  case "$status" in
    124|137)
      echo "btmgmt command timed out after ${BTMGMT_TIMEOUT}s." >&2
      ;;
  esac

  return "$status"
}

set_public_address() {
  local value="$1" first_sequence second_sequence

  # The indexed single command is the path that actually configures the
  # unconfigured wcn7850 controller on the Surface Pro 11's BlueZ 5.85:
  #   btmgmt -i hci0 public-addr <mac>  ->  "Set Public Address complete"
  # and after a bluetooth.service restart the controller comes up UP RUNNING.
  # Piping a command script into interactive btmgmt is a silent no-op on this
  # BlueZ build (it reads nothing and exits 0), so try the indexed call first
  # and keep the community batch sequence only as a fallback for other BlueZ
  # versions where interactive scripting executes.
  #
  # When --no-batch is set (cold-boot systemd unit), skip the interactive batch
  # fallback entirely: piping commands into btmgmt without -i hangs in systemd
  # because it opens an interactive [mgmt]> prompt waiting for stdin.
  if run_btmgmt true public-addr "$value"; then
    printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete' && return 0
  elif printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete'; then
    return 0
  fi

  if [ "$NO_BATCH" = "true" ]; then
    return 1
  fi

  # validate_mac restricts value to uppercase hex pairs and colons before this
  # function is called, so it is safe to place directly in btmgmt command input.
  first_sequence="$(cat <<EOF
info
power off
public-addr $value
info
exit
EOF
)"
  second_sequence="$(cat <<EOF
public-addr $value
exit
EOF
)"

  if run_btmgmt_batch true "$first_sequence"; then
    printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete' && return 0
  elif printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete'; then
    return 0
  fi

  if run_btmgmt_batch true "$second_sequence"; then
    printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete' && return 0
  elif printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete'; then
    return 0
  fi

  printf '%s\n' "$BTMGMT_OUTPUT" | grep -qi 'Set Public Address complete'
}

redact_mac() {
  local value
  value="$(normalize_mac "$1")"
  case "$value" in
    ??:??:??:??:??:??) printf '%s:xx:xx:xx\n' "${value%:*:*:*}" ;;
    *) printf 'not-available\n' ;;
  esac
}

format_mac_for_output() {
  if [ "$SHOW_ADDRESSES" = "true" ]; then
    normalize_mac "$1"
  else
    redact_mac "$1"
  fi
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

current_hci_address() {
  if [ -r "/sys/class/bluetooth/$HCI/address" ]; then
    normalize_mac "$(cat "/sys/class/bluetooth/$HCI/address")"
  elif command -v hciconfig >/dev/null 2>&1; then
    normalize_mac "$(hciconfig "$HCI" 2>/dev/null | awk '/BD Address:/ { print $3; exit }')"
  fi
}

wait_for_hci_ready() {
  local poll_attempt max_polls
  max_polls=24
  for poll_attempt in $(seq 1 $max_polls); do
    if [ -d "/sys/class/bluetooth/${HCI}" ]; then
      echo "${HCI} enumerated at poll attempt ${poll_attempt}."
      sleep 1
      return 0
    fi
    sleep 5
  done
  echo "${HCI} did not enumerate after ${max_polls} polls (${max_polls}×5s)." >&2
  return 1
}

restart_bluetooth_before_apply() {
  if [ "$RESTART_BLUETOOTH_BEFORE" != "true" ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "Restarting bluetooth.service before applying the Bluetooth public address."
    systemctl restart bluetooth.service || true
    sleep 3
  fi
}

apply_mac() {
  local value="$1" attempt
  local stopped_bluetoothd=false

  require_tool btmgmt
  require_tool timeout
  validate_positive_integer "--attempts" "$ATTEMPTS"
  validate_positive_integer "--settle-seconds" "$SETTLE_SECONDS"
  validate_positive_integer "--btmgmt-timeout" "$BTMGMT_TIMEOUT"
  validate_boolean "SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE" "$RESTART_BLUETOOTH_BEFORE"

  if [ ! -d "/sys/class/bluetooth/$HCI" ]; then
    echo "Bluetooth controller not found: $HCI" >&2
    echo "Run troubleshoot-sp11-bluetooth to confirm the HCI name." >&2
    exit 1
  fi

  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock bluetooth || true
  fi

  if [ "$NO_BATCH" = "true" ] && [ "$HCI" = "hci0" ]; then
    if wait_for_hci_ready; then
      if command -v systemctl >/dev/null 2>&1; then
        systemctl stop bluetooth.service || true
        stopped_bluetoothd=true
      fi
    else
      echo "Controller did not initialize in the readiness window. Aborting." >&2
      exit 1
    fi
  else
    restart_bluetooth_before_apply
  fi

  if [ "$SETTLE_SECONDS" -gt 0 ]; then
    sleep "$SETTLE_SECONDS"
  fi

  for attempt in $(seq 1 "$ATTEMPTS"); do
    if set_public_address "$value"; then
      if [ "$(current_hci_address)" = "$value" ]; then
        echo "Configured Bluetooth public address for $HCI."
      else
        echo "Bluetooth public address was accepted for $HCI."
        echo "Restart bluetooth.service, then validate with bluetoothctl show."
      fi
      return 0
    else
      echo "Attempt $attempt failed to set the Bluetooth public address." >&2
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ]; then
      sleep 2
    fi
  done

  echo "Failed to configure Bluetooth public address for $HCI." >&2
  echo "Current $HCI address: $(format_mac_for_output "$(current_hci_address || true)")" >&2
  if [ "$stopped_bluetoothd" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart bluetooth.service || true
  fi
  exit 1
}

show_status() {
  require_tool btmgmt
  require_tool timeout
  local current
  current="$(current_hci_address || true)"
  echo "Controller: $HCI"
  if [ -n "$MAC" ]; then
    echo "Configured MAC: $(format_mac_for_output "$MAC")"
  else
    echo "Configured MAC: not configured"
  fi
  if [ -n "$current" ]; then
    echo "Current address: $(format_mac_for_output "$current")"
  else
    echo "Current address: not available"
  fi
  run_btmgmt true info || true
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      ACTION="apply"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --show-addresses)
      SHOW_ADDRESSES="true"
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
    --attempts)
      if [ "$#" -lt 2 ]; then
        echo "--attempts requires a value." >&2
        exit 2
      fi
      ATTEMPTS="$2"
      ATTEMPTS_SET="true"
      shift 2
      ;;
    --settle-seconds)
      if [ "$#" -lt 2 ]; then
        echo "--settle-seconds requires a value." >&2
        exit 2
      fi
      SETTLE_SECONDS="$2"
      SETTLE_SECONDS_SET="true"
      shift 2
      ;;
    --btmgmt-timeout)
      if [ "$#" -lt 2 ]; then
        echo "--btmgmt-timeout requires a value." >&2
        exit 2
      fi
      BTMGMT_TIMEOUT="$2"
      BTMGMT_TIMEOUT_SET="true"
      shift 2
      ;;
    --restart-bluetooth-before)
      RESTART_BLUETOOTH_BEFORE="true"
      RESTART_BLUETOOTH_BEFORE_SET="true"
      shift
      ;;
    --no-batch)
      NO_BATCH="true"
      shift
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
    --uninstall-systemd)
      ACTION="uninstall-systemd"
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

if [ "$SHOW_ADDRESSES" = "true" ] && [ "$ACTION" != "status" ]; then
  echo "--show-addresses is only supported with --status." >&2
  exit 2
fi

case "$ACTION" in
  write-config)
    validate_positive_integer "--attempts" "$ATTEMPTS"
    validate_positive_integer "--settle-seconds" "$SETTLE_SECONDS"
    validate_positive_integer "--btmgmt-timeout" "$BTMGMT_TIMEOUT"
    validate_boolean "SP11_BLUETOOTH_RESTART_BLUETOOTH_BEFORE" "$RESTART_BLUETOOTH_BEFORE"
    MAC="$(validate_mac "$MAC")"
    write_config "$MAC"
    ;;
  install-systemd)
    install_systemd
    ;;
  uninstall-systemd)
    uninstall_systemd
    ;;
  status)
    load_config
    if [ -n "$MAC" ]; then
      MAC="$(validate_mac "$MAC")"
    fi
    show_status
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
