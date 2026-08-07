#!/usr/bin/env bash
set -uo pipefail

PROGRAM="${0##*/}"
TARGET_ROOT="/"
RELEASE=""
DMESG_FILE=""
INITRD_OVERRIDE=""
FAILURES=0
WARNINGS=0

usage() {
  cat <<EOF
Usage: $PROGRAM [options]

Read-only diagnostics for the Surface Pro 11 MSHW0485 QSPI touchscreen.

Options:
  --release RELEASE   Kernel ABI to inspect (default: running kernel).
  --root DIR          Filesystem root to inspect (default /). With a non-live
                       root, supply --release; live dmesg checks are skipped.
  --dmesg FILE        Read a saved kernel log instead of the current boot log.
  --initrd FILE       Inspect this initramfs instead of the standard ABI path.
  -h, --help           Show this help.

Exit status is zero only when no failure is detected. Warnings alone do not
change the exit status.
EOF
}

fail() {
  echo "[FAIL] $*"
  FAILURES=$((FAILURES + 1))
}

warn() {
  echo "[WARN] $*"
  WARNINGS=$((WARNINGS + 1))
}

ok() {
  echo "[ OK ] $*"
}

info() {
  echo "[INFO] $*"
}

usage_error() {
  echo "error: $*" >&2
  usage >&2
  exit 2
}

require_value() {
  [ -n "${2:-}" ] || usage_error "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      require_value "$1" "${2:-}"
      RELEASE="$2"
      shift 2
      ;;
    --release=*)
      RELEASE="${1#*=}"
      [ -n "$RELEASE" ] || usage_error "--release cannot be empty"
      shift
      ;;
    --root)
      require_value "$1" "${2:-}"
      TARGET_ROOT="$2"
      shift 2
      ;;
    --root=*)
      TARGET_ROOT="${1#*=}"
      [ -n "$TARGET_ROOT" ] || usage_error "--root cannot be empty"
      shift
      ;;
    --dmesg)
      require_value "$1" "${2:-}"
      DMESG_FILE="$2"
      shift 2
      ;;
    --dmesg=*)
      DMESG_FILE="${1#*=}"
      [ -n "$DMESG_FILE" ] || usage_error "--dmesg cannot be empty"
      shift
      ;;
    --initrd)
      require_value "$1" "${2:-}"
      INITRD_OVERRIDE="$2"
      shift 2
      ;;
    --initrd=*)
      INITRD_OVERRIDE="${1#*=}"
      [ -n "$INITRD_OVERRIDE" ] || usage_error "--initrd cannot be empty"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

command -v realpath >/dev/null 2>&1 || {
  echo "error: required command not found: realpath" >&2
  exit 2
}
TARGET_ROOT="$(realpath -e -- "$TARGET_ROOT" 2>/dev/null)" ||
  usage_error "cannot resolve --root"
[ -d "$TARGET_ROOT" ] || usage_error "not a directory: $TARGET_ROOT"

if [ -z "$RELEASE" ]; then
  [ "$TARGET_ROOT" = "/" ] || usage_error "--release is required with a non-live --root"
  RELEASE="$(uname -r)"
fi
case "$RELEASE" in
  ""|*[!A-Za-z0-9._+~-]*|[!A-Za-z0-9]*)
    usage_error "unsafe kernel release: '$RELEASE'"
    ;;
esac

root_path() {
  local absolute="$1"
  printf '%s%s' "${TARGET_ROOT%/}" "$absolute"
}

module_files=(gpi.ko spi-geni-qcom.ko mshw0485_touch.ko)
module_names=(gpi spi_geni_qcom mshw0485_touch)
module_relpaths=(
  updates/drivers/dma/qcom/gpi.ko
  updates/drivers/spi/spi-geni-qcom.ko
  updates/drivers/input/touchscreen/mshw0485_touch.ko
)

echo "Surface Pro 11 touchscreen diagnostic"
echo "Root: $TARGET_ROOT"
echo "Kernel release: $RELEASE"
if [ "$TARGET_ROOT" = "/" ]; then
  echo "Running release: $(uname -r)"
