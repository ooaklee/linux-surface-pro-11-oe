#!/usr/bin/env bash
set -uo pipefail

PROGRAM="${0##*/}"
INCLUDE_KERNEL_LOG="false"
REDACT_STDIN="false"
FILTER_G6_STATS_STDIN="false"
FILTER_KERNEL_LOG_STDIN="false"
COMMAND_TIMEOUT_SECONDS=15

export LC_ALL=C

usage() {
  cat <<EOF
Usage: $PROGRAM [--include-kernel-log]
       $PROGRAM --redact-stdin
       $PROGRAM --filter-g6-stats-stdin
       $PROGRAM --filter-kernel-log-stdin

Collect a read-only, privacy-filtered Surface Pro 11 feature-parity inventory
on standard output. Redirect the output to a file when a persistent report is
required.

  --include-kernel-log  Include bounded, filtered kernel messages. This
                        optional section remains local-sensitive and requires
                        manual content review before publication.
  --redact-stdin        Apply the report redactor to standard input and exit.
                        Intended for fixture tests and pre-publication review.
  --filter-g6-stats-stdin
                        Apply the strict behavior_stats scalar allowlist to
                        standard input and exit. Intended for fixture tests.
  --filter-kernel-log-stdin
                        Apply the local-sensitive kernel-log filter to standard
                        input and exit. Intended for fixture tests.
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
    --filter-g6-stats-stdin)
      FILTER_G6_STATS_STDIN="true"
      shift
      ;;
    --filter-kernel-log-stdin)
      FILTER_KERNEL_LOG_STDIN="true"
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

filter_g6_behavior_stats() {
  awk -F '=' '
    NF != 2 { next }
    ($1 == "profile" || $1 == "initialization_stage") &&
      $2 ~ /^[a-z0-9][a-z0-9-]*$/ && length($2) <= 32 { print; next }
    ($1 == "mode_enabled" || $1 == "awaiting_ready_heat") &&
      $2 ~ /^[01]$/ { print; next }
    ($1 == "heat_frames" || $1 == "heat_errors" ||
     $1 == "panel_resets" || $1 == "recovery_successes" ||
     $1 == "recovery_failures" || $1 == "hardware_recovery_attempts" ||
     $1 == "software_recovery_attempts" ||
     $1 == "software_recovery_fallbacks" ||
     $1 == "reset_storm_escalations" ||
     $1 == "host_fault_recoveries" ||
     $1 == "irq_transport_errors" || $1 == "irq_protocol_errors" ||
     $1 == "irq_drain_overflows" || $1 == "quiesced_empty_reads" ||
     $1 == "ready_heat_frames" || $1 == "ready_verification_failures") &&
      $2 ~ /^[0-9]+$/ && length($2) <= 20 { print; next }
  '
}

sanitize_kernel_material() {
  sed -E \
    -e 's/[[:xdigit:]]{2}([[:space:]:,-]+[[:xdigit:]]{2}){3,}/<redacted-binary>/g' \
    -e 's/((^|[^[:alnum:]_])(x|y|pressure|tilt|contact)[[:space:]_-]*=[[:space:]]*)-?[0-9]+/\1<redacted-input-value>/g'
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
  grep -iE '(mshw0485|surface g6|hid.?spi|ipts|camss|ov02c10|imx681|ov13858|vd55|camera|wsa884|soundwire|dmic|suspend|resume|psci|cpuidle|platform.?profile|gpio-keys|(^|[^[:alnum:]_])(pen|stylus)([^[:alnum:]_]|$))' |
    grep -viE '(parity_feature|parity_cfu|cfu_(version|offer)|last_header|raw[ _-]*(report|payload)|report[ _-]*(bytes|payload|hex)|stroke|handwriting)' |
    tail -n 500 |
    sanitize_kernel_material |
    sanitize_public_values
}

stdin_filter_count=0
for stdin_filter in "$REDACT_STDIN" "$FILTER_G6_STATS_STDIN" \
  "$FILTER_KERNEL_LOG_STDIN"; do
  [ "$stdin_filter" = "true" ] && stdin_filter_count=$((stdin_filter_count + 1))
done
if [ "$stdin_filter_count" -gt 1 ]; then
  echo "error: choose only one standard-input filter" >&2
  exit 2
fi
if [ "$REDACT_STDIN" = "true" ]; then
  sanitize_public_values
  exit 0
fi
if [ "$FILTER_G6_STATS_STDIN" = "true" ]; then
  filter_g6_behavior_stats
  exit 0
fi
if [ "$FILTER_KERNEL_LOG_STDIN" = "true" ]; then
  filter_kernel_log
  exit 0
fi

