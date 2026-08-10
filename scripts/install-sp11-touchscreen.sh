#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
MODULES_DIR=""
REQUESTED_RELEASE=""
TARGET_ROOT="/"
WINDOWS_SE_INIT="false"

usage() {
  cat <<EOF
Usage: sudo $PROGRAM --modules-dir DIR [options]

Install the matched Surface Pro 11 touchscreen module set for one exact kernel
ABI and rebuild that ABI's initramfs.

Required:
  --modules-dir DIR    Directory containing gpi.ko, spi-geni-qcom.ko, and
                       mshw0485_touch.ko.

Options:
  --release RELEASE   Expected kernel release. By default it is inferred from
                       the common module vermagic. A supplied value must match.
  --root DIR          Installed-system root (default /). Non-live roots must be
                       runnable with chroot so their own initramfs tool is used.
  --windows-se-init   Opt in to the experimental captured Windows cold-init
                       controller sequence. The validated default is off.
  -h, --help           Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

require_value() {
  if [ -z "${2:-}" ]; then
    echo "error: $1 requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --modules-dir)
      require_value "$1" "${2:-}"
      MODULES_DIR="$2"
      shift 2
      ;;
    --modules-dir=*)
      MODULES_DIR="${1#*=}"
      [ -n "$MODULES_DIR" ] || die "--modules-dir cannot be empty"
      shift
      ;;
    --release)
      require_value "$1" "${2:-}"
      REQUESTED_RELEASE="$2"
      shift 2
      ;;
    --release=*)
      REQUESTED_RELEASE="${1#*=}"
      [ -n "$REQUESTED_RELEASE" ] || die "--release cannot be empty"
      shift
      ;;
    --root)
      require_value "$1" "${2:-}"
      TARGET_ROOT="$2"
      shift 2
      ;;
    --root=*)
      TARGET_ROOT="${1#*=}"
      [ -n "$TARGET_ROOT" ] || die "--root cannot be empty"
      shift
      ;;
    --windows-se-init)
      WINDOWS_SE_INIT="true"
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

[ -n "$MODULES_DIR" ] || {
  usage >&2
  exit 2
}

for tool in modinfo depmod install realpath sha256sum cmp mktemp grep awk find od tr; do
  command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done

if [ "$(id -u)" -ne 0 ]; then
  die "installation mutates the target system and must be run as root"
fi

MODULES_DIR="$(realpath -e -- "$MODULES_DIR")" || die "cannot resolve --modules-dir"
[ -d "$MODULES_DIR" ] || die "not a directory: $MODULES_DIR"
TARGET_ROOT="$(realpath -e -- "$TARGET_ROOT")" || die "cannot resolve --root"
[ -d "$TARGET_ROOT" ] || die "not a directory: $TARGET_ROOT"

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
module_sources=()
COMMON_RELEASE=""

for index in "${!module_files[@]}"; do
  source_path="$MODULES_DIR/${module_files[index]}"
  [ -f "$source_path" ] || die "required module is missing: $source_path"

  actual_name="$(modinfo -F name "$source_path" 2>/dev/null || true)"
  [ "$actual_name" = "${module_names[index]}" ] ||
    die "${module_files[index]} has module name '${actual_name:-unknown}', expected '${module_names[index]}'"

  vermagic="$(modinfo -F vermagic "$source_path" 2>/dev/null || true)"
  module_release="${vermagic%%[[:space:]]*}"
  [ -n "$module_release" ] || die "cannot read vermagic from $source_path"

  if [ -z "$COMMON_RELEASE" ]; then
    COMMON_RELEASE="$module_release"
  elif [ "$module_release" != "$COMMON_RELEASE" ]; then
    die "module vermagic releases differ: $COMMON_RELEASE and $module_release"
  fi
  module_sources+=("$source_path")
done