fi
echo

if ! command -v modinfo >/dev/null 2>&1; then
  fail "modinfo is unavailable; module identity cannot be checked"
else
  echo "Disk module selection"
  for index in "${!module_names[@]}"; do
    expected="$(root_path "/lib/modules/$RELEASE/${module_relpaths[index]}")"
    selected="$(modinfo -b "$TARGET_ROOT" -k "$RELEASE" -n "${module_names[index]}" 2>/dev/null || true)"
    if [ ! -f "$expected" ]; then
      fail "missing override: $expected"
    fi
    expected_suffix="/lib/modules/$RELEASE/${module_relpaths[index]}"
    case "$selected" in
      *"$expected_suffix"|*"/usr$expected_suffix")
        ok "${module_names[index]} selects the updates/ override: $selected"
        ;;
      "")
        fail "${module_names[index]} is not selectable for $RELEASE"
        ;;
      *)
        fail "${module_names[index]} selects a stock or unexpected module: $selected"
        ;;
    esac

    if [ -f "$expected" ]; then
      vermagic="$(modinfo -F vermagic "$expected" 2>/dev/null || true)"
      disk_release="${vermagic%%[[:space:]]*}"
      if [ "$disk_release" = "$RELEASE" ]; then
        ok "${module_files[index]} vermagic matches $RELEASE"
      else
        fail "${module_files[index]} vermagic '${disk_release:-unknown}' does not match $RELEASE"
      fi
    fi
  done
  echo
fi

echo "Loaded-versus-disk identity"
if [ "$TARGET_ROOT" != "/" ] || [ "$RELEASE" != "$(uname -r)" ]; then
  warn "loaded-module comparison is unavailable for an offline or non-running release"
else
  for index in "${!module_names[@]}"; do
    module="${module_names[index]}"
    expected="/lib/modules/$RELEASE/${module_relpaths[index]}"
    sys_module="/sys/module/$module"
    if [ ! -d "$sys_module" ]; then
      fail "$module is not loaded"
      continue
    fi
    loaded_srcversion=""
    disk_srcversion=""
    [ -r "$sys_module/srcversion" ] && read -r loaded_srcversion < "$sys_module/srcversion"
    [ -f "$expected" ] && disk_srcversion="$(modinfo -F srcversion "$expected" 2>/dev/null || true)"
    if [ -n "$loaded_srcversion" ] && [ -n "$disk_srcversion" ]; then
      if [ "$loaded_srcversion" = "$disk_srcversion" ]; then
        ok "$module loaded srcversion matches the selected disk override ($disk_srcversion)"
      else
        fail "$module loaded srcversion $loaded_srcversion differs from disk $disk_srcversion; reboot or initramfs repair is required"
      fi
    else
      warn "$module is loaded, but srcversion metadata is unavailable for a conclusive comparison"
    fi
  done
fi
echo

echo "Controller profile"
if command -v modinfo >/dev/null 2>&1; then
  spi_override="$(root_path "/lib/modules/$RELEASE/${module_relpaths[1]}")"
  if [ -f "$spi_override" ] &&
     modinfo -p "$spi_override" 2>/dev/null | grep -q '^sp11_windows_se_init:'; then
    ok "selected SPI override exposes sp11_windows_se_init"
  else
    fail "selected SPI module lacks sp11_windows_se_init and is probably stock"
  fi
fi
parameter_path="$(root_path /sys/module/spi_geni_qcom/parameters/sp11_windows_se_init)"
if [ -r "$parameter_path" ]; then
  read -r se_value < "$parameter_path"
  case "$se_value" in
    N|0|n)
      ok "sp11_windows_se_init=$se_value (normal validated Linux-integrated profile)"
      ;;
    Y|1|y)
      warn "sp11_windows_se_init=$se_value (experimental Windows cold-init opt-in)"
      ;;
    *)
      warn "sp11_windows_se_init has unexpected value '$se_value'"
      ;;
  esac
