#!/usr/bin/env bash
set -uo pipefail

PROGRAM="${0##*/}"
INCLUDE_KERNEL_LOG="false"
REDACT_STDIN="false"
COMMAND_TIMEOUT_SECONDS=15

export LC_ALL=C

usage() {
  cat <<EOF
Usage: $PROGRAM [--include-kernel-log]
       $PROGRAM --redact-stdin

Collect a read-only, privacy-filtered Surface Pro 11 feature-parity inventory
on standard output. Redirect the output to a file when a persistent report is
required.

  --include-kernel-log  Include filtered kernel messages after identifier and
                        network-value redaction. Omitted by default.
  --redact-stdin        Apply the report redactor to standard input and exit.
                        Intended for fixture tests and pre-publication review.
  -h, --help            Show this help.

The report deliberately excludes host names, user names, serial numbers,
machine IDs, network addresses, saved networks, and the SSH endpoint.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-kernel-log)
      INCLUDE_KERNEL_LOG="true"
      shift
      ;;
    --redact-stdin)
      REDACT_STDIN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

section() {
  printf '\n== %s ==\n' "$1"
}

unavailable() {
  printf '[unavailable: %s]\n' "$1"
}

read_text_file() {
  local path="$1"
  if [ -r "$path" ]; then
    tr -d '\000\n' < "$path"
    printf '\n'
  else
    unavailable "$path"
  fi
}

read_nul_list() {
  local path="$1"
  if [ -r "$path" ]; then
    tr '\000' '\n' < "$path" | sed '/^$/d'
  else
    unavailable "$path"
  fi
}

sanitize_public_values() {
  sed -E \
    -e 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/<redacted-mac>/g' \
    -e 's/([^[:digit:]]|^)([0-9]{1,3}\.){3}[0-9]{1,3}([^[:digit:]]|$)/\1<redacted-ipv4>\3/g' \
    -e 's/([[:xdigit:]]{0,4}:){2,7}[[:xdigit:]]{0,4}/<redacted-ipv6>/g' \
    -e 's/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/<redacted-uuid>/g' \
    -e 's#/(home|Users)/[^/[:space:]]+#/\1/<redacted-user>#g' \
    -e 's/([Ss]erial([[:space:]_-]+[Nn]umber)?|UUID|[Mm]achine[-_ ]?[Ii][Dd])([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\3<redacted-identifier>/g' \
    -e 's/user(-|@)[0-9]+/user\1<redacted-id>/g' \
    -e 's/((fs|o)?uid|gid)=[0-9]+/\1=<redacted-id>/g' \
    -e 's/[[:alnum:].-]+\.ngrok(-free)?\.(app|io)(:[0-9]+)?/<redacted-endpoint>/g'
}

run_optional() {
  local command_name="$1"
  shift
  if command -v "$command_name" >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "$COMMAND_TIMEOUT_SECONDS" "$command_name" "$@" 2>&1 || true
    else
      "$command_name" "$@" 2>&1 || true
    fi
  else
    unavailable "$command_name"
  fi
}

filter_kernel_log() {
  grep -iE '(mshw0485|surface g6|hid.?spi|ipts|camss|imx681|ov13858|vd55|camera|wsa884|soundwire|dmic|suspend|resume|psci|cpuidle|platform.?profile|gpio-keys|(^|[^[:alnum:]_])(pen|stylus)([^[:alnum:]_]|$))' |
    tail -n 500 |
    sanitize_public_values
}

if [ "$REDACT_STDIN" = "true" ]; then
  sanitize_public_values
  exit 0
fi