case "$COMMON_RELEASE" in
  ""|*[!A-Za-z0-9._+~-]*|[!A-Za-z0-9]*)
    die "unsafe kernel release inferred from vermagic: '$COMMON_RELEASE'"
    ;;
esac

if [ -n "$REQUESTED_RELEASE" ] && [ "$REQUESTED_RELEASE" != "$COMMON_RELEASE" ]; then
  die "--release '$REQUESTED_RELEASE' does not match module vermagic '$COMMON_RELEASE'"
fi
RELEASE="$COMMON_RELEASE"

case "$RELEASE" in
  *sp11v3*-qcom-x1e) ;;
  *) die "$RELEASE is not an sp11v3 touchscreen kernel ABI" ;;
esac

if ! modinfo -p "${module_sources[1]}" 2>/dev/null |
  grep -q '^sp11_windows_se_init:'; then
  die "spi-geni-qcom.ko lacks sp11_windows_se_init; this is not the required SP11 override"
fi
if ! modinfo -F alias "${module_sources[2]}" 2>/dev/null |
  grep -q 'microsoft,mshw0485'; then
  die "mshw0485_touch.ko lacks the microsoft,mshw0485 device-tree alias"
fi
for index in "${!module_files[@]}"; do
  srcversion="$(modinfo -F srcversion "${module_sources[index]}" 2>/dev/null || true)"
  [ -n "$srcversion" ] || die "${module_files[index]} has no source-version identity"
done

MODULE_TREE="$(root_path "/lib/modules/$RELEASE")"
[ -d "$MODULE_TREE" ] || die "target kernel module tree does not exist: $MODULE_TREE"
[ -d "$(root_path /etc)" ] || die "target root lacks /etc: $TARGET_ROOT"
[ -d "$(root_path /boot)" ] || die "target root lacks /boot: $TARGET_ROOT"

config=""
for candidate in \
  "$(root_path "/lib/modules/$RELEASE/build/.config")" \
  "$(root_path "/boot/config-$RELEASE")"; do
  if [ -r "$candidate" ]; then
    config="$candidate"
    break
  fi
done
[ -n "$config" ] || die "cannot find the exact target kernel configuration for $RELEASE"
grep -qx 'CONFIG_MODULES=y' "$config" || die "CONFIG_MODULES is not enabled for $RELEASE"
grep -qx 'CONFIG_QCOM_GPI_DMA=m' "$config" || die "CONFIG_QCOM_GPI_DMA must be a replaceable module"
grep -qx 'CONFIG_SPI_QCOM_GENI=m' "$config" || die "CONFIG_SPI_QCOM_GENI must be a replaceable module"
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$config"; then
  die "CONFIG_MODULE_SIG_FORCE rejects the unsigned touchscreen modules"
fi

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "touchscreen installation must run on an ARM64 system" ;;
esac

compatible="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
case " $compatible " in
  *" microsoft,denali-oled "*) ;;
  *) die "running hardware is not the supported Surface Pro 11 OLED (microsoft,denali-oled)" ;;
esac

secure_boot_enabled="false"
if command -v mokutil >/dev/null 2>&1 &&
  mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
  secure_boot_enabled="true"
else
  for variable in /sys/firmware/efi/efivars/SecureBoot-*; do
    [ -r "$variable" ] || continue
    byte="$(od -An -t u1 -j 4 -N 1 "$variable" 2>/dev/null | tr -d ' ')"
    [ "$byte" = 1 ] && secure_boot_enabled="true"
  done
fi
[ "$secure_boot_enabled" != "true" ] || die "Secure Boot is enabled; these experimental modules are unsigned"

touch_dtb=""
for candidate in \
  "$(root_path "/lib/firmware/$RELEASE/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb")" \
  "$(root_path "/usr/lib/linux-image-$RELEASE/qcom/x1e80100-microsoft-denali-oled.dtb")" \
  "$(root_path "/boot/dtbs/$RELEASE/qcom/x1e80100-microsoft-denali-oled.dtb")"; do
  if [ -f "$candidate" ] && grep -a -q 'microsoft,mshw0485' "$candidate"; then
    touch_dtb="$candidate"
    break
  fi