collect_inventory() {
printf 'Surface Pro 11 feature-parity inventory\n'
printf 'Schema: 3\n'
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
    $1 ~ /^(gpi|spi_geni_qcom|mshw0485_touch|hid_multitouch|snd_soc_wsa884x|i2c_qcom_cci|qcom_camss|ov02c10|ov13858|imx681|vd55g0|vd55g1|gpio_keys)$/ ||
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

section "G6 touchscreen profile and safe counters"
touchscreen_stats_found="false"
for stats_path in /sys/bus/spi/devices/*/behavior_stats; do
  [ -r "$stats_path" ] || continue
  stats_device="${stats_path%/behavior_stats}"
  stats_device_name="${stats_device##*/}"
  [[ "$stats_device_name" =~ ^spi[0-9]+\.[0-9]+$ ]] || continue
  [ -L "$stats_device/driver" ] || continue
  [ "$(basename "$(readlink "$stats_device/driver")")" = "mshw0485-touch" ] || continue
  [ "$(tr -d '\000\n' < "$stats_device/modalias" 2>/dev/null)" = "spi:mshw0485" ] || continue
  tr '\000' '\n' < "$stats_device/of_node/compatible" 2>/dev/null |
    grep -Fx 'microsoft,mshw0485' >/dev/null || continue
  touchscreen_stats_found="true"
  printf 'Device: /sys/bus/spi/devices/%s\n' "$stats_device_name"
  filter_g6_behavior_stats < "$stats_path" 2>/dev/null || true
done
[ "$touchscreen_stats_found" = "true" ] || printf '[no readable behavior_stats found]\n'

printf 'Safe mshw0485_touch parameters:\n'
touchscreen_parameters_found="false"
for parameter in behavior_v2 mode_config_fix feature70_one_byte \
  reset_recovery_v2 reset_storm_breaker host_fault_recovery ready_quiesce \
  windows_orchestrator windows_init_parity parity_linux_power \
  windows_read_cadence; do
  parameter_path="/sys/module/mshw0485_touch/parameters/$parameter"
  [ -r "$parameter_path" ] || continue
  touchscreen_parameters_found="true"
  parameter_value=""
  IFS= read -r parameter_value < "$parameter_path" || true
  case "$parameter_value" in
    Y|N|y|n|0|1) printf '%s=%s\n' "$parameter" "$parameter_value" ;;
    *) printf '%s=[invalid value omitted]\n' "$parameter" ;;
  esac
done
[ "$touchscreen_parameters_found" = "true" ] || printf '[no readable allowlisted parameters found]\n'

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
  printf 'IPTSD template unit installed: '
  if systemctl list-unit-files --no-legend 'iptsd@.service' 2>/dev/null |
    grep -q '^iptsd@\.service'; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  printf 'IPTSD template instance active: '
  if systemctl list-units --type=service --state=active --no-legend \
    'iptsd@*.service' 2>/dev/null | grep -q '^iptsd@'; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
fi
printf 'IPTSD generic udev discovery rule present: '
iptsd_udev_rule="false"
for rule in /etc/udev/rules.d/*iptsd*.rules /run/udev/rules.d/*iptsd*.rules \
  /usr/lib/udev/rules.d/*iptsd*.rules /lib/udev/rules.d/*iptsd*.rules; do
  [ -f "$rule" ] || continue
  if grep -q 'iptsd' "$rule" 2>/dev/null; then
    iptsd_udev_rule="true"
    break
  fi
done
printf '%s\n' "$iptsd_udev_rule"

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
  zgrep -E '^CONFIG_(I2C_QCOM_CCI|VIDEO_QCOM_CAMSS|VIDEO_OV02C10|VIDEO_OV13858|VIDEO_IMX681|VIDEO_VD55G0|VIDEO_VD55G1|SURFACE_PLATFORM_PROFILE|SURFACE_AGGREGATOR|HIDRAW|UHID|INPUT_EVDEV|CPU_IDLE|ARM_PSCI_CPUIDLE)=' \
    /proc/config.gz || true
elif [ -r "$config_path" ]; then
  grep -E '^CONFIG_(I2C_QCOM_CCI|VIDEO_QCOM_CAMSS|VIDEO_OV02C10|VIDEO_OV13858|VIDEO_IMX681|VIDEO_VD55G0|VIDEO_VD55G1|SURFACE_PLATFORM_PROFILE|SURFACE_AGGREGATOR|HIDRAW|UHID|INPUT_EVDEV|CPU_IDLE|ARM_PSCI_CPUIDLE)=' \
    "$config_path" || true
else
  unavailable "kernel configuration"
fi

if [ "$INCLUDE_KERNEL_LOG" = "true" ]; then
  section "Filtered kernel log"
  printf '[local-sensitive: manually review before publication]\n'
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
