#!/usr/bin/env bash
set -euo pipefail

TRY_UNBLOCK="false"
DMESG_LINES=120

usage() {
  cat <<EOF
Usage: $0 [--try-unblock] [--dmesg-lines N]

Collects Surface Pro 11 WCN7850 Wi-Fi rfkill diagnostics.

By default this script is read-only. Pass --try-unblock to run
sudo rfkill unblock all before collecting state.

Options:
  --try-unblock    Attempt to clear software rfkill blocks before reporting.
  --dmesg-lines N  Number of filtered dmesg lines to print, default 120.
  -h, --help       Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --try-unblock)
      TRY_UNBLOCK="true"
      shift
      ;;
    --dmesg-lines)
      if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
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

module_reader() {
  case "$1" in
    *.zst) printf '%s\n' zstdcat ;;
    *.xz) printf '%s\n' xzcat ;;
    *) printf '%s\n' cat ;;
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

if [ "$TRY_UNBLOCK" = "true" ]; then
  section "Unblock Attempt"
  if have rfkill; then
    sudo rfkill unblock all || true
  else
    echo "Missing tool: rfkill"
  fi
fi

section "rfkill"
run_or_note rfkill rfkill list

section "rfkill sysfs"
for rfkill_dir in /sys/class/rfkill/rfkill*; do
  [ -d "$rfkill_dir" ] || continue
  name="$(cat "$rfkill_dir/name" 2>/dev/null || true)"
  type="$(cat "$rfkill_dir/type" 2>/dev/null || true)"
  soft="$(cat "$rfkill_dir/soft" 2>/dev/null || true)"
  hard="$(cat "$rfkill_dir/hard" 2>/dev/null || true)"
  printf '%s: name=%s type=%s soft=%s hard=%s\n' "$rfkill_dir" "$name" "$type" "$soft" "$hard"
done

section "PCI Wi-Fi"
if have lspci; then
  lspci -nn | grep -iE 'network|qualcomm|wcn|ath' || true
else
  echo "Missing tool: lspci"
fi

section "Network Interfaces"
run_or_note ip ip link show

section "Device Tree Wi-Fi Node"
wifi_node="$(find /sys/firmware/devicetree/base -type d -name 'wifi@0' 2>/dev/null | head -n 1 || true)"
echo "WIFI_NODE=${wifi_node:-not found}"
if [ -n "$wifi_node" ]; then
  if [ -e "$wifi_node/disable-rfkill" ]; then
    echo "DT has disable-rfkill"
  else
    echo "DT is missing disable-rfkill"
  fi
  echo "Wi-Fi node properties:"
  find "$wifi_node" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | sort || true
fi

section "ath12k Module disable-rfkill String Scan"
found=0
if ! have strings; then
  echo "Missing tool: strings; cannot scan ath12k modules for disable-rfkill support"
else
  while IFS= read -r module; do
    reader="$(module_reader "$module")"
    if ! have "$reader"; then
      echo "Skipping $module; missing reader: $reader"
      continue
    fi
    if "$reader" "$module" 2>/dev/null | strings | grep -q 'disable-rfkill'; then
      echo "disable-rfkill support found in $module"
      found=1
    fi
  done < <(find "/lib/modules/$(uname -r)" -type f -path '*ath12k*' 2>/dev/null | sort)
fi
if [ "$found" != "1" ] && have strings; then
  echo "disable-rfkill string not found in installed ath12k modules"
  echo "Note: this string scan is best-effort; rfkill hard=0 with DT disable-rfkill is the runtime validation."
fi

section "Firmware Directory"
fw_dir="/lib/firmware/ath12k/WCN7850/hw2.0"
if [ -d "$fw_dir" ]; then
  ls -l "$fw_dir"
else
  echo "Missing firmware directory: $fw_dir"
fi

section "Loaded Modules"
if have lsmod; then
  lsmod | grep -iE 'ath12k|wcn|cfg80211|mac80211' || true
else
  echo "Missing tool: lsmod"
fi

section "dmesg"
if have dmesg; then
  dmesg -T 2>/dev/null | grep -iE 'ath12k|wcn|rfkill|firmware|board|qcom|gpio|wlan|airplane' | tail -n "$DMESG_LINES" || true
else
  echo "Missing tool: dmesg"
fi