done
[ -n "$touch_dtb" ] || die "the target ABI has no Denali OLED DTB with microsoft,mshw0485"

firmware_found="false"
for candidate in \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.zst \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.xz \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf; do
  [ -f "$(root_path "$candidate")" ] && firmware_found="true"
done
[ "$firmware_found" = "true" ] || die "target root lacks qcom/x1e80100/qupv3fw.elf firmware"

REFRESH_TOOL=""
REFRESH_COMMAND=""
if [ "$TARGET_ROOT" = "/" ]; then
  if command -v update-initramfs >/dev/null 2>&1; then
    REFRESH_TOOL="update-initramfs"
    REFRESH_COMMAND="$(command -v update-initramfs)"
  elif command -v dracut >/dev/null 2>&1; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="$(command -v dracut)"
  else
    die "neither update-initramfs nor dracut is installed"
  fi
else
  command -v chroot >/dev/null 2>&1 || die "--root requires chroot"
  [ -x "$(root_path /bin/sh)" ] || die "target root has no executable /bin/sh"
  if ! chroot "$TARGET_ROOT" /bin/sh -c ':' >/dev/null 2>&1; then
    die "target root is not runnable with chroot; refusing a partial offline install"
  fi
  if [ -x "$(root_path /usr/sbin/update-initramfs)" ]; then
    REFRESH_TOOL="update-initramfs"
    REFRESH_COMMAND="/usr/sbin/update-initramfs"
  elif [ -x "$(root_path /usr/bin/dracut)" ]; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="/usr/bin/dracut"
  elif [ -x "$(root_path /usr/sbin/dracut)" ]; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="/usr/sbin/dracut"
  else
    die "target root contains neither update-initramfs nor dracut"
  fi
fi

if command -v lsinitramfs >/dev/null 2>&1; then
  INITRD_INSPECTOR="lsinitramfs"
elif command -v lsinitrd >/dev/null 2>&1; then
  INITRD_INSPECTOR="lsinitrd"
else
  die "post-install verification requires lsinitramfs or lsinitrd"
fi
if command -v unmkinitramfs >/dev/null 2>&1; then
  INITRD_EXTRACTOR="unmkinitramfs"
elif command -v lsinitrd >/dev/null 2>&1; then
  INITRD_EXTRACTOR="lsinitrd"
else
  die "exact initramfs module verification requires unmkinitramfs or lsinitrd"
fi

if [ "$WINDOWS_SE_INIT" = "true" ]; then
  warn "--windows-se-init enables an experimental captured Windows cold-init path"
  warn "the validated Phase 91 Linux-integrated profile uses sp11_windows_se_init=0"
  SE_INIT_VALUE=1
  PROFILE="windows-cold-init-opt-in"
else
  SE_INIT_VALUE=0
  PROFILE="linux-integrated"
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

cat > "$work_dir/sp11-touchscreen.modprobe" <<EOF
# Generated by $PROGRAM for $RELEASE.
# Keep the validated Linux-integrated controller path unless explicitly testing
# the captured Windows cold-init fallback.
softdep spi_geni_qcom pre: gpi
softdep mshw0485_touch pre: spi_geni_qcom
options spi_geni_qcom sp11_windows_se_init=$SE_INIT_VALUE
EOF

cat > "$work_dir/sp11-touchscreen.modules-load" <<'EOF'
# Surface Pro 11 touchscreen transport order.
gpi
spi_geni_qcom
mshw0485_touch
EOF

cat > "$work_dir/sp11-touchscreen.initramfs-hook" <<'EOF'
#!/bin/sh
set -eu

PREREQ=""
prereqs() { printf '%s\n' "$PREREQ"; }

case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