elif [ "$TARGET_ROOT" = "/" ] && [ "$RELEASE" = "$(uname -r)" ]; then
  fail "loaded SPI module has no sp11_windows_se_init parameter; stale stock module is likely"
else
  warn "live sp11_windows_se_init value is unavailable for this root/release"
fi
echo

echo "Firmware"
firmware_found=""
for candidate in \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.zst \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.xz \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf; do
  if [ -f "$(root_path "$candidate")" ]; then
    firmware_found="$candidate"
    break
  fi
done
if [ -n "$firmware_found" ]; then
  ok "QUP firmware present: $firmware_found"
else
  fail "missing QUP firmware: /lib/firmware/qcom/x1e80100/qupv3fw.elf[.zst|.xz]"
fi
echo

echo "Live device tree and client"
DT_BASE=""
for candidate in /sys/firmware/devicetree/base /proc/device-tree; do
  if [ -d "$(root_path "$candidate")" ]; then
    DT_BASE="$(root_path "$candidate")"
    break
  fi
done
if [ -z "$DT_BASE" ]; then
  if [ "$TARGET_ROOT" = "/" ] && [ "$RELEASE" = "$(uname -r)" ]; then
    fail "live device tree is unavailable; SPI10 and MSHW0485 nodes cannot be verified"
  else
    warn "live device tree is unavailable; SPI10 and MSHW0485 nodes were not checked"
  fi
else
  spi_node="$(find "$DT_BASE" -type d -name 'spi@a88000' -print -quit 2>/dev/null || true)"
  if [ -z "$spi_node" ]; then
    fail "device tree lacks the QSPI controller node spi@a88000"
  else
    status="okay"
    if [ -r "$spi_node/status" ]; then
      status="$(tr -d '\000' < "$spi_node/status" 2>/dev/null || true)"
    fi
    case "$status" in
      okay|ok|"") ok "device-tree QSPI controller is enabled: $spi_node" ;;
      *) fail "device-tree QSPI controller status is '$status': $spi_node" ;;
    esac

    touch_compatible="$(find "$spi_node" -type f -name compatible -exec grep -a -l 'microsoft,mshw0485' {} + 2>/dev/null | head -n 1 || true)"
    if [ -n "$touch_compatible" ]; then
      ok "device tree contains microsoft,mshw0485: ${touch_compatible%/compatible}"
    else
      fail "device tree lacks a microsoft,mshw0485 child below spi@a88000"
    fi
  fi
fi

if [ "$TARGET_ROOT" = "/" ] && [ "$RELEASE" = "$(uname -r)" ]; then
  if find -L /sys/bus/spi/devices -maxdepth 3 -type f \( -name modalias -o -name uevent \) \
      -exec grep -a -q -E 'mshw0485|MSHW0485' {} \; -print -quit 2>/dev/null |
      grep -q .; then
    ok "MSHW0485 is registered on the live SPI bus"
  else
    fail "MSHW0485 is not registered on the live SPI bus"
  fi
  if [ -r /proc/bus/input/devices ] &&
     grep -q 'Microsoft Surface G6 Touch' /proc/bus/input/devices; then
    ok "Microsoft Surface G6 Touch is present in /proc/bus/input/devices"
  else
    fail "Microsoft Surface G6 Touch is absent from /proc/bus/input/devices"
  fi
else
  warn "live SPI client registration is unavailable for this root/release"
fi
echo

echo "Initramfs contents"
if [ -n "$INITRD_OVERRIDE" ]; then
  INITRD="$(realpath -e -- "$INITRD_OVERRIDE" 2>/dev/null || true)"
else
  INITRD="$(root_path "/boot/initrd.img-$RELEASE")"
fi
if [ -z "$INITRD" ] || [ ! -s "$INITRD" ]; then
  fail "initramfs is missing or empty: ${INITRD_OVERRIDE:-$(root_path "/boot/initrd.img-$RELEASE")}"
elif [ ! -r "$INITRD" ]; then
  fail "initramfs is not readable: $INITRD (rerun with sudo to verify its module paths)"
