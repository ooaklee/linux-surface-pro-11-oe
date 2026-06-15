#!/usr/bin/env bash
set -euo pipefail

DMESG_LINES=180
TOPOLOGY="/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"

usage() {
  cat <<EOF
Usage: $0 [--dmesg-lines N]

Collects Surface Pro 11 audio diagnostics without changing audio state.

Options:
  --dmesg-lines N Number of filtered dmesg lines to print, default 180.
  -h, --help      Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

section "Topology Firmware"
if [ -f "$TOPOLOGY" ]; then
  ls -l "$TOPOLOGY"
else
  echo "Missing topology: $TOPOLOGY"
fi

section "Qualcomm Firmware Directory"
if [ -d /lib/firmware/qcom/x1e80100 ]; then
  find /lib/firmware/qcom/x1e80100 -maxdepth 4 -type f | sort
else
  echo "Missing /lib/firmware/qcom/x1e80100"
fi

section "ALSA Cards"
if [ -r /proc/asound/cards ]; then
  cat /proc/asound/cards
else
  echo "Missing /proc/asound/cards"
fi

section "aplay"
run_or_note aplay aplay -l
run_or_note aplay aplay -L

section "PipeWire and PulseAudio"
run_or_note pactl pactl info
run_or_note pactl pactl list cards
run_or_note pactl pactl list short sinks
run_or_note pactl pactl list short sources
run_or_note wpctl wpctl status
run_or_note wpctl wpctl inspect @DEFAULT_AUDIO_SINK@
run_or_note pw-cli pw-cli ls Card

section "UCM"
if [ -d /usr/share/alsa/ucm2 ]; then
  find /usr/share/alsa/ucm2 -maxdepth 4 -type f \
    \( -iname '*x1e80100*' -o -iname '*surface*' -o -iname '*tuxedo*' -o -iname '*elite*' \) |
    sort
else
  echo "Missing /usr/share/alsa/ucm2"
fi
run_or_note alsaucm alsaucm -c X1E80100Microso dump text

section "Loaded Audio Modules"
if have lsmod; then
  lsmod | grep -iE 'snd|qcom|audioreach|qrtr|apr|gpr|wsa|lpass|soundwire' || true
else
  echo "Missing tool: lsmod"
fi

section "dmesg"
if have dmesg; then
  dmesg -T 2>/dev/null |
    grep -iE 'snd|asoc|audio|audioreach|topology|tplg|qcom-apm|gpr|apr|wsa|rxmacro|txmacro|lpass|soundwire|adsp' |
    tail -n "$DMESG_LINES" || true
else
  echo "Missing tool: dmesg"
fi