release="${version:-}"
[ -n "$release" ] || {
  echo "sp11-touchscreen hook: initramfs kernel version is unavailable" >&2
  exit 1
}

marker="/etc/sp11-touchscreen/releases/$release"
[ -f "$marker" ] || exit 0

for relative in \
  updates/drivers/dma/qcom/gpi.ko \
  updates/drivers/spi/spi-geni-qcom.ko \
  updates/drivers/input/touchscreen/mshw0485_touch.ko; do
  source_path="/lib/modules/$release/$relative"
  if [ ! -f "$source_path" ]; then
    echo "sp11-touchscreen hook: required override missing: $source_path" >&2
    exit 1
  fi
  copy_file module "$source_path" "$source_path" || {
    result=$?
    [ "$result" -eq 1 ] || exit "$result"
  }
done

manual_add_modules gpi spi_geni_qcom mshw0485_touch
EOF

cat > "$work_dir/sp11-touchscreen.dracut" <<'EOF'
# Surface Pro 11 QSPI touchscreen transport and client. depmod selects the
# exact updates/ overrides installed for the initramfs kernel release.
force_drivers+=" gpi spi_geni_qcom mshw0485_touch "
EOF

{
  printf 'release=%s\n' "$RELEASE"
  printf 'profile=%s\n' "$PROFILE"
  for index in "${!module_files[@]}"; do
    checksum="$(sha256sum "${module_sources[index]}" | awk '{print $1}')"
    printf '%s_sha256=%s\n' "${module_names[index]}" "$checksum"
  done
} > "$work_dir/release-marker"

echo "Installing Surface Pro 11 touchscreen support for exact ABI: $RELEASE"
for index in "${!module_files[@]}"; do
  destination="$MODULE_TREE/${module_relpaths[index]}"
  install -d -m 0755 "$(dirname "$destination")"
  install -m 0644 "${module_sources[index]}" "$destination"
done

install -d -m 0755 \
  "$(root_path /etc/modprobe.d)" \
  "$(root_path /etc/modules-load.d)" \
  "$(root_path /etc/initramfs-tools/hooks)" \
  "$(root_path /etc/dracut.conf.d)" \
  "$(root_path /etc/sp11-touchscreen/releases)"
install -m 0644 "$work_dir/sp11-touchscreen.modprobe" \
  "$(root_path /etc/modprobe.d/sp11-touchscreen.conf)"
install -m 0644 "$work_dir/sp11-touchscreen.modules-load" \
  "$(root_path /etc/modules-load.d/sp11-touchscreen.conf)"
install -m 0755 "$work_dir/sp11-touchscreen.initramfs-hook" \
  "$(root_path /etc/initramfs-tools/hooks/sp11-touchscreen)"
install -m 0644 "$work_dir/sp11-touchscreen.dracut" \
  "$(root_path /etc/dracut.conf.d/91-sp11-touchscreen.conf)"
install -m 0644 "$work_dir/release-marker" \
  "$(root_path "/etc/sp11-touchscreen/releases/$RELEASE")"

depmod -b "$TARGET_ROOT" -a "$RELEASE"

for index in "${!module_files[@]}"; do
  selected="$(modinfo -b "$TARGET_ROOT" -k "$RELEASE" -n "${module_names[index]}" 2>/dev/null || true)"
  expected_suffix="/lib/modules/$RELEASE/${module_relpaths[index]}"
  case "$selected" in
    *"$expected_suffix"|*"/usr$expected_suffix") ;;
    *) die "depmod selects '${selected:-nothing}' for ${module_names[index]}, expected updates/${module_relpaths[index]#updates/}" ;;
  esac
  cmp -s "${module_sources[index]}" "$MODULE_TREE/${module_relpaths[index]}" ||
    die "installed module differs from source: ${module_files[index]}"
  echo "Verified disk selection: ${module_names[index]} -> $selected"
done