else
  listing_file="$(mktemp)"
  trap 'rm -f -- "$listing_file"' EXIT HUP INT TERM
  listing_ok="false"
  if command -v lsinitramfs >/dev/null 2>&1 &&
     lsinitramfs "$INITRD" > "$listing_file" 2>/dev/null; then
    info "inspected $INITRD with lsinitramfs"
    listing_ok="true"
  elif command -v lsinitrd >/dev/null 2>&1 &&
       lsinitrd "$INITRD" > "$listing_file" 2>/dev/null; then
    info "inspected $INITRD with lsinitrd"
    listing_ok="true"
  else
    fail "neither lsinitramfs nor lsinitrd could inspect $INITRD"
  fi
  if [ "$listing_ok" = "true" ]; then
    for relative in "${module_relpaths[@]}"; do
      initrd_path="lib/modules/$RELEASE/$relative"
      if grep -Fq "$initrd_path" "$listing_file" ||
         grep -Fq "usr/$initrd_path" "$listing_file"; then
        ok "initramfs contains override path: $initrd_path"
      else
        fail "initramfs lacks override path: $initrd_path"
      fi
    done
  fi
fi
echo

echo "Current-boot kernel log classification"
log_file=""
temporary_log=""
if [ -n "$DMESG_FILE" ]; then
  log_file="$(realpath -e -- "$DMESG_FILE" 2>/dev/null || true)"
  [ -n "$log_file" ] && [ -r "$log_file" ] || fail "cannot read --dmesg file: $DMESG_FILE"
elif [ "$TARGET_ROOT" = "/" ] && [ "$RELEASE" = "$(uname -r)" ]; then
  temporary_log="$(mktemp)"
  if dmesg > "$temporary_log" 2>/dev/null; then
    log_file="$temporary_log"
  elif command -v journalctl >/dev/null 2>&1 &&
       journalctl -k -b --no-pager > "$temporary_log" 2>/dev/null; then
    log_file="$temporary_log"
  else
    warn "current kernel log is unreadable; rerun with sudo or supply --dmesg FILE"
  fi
else
  warn "kernel log classification skipped for an offline or non-running release"
fi

if [ -n "$log_file" ] && [ -r "$log_file" ]; then
  if grep -q -E 'geni_spi a88000\.spi: Invalid proto 9' "$log_file"; then
    fail "Invalid proto 9: the booted initramfs loaded the stock SPI controller instead of the SP11 override"
  elif grep -q -E 'a88000\.spi: SP11: accepting protocol 9 as QSPI controller' "$log_file"; then
    ok "patched SPI controller accepted QSPI protocol 9"
  else
    warn "no SPI protocol-9 acceptance marker was found"
  fi

  if grep -q -E 'CH START completion timeout' "$log_file"; then
    fail "GPI CH START timeout: stale/stock GPI DMA or an incomplete initramfs override is likely"
  elif grep -q -E 'SP11: QSPI using GPI DMA descriptor mode' "$log_file"; then
    ok "QSPI is using GPI DMA descriptor mode"
  else
    warn "no GPI DMA success marker was found"
  fi

  if grep -q -E 'sync_state\(\) pending due to a88000\.spi' "$log_file"; then
    fail "deferred sync_state dependencies remain blocked by a88000.spi"
  fi
  if grep -q -E '(Direct firmware load|failed to load).*(qupv3fw|qup.*fw)' "$log_file"; then
    fail "kernel log reports a QUP firmware load failure"
  fi

  if grep -q -E 'touch controller initialized path=hardware' "$log_file"; then
    ok "MSHW0485 controller completed hardware initialization"
  elif grep -q -E 'Microsoft Surface G6 Touch' "$log_file"; then
    warn "input device registered, but the final hardware-initialized marker is absent"
  else
    fail "kernel log has no Microsoft Surface G6 Touch initialization marker"
  fi
fi
[ -z "$temporary_log" ] || rm -f -- "$temporary_log"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "Result: FAIL ($FAILURES failure(s), $WARNINGS warning(s))"
  exit 1
fi
echo "Result: PASS ($WARNINGS warning(s))"
exit 0