collect_inventory() {
printf 'Surface Pro 11 feature-parity inventory\n'
printf 'Schema: 2\n'
printf 'Collected (UTC): '
date -u '+%Y-%m-%dT%H%M%SZ'

section "Operating system and hardware"
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Kernel release: %s\n' "$(uname -r)"
if [ -r /etc/os-release ]; then
  (
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'Distribution: %s %s\n' "${NAME:-unknown}" "${VERSION_ID:-unknown}"
  )
else
  unavailable /etc/os-release
fi
printf 'Device-tree model: '
read_text_file /proc/device-tree/model
printf 'Device-tree compatible strings:\n'
read_nul_list /proc/device-tree/compatible

for item in product_name bios_vendor bios_version bios_date; do
  path="/sys/class/dmi/id/$item"
  [ -r "$path" ] || continue
  printf '%s: ' "$item"
  read_text_file "$path"
done

section "Installed qcom-x1e kernels"
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' \
    'linux-image*qcom-x1e*' 'linux-headers*qcom-x1e*' 2>/dev/null |
    awk '$1 == "ii" {print $2 "\t" $3}' | sort -u || true
else
  unavailable dpkg-query
fi
if [ -r /boot/grub/grubenv ] && command -v grub-editenv >/dev/null 2>&1; then
  printf 'GRUB environment:\n'
  grub-editenv /boot/grub/grubenv list 2>/dev/null || true
fi

section "Loaded SP11-related modules"
if command -v lsmod >/dev/null 2>&1; then
  lsmod | awk '
    NR == 1 ||
    $1 ~ /^(gpi|spi_geni_qcom|mshw0485_touch|hid_multitouch|snd_soc_wsa884x|qcom_camss|ov13858|imx681|vd55g0|vd55g1|gpio_keys)$/ ||
    $1 ~ /^(surface_|soundwire_|snd_soc_lpass_|q6apm)/
  '
else
  unavailable lsmod
fi

section "Input devices"
if [ -r /proc/bus/input/devices ]; then
  awk 'BEGIN {RS=""; ORS=""}
    /Microsoft Surface G6 Touch|gpio-keys|pmic_pwrkey|Surface.*(Pen|Stylus)/ {
      count = split($0, lines, "\n")
      output = ""
      for (line = 1; line <= count; line++) {
        if (lines[line] ~ /^(I:|N:|P:|H:)/) output = output lines[line] "\n"
      }
      if (output != "") print output "\n"
    }
  ' /proc/bus/input/devices
else
  unavailable /proc/bus/input/devices
fi
printf 'IPTSD executable: '
if command -v iptsd >/dev/null 2>&1; then
  printf '[installed]\n'
else
  printf '[not installed]\n'
fi
if command -v systemctl >/dev/null 2>&1; then
  printf 'IPTSD service enabled: '
  if systemctl is-enabled --quiet iptsd.service 2>/dev/null; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'IPTSD service active: '
  if systemctl is-active --quiet iptsd.service 2>/dev/null; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
fi

section "USB identities"
run_optional lsusb

section "Audio devices"
run_optional aplay -l
run_optional arecord -l

section "Media and camera devices"
media_nodes_found="false"
for pattern in /dev/media\* /dev/video\* /dev/v4l-subdev\*; do
  for path in $pattern; do
    if [ -e "$path" ]; then
      printf '%s\n' "$path"
      media_nodes_found="true"
    fi
  done
done
[ "$media_nodes_found" = "true" ] || printf '[no media device nodes found]\n'
run_optional media-ctl --print-topology
run_optional v4l2-ctl --list-devices

section "Relevant live device-tree nodes"
if [ -d /proc/device-tree ]; then
  dt_nodes="$(find /proc/device-tree -type d 2>/dev/null |
    grep -Ei '/(isp|camss|cci|camera|csiphy|spi)@|/touchscreen@' |
    sort || true)"
  if [ -n "$dt_nodes" ]; then
    printf '%s\n' "$dt_nodes"
  else
    printf '[no matching live device-tree nodes found]\n'
  fi
else
  unavailable /proc/device-tree
fi

section "Suspend and CPU idle"
printf 'mem_sleep: '
read_text_file /sys/power/mem_sleep
printf 'cpuidle driver: '
read_text_file /sys/devices/system/cpu/cpuidle/current_driver
printf 'cpuidle governor: '
read_text_file /sys/devices/system/cpu/cpuidle/current_governor_ro
if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
  for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    [ -d "$state" ] || continue
    printf '%s: name=' "${state##*/}"
    tr -d '\n' < "$state/name" 2>/dev/null || printf unknown
    printf ' disable='
    tr -d '\n' < "$state/disable" 2>/dev/null || printf unknown
    printf '\n'
  done
fi

section "Platform profile and CPU-frequency policies"
for path in /sys/firmware/acpi/platform_profile_choices \
  /sys/firmware/acpi/platform_profile; do
  printf '%s: ' "${path##*/}"
  read_text_file "$path"
done
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -d "$policy" ] || continue
  printf '%s:' "${policy##*/}"
  for property in scaling_driver scaling_governor scaling_min_freq scaling_max_freq \
    cpuinfo_min_freq cpuinfo_max_freq; do
    value=""
    [ -r "$policy/$property" ] && read -r value < "$policy/$property"
    [ -n "$value" ] && printf ' %s=%s' "$property" "$value"
  done
  printf '\n'
done

section "Kernel configuration"
config_path="/boot/config-$(uname -r)"
if [ -r /proc/config.gz ] && command -v zgrep >/dev/null 2>&1; then
  zgrep -E '^CONFIG_(VIDEO_QCOM_CAMSS|VIDEO_OV13858|VIDEO_IMX681|VIDEO_VD55G0|VIDEO_VD55G1|SURFACE_PLATFORM_PROFILE|SURFACE_AGGREGATOR|HIDRAW|UHID|INPUT_EVDEV|CPU_IDLE|ARM_PSCI_CPUIDLE)=' \
    /proc/config.gz || true
elif [ -r "$config_path" ]; then
  grep -E '^CONFIG_(VIDEO_QCOM_CAMSS|VIDEO_OV13858|VIDEO_IMX681|VIDEO_VD55G0|VIDEO_VD55G1|SURFACE_PLATFORM_PROFILE|SURFACE_AGGREGATOR|HIDRAW|UHID|INPUT_EVDEV|CPU_IDLE|ARM_PSCI_CPUIDLE)=' \
    "$config_path" || true
else
  unavailable "kernel configuration"
fi

if [ "$INCLUDE_KERNEL_LOG" = "true" ]; then
  section "Filtered kernel log"
  if command -v dmesg >/dev/null 2>&1 && dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | filter_kernel_log || unavailable "filtered kernel log"
  elif command -v journalctl >/dev/null 2>&1 &&
    journalctl -k -b -o short-monotonic --no-hostname --no-pager >/dev/null 2>&1; then
    journalctl -k -b -o short-monotonic --no-hostname --no-pager 2>/dev/null |
      filter_kernel_log || unavailable "filtered kernel log"
  else
    unavailable "kernel log access"
  fi
fi

section "Inventory boundary"
printf '%s\n' \
  'This report is observational. It does not prove feature correctness.' \
  'No firmware, NVM, boot configuration, module state, or device setting was changed.'
}

# Sanitize the assembled report as one final boundary. Individual commands
# are intentionally not trusted to omit identifiers or private paths.
collect_inventory | sanitize_public_values