INITRD="$(root_path "/boot/initrd.img-$RELEASE")"
if [ "$REFRESH_TOOL" = "update-initramfs" ]; then
  if [ -e "$INITRD" ]; then
    action=-u
  else
    action=-c
  fi
  if [ "$TARGET_ROOT" = "/" ]; then
    "$REFRESH_COMMAND" "$action" -k "$RELEASE"
  else
    chroot "$TARGET_ROOT" "$REFRESH_COMMAND" "$action" -k "$RELEASE"
  fi
else
  if [ "$TARGET_ROOT" = "/" ]; then
    "$REFRESH_COMMAND" --force "/boot/initrd.img-$RELEASE" "$RELEASE"
  else
    chroot "$TARGET_ROOT" "$REFRESH_COMMAND" --force "/boot/initrd.img-$RELEASE" "$RELEASE"
  fi
fi

[ -s "$INITRD" ] || die "initramfs was not created or updated: $INITRD"
initrd_listing="$work_dir/initrd.list"
if [ "$INITRD_INSPECTOR" = "lsinitramfs" ]; then
  lsinitramfs "$INITRD" > "$initrd_listing" || die "lsinitramfs could not inspect $INITRD"
else
  lsinitrd "$INITRD" > "$initrd_listing" || die "lsinitrd could not inspect $INITRD"
fi

for relative in "${module_relpaths[@]}"; do
  initrd_path="lib/modules/$RELEASE/$relative"
  if ! grep -Fq "$initrd_path" "$initrd_listing" &&
     ! grep -Fq "usr/$initrd_path" "$initrd_listing"; then
    die "initramfs does not contain exact override path: $initrd_path"
  fi
  echo "Verified initramfs path: $initrd_path"
done

initrd_extract="$work_dir/initrd-extracted"
mkdir -p "$initrd_extract"
if [ "$INITRD_EXTRACTOR" = "unmkinitramfs" ]; then
  unmkinitramfs "$INITRD" "$initrd_extract" || die "unmkinitramfs could not extract $INITRD"
else
  (
    cd "$initrd_extract"
    lsinitrd --unpack "$INITRD"
  ) || die "lsinitrd could not extract $INITRD"
fi

for index in "${!module_files[@]}"; do
  expected_relative="lib/modules/$RELEASE/${module_relpaths[index]}"
  embedded="$(
    find "$initrd_extract" -type f \
      \( -path "*/$expected_relative" -o -path "*/usr/$expected_relative" \
         -o -path "*/$expected_relative.*" -o -path "*/usr/$expected_relative.*" \) \
      -print -quit
  )"
  [ -n "$embedded" ] || die "cannot locate extracted initramfs override for ${module_files[index]}"
  source_srcversion="$(modinfo -F srcversion "${module_sources[index]}")"
  embedded_srcversion="$(modinfo -F srcversion "$embedded" 2>/dev/null || true)"
  [ "$embedded_srcversion" = "$source_srcversion" ] ||
    die "initramfs ${module_files[index]} srcversion ${embedded_srcversion:-unknown} differs from $source_srcversion"

  unexpected="$(
    find "$initrd_extract" -type f -name "${module_files[index]}*" \
      ! -path "*/${module_relpaths[index]}" \
      ! -path "*/${module_relpaths[index]}.*" -print -quit
  )"
  [ -z "$unexpected" ] || die "initramfs also contains a stock/duplicate ${module_files[index]}: $unexpected"
  echo "Verified initramfs srcversion: ${module_names[index]} -> $embedded_srcversion"
done

echo
echo "Surface Pro 11 touchscreen modules installed successfully."
echo "Profile: $PROFILE (sp11_windows_se_init=$SE_INIT_VALUE)"
if [ "$TARGET_ROOT" = "/" ] && [ "$(uname -r)" = "$RELEASE" ]; then
  echo "Reboot is required; the currently loaded modules were not replaced in memory."
else
  echo "Boot the exact kernel release '$RELEASE' to activate the installed stack."
fi
