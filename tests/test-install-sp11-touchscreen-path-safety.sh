#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$repo_dir/scripts/install-sp11-touchscreen.sh"
test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
mock_bin="$test_root/mock-bin"
private_tmp="$test_root/private-tmp"
command_log="$test_root/commands.log"
depmod_snapshot_fingerprint="$test_root/depmod-snapshot.fingerprint"
initrd_snapshot_fingerprint="$test_root/initrd-snapshot.fingerprint"
release="7.2-rc5-jg-0sp11v3-test-qcom-x1e"
real_ln="$(command -v ln)"
case_output=""
case_status=0

cleanup_test() {
  case "${test_root:-}" in
    /|"") ;;
    *)
      chmod -R u+w "$test_root" 2>/dev/null || true
      rm -rf -- "$test_root"
      ;;
  esac
}
trap cleanup_test EXIT HUP INT TERM

mkdir -p "$mock_bin" "$private_tmp"
: > "$command_log"

cat > "$mock_bin/id" <<'EOF_ID'
#!/bin/sh
[ "${1:-}" = "-u" ] || exit 90
printf '%s\n' 0
EOF_ID

cat > "$mock_bin/uname" <<'EOF_UNAME'
#!/bin/sh
case "${1:-}" in
  -m) printf '%s\n' aarch64 ;;
  -r) printf '%s\n' fixture-running-kernel ;;
  *) printf '%s\n' Linux ;;
esac
EOF_UNAME

cat > "$mock_bin/realpath" <<'EOF_REALPATH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e|--) shift ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || exit 91
if [ -x /usr/bin/realpath ] && /usr/bin/realpath -e -- "$1" >/dev/null 2>&1; then
  exec /usr/bin/realpath -e -- "$1"
fi
python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
if not os.path.exists(path):
    raise SystemExit(1)
print(path)
PY
EOF_REALPATH

cat > "$mock_bin/sha256sum" <<'EOF_SHA'
#!/bin/sh
if [ -x /usr/bin/sha256sum ]; then
  exec /usr/bin/sha256sum "$@"
fi
exec shasum -a 256 "$@"
EOF_SHA

cat > "$mock_bin/modinfo" <<'EOF_MODINFO'
#!/bin/sh
field=""
path=""
root=""
release="${MOCK_RELEASE:?}"
lookup_name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -F) field="$2"; shift 2 ;;
    -p) field="parameters"; path="$2"; shift 2 ;;
    -b) root="$2"; shift 2 ;;
    -k) release="$2"; shift 2 ;;
    -n) field="filename"; lookup_name="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done

if [ "$field" = "filename" ]; then
  if [ -n "${MOCK_MODINFO_REPLACE_PATH:-}" ] &&
     [ ! -e "${MOCK_MODINFO_REPLACE_MARKER:?}" ]; then
    temporary="$(mktemp "$(dirname "$MOCK_MODINFO_REPLACE_PATH")/.regular-occupant.XXXXXX")"
    printf '%s\n' "${MOCK_MODINFO_REPLACE_CONTENT:?}" > "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$MOCK_MODINFO_REPLACE_PATH"
    : > "$MOCK_MODINFO_REPLACE_MARKER"
    [ "${MOCK_MODINFO_FAIL_AFTER_REPLACE:-false}" != "true" ] || exit 0
  fi
  case "$lookup_name" in
    gpi) relative='updates/drivers/dma/qcom/gpi.ko' ;;
    spi_geni_qcom) relative='updates/drivers/spi/spi-geni-qcom.ko' ;;
    mshw0485_touch) relative='updates/drivers/input/touchscreen/mshw0485_touch.ko' ;;
    *) exit 92 ;;
  esac
  printf '%s/lib/modules/%s/%s\n' "${root%/}" "$release" "$relative"
  exit 0
fi

name="${path##*/}"
case "$name" in
  gpi.ko*) module_name=gpi; srcversion=GPI123 ;;
  spi-geni-qcom.ko*) module_name=spi_geni_qcom; srcversion=SPI123 ;;
  mshw0485_touch.ko*) module_name=mshw0485_touch; srcversion=TOUCH123 ;;
  *) exit 93 ;;
esac

case "$field" in
  name) printf '%s\n' "$module_name" ;;
  vermagic) printf '%s SMP preempt mod_unload aarch64\n' "$release" ;;
  srcversion) printf '%s\n' "$srcversion" ;;
  parameters)
    [ "$module_name" = spi_geni_qcom ] &&
      printf '%s\n' 'sp11_windows_se_init:experimental controller sequence (bool)'
    ;;
  alias)
    [ "$module_name" = mshw0485_touch ] &&
      printf '%s\n' 'of:N*T*Cmicrosoft,mshw0485'
    ;;
  *) exit 94 ;;
esac
EOF_MODINFO

cat > "$mock_bin/depmod" <<'EOF_DEPMOD'
#!/bin/sh
fingerprint() {
  if metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' -- "$1" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$1")"
  fi
  checksum="$(cksum "$1" | awk '{print $1 ":" $2}')"
  printf '%s:%s\n' "$metadata" "$checksum"
}

root=""
release="${MOCK_RELEASE:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b) root="$2"; shift 2 ;;
    -a) shift ;;
    *) release="$1"; shift ;;
  esac
done
tree="${root%/}/lib/modules/$release"
if [ -n "${MOCK_DEPMOD_SNAPSHOT_FINGERPRINT_FILE:-}" ]; then
  backup="$(find "$tree" -mindepth 2 -maxdepth 2 \
    -path '*/.sp11-touchscreen-depmod-backup.*/modules.dep' -print -quit)"
  [ -n "$backup" ] || exit 95
  fingerprint "$backup" > "$MOCK_DEPMOD_SNAPSHOT_FINGERPRINT_FILE"
fi
printf 'new depmod metadata\n' > "$tree/modules.dep"
printf 'new alias metadata\n' > "$tree/modules.alias"
printf 'new symbol metadata\n' > "$tree/modules.symbols"
printf 'depmod %s %s\n' "$root" "$release" >> "${MOCK_COMMAND_LOG:?}"
if [ -n "${MOCK_DEPMOD_OCCUPY_NAME:-}" ]; then
  occupied="$tree/$MOCK_DEPMOD_OCCUPY_NAME"
  rm -f -- "$occupied"
  mkdir "$occupied"
  printf 'unexpected depmod directory occupant\n' > "$occupied/occupant"
  exit 81
fi
[ "${MOCK_DEPMOD_FAIL:-false}" != "true" ] || exit 81
EOF_DEPMOD

cat > "$mock_bin/chroot" <<'EOF_CHROOT'
#!/bin/sh
fingerprint() {
  if metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' -- "$1" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$1")"
  fi
  checksum="$(cksum "$1" | awk '{print $1 ":" $2}')"
  printf '%s:%s\n' "$metadata" "$checksum"
}

root="$1"
shift
printf 'chroot %s %s\n' "$root" "$*" >> "${MOCK_COMMAND_LOG:?}"
if [ "${1:-}" = "/bin/sh" ]; then
  exit 0
fi
release="${MOCK_RELEASE:?}"
previous=""
for argument in "$@"; do
  if [ "$previous" = "-k" ]; then
    release="$argument"
  fi
  previous="$argument"
done
if [ -n "${MOCK_INITRD_SNAPSHOT_FINGERPRINT_FILE:-}" ]; then
  backup="$(find "$root/boot" -mindepth 2 -maxdepth 2 \
    -path '*/.sp11-touchscreen-initrd-backup.*/original' -print -quit)"
  [ -n "$backup" ] || exit 96
  fingerprint "$backup" > "$MOCK_INITRD_SNAPSHOT_FINGERPRINT_FILE"
fi
printf 'new initramfs bytes\n' > "$root/boot/initrd.img-$release"
if [ "${MOCK_INITRAMFS_OCCUPY:-false}" = "true" ]; then
  rm -f -- "$root/boot/initrd.img-$release"
  mkdir "$root/boot/initrd.img-$release"
  printf 'unexpected initramfs directory occupant\n' > \
    "$root/boot/initrd.img-$release/occupant"
  exit 82
fi
[ "${MOCK_INITRAMFS_FAIL:-false}" != "true" ] || exit 82
EOF_CHROOT

cat > "$mock_bin/lsinitramfs" <<'EOF_LSINITRAMFS'
#!/bin/sh
release="${MOCK_RELEASE:?}"
if [ -n "${MOCK_LSINITRAMFS_REPLACE_PATH:-}" ] &&
   [ ! -e "${MOCK_LSINITRAMFS_REPLACE_MARKER:?}" ]; then
  temporary="$(mktemp "$(dirname "$MOCK_LSINITRAMFS_REPLACE_PATH")/.regular-occupant.XXXXXX")"
  printf '%s\n' "${MOCK_LSINITRAMFS_REPLACE_CONTENT:?}" > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$MOCK_LSINITRAMFS_REPLACE_PATH"
  : > "$MOCK_LSINITRAMFS_REPLACE_MARKER"
  exit 84
fi
printf '%s\n' \
  "lib/modules/$release/updates/drivers/dma/qcom/gpi.ko" \
  "lib/modules/$release/updates/drivers/spi/spi-geni-qcom.ko" \
  "lib/modules/$release/updates/drivers/input/touchscreen/mshw0485_touch.ko"
EOF_LSINITRAMFS

cat > "$mock_bin/unmkinitramfs" <<'EOF_UNMKINITRAMFS'
#!/bin/sh
destination="$2"
release="${MOCK_RELEASE:?}"
mkdir -p \
  "$destination/main/lib/modules/$release/updates/drivers/dma/qcom" \
  "$destination/main/lib/modules/$release/updates/drivers/spi" \
  "$destination/main/lib/modules/$release/updates/drivers/input/touchscreen"
printf 'embedded gpi\n' > \
  "$destination/main/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko"
printf 'embedded spi\n' > \
  "$destination/main/lib/modules/$release/updates/drivers/spi/spi-geni-qcom.ko"
printf 'embedded touch\n' > \
  "$destination/main/lib/modules/$release/updates/drivers/input/touchscreen/mshw0485_touch.ko"
EOF_UNMKINITRAMFS

cat > "$mock_bin/ln" <<'EOF_LN'
#!/bin/sh
last=""
for argument in "$@"; do
  last="$argument"
done
if [ -n "${MOCK_LN_FAIL_DESTINATION:-}" ] &&
   [ "$last" = "$MOCK_LN_FAIL_DESTINATION" ]; then
  printf 'forced ln failure %s\n' "$last" >> "${MOCK_COMMAND_LOG:?}"
  exit 83
fi
if [ -n "${MOCK_LN_OCCUPY_DESTINATION:-}" ] &&
   [ "$last" = "$MOCK_LN_OCCUPY_DESTINATION" ]; then
  "${REAL_LN:?}" -s "${MOCK_LN_OCCUPY_VICTIM:?}" "$last"
  exit 83
fi
if [ -n "${MOCK_LN_REPLACE_TRIGGER_DESTINATION:-}" ] &&
   [ "$last" = "$MOCK_LN_REPLACE_TRIGGER_DESTINATION" ]; then
  temporary="$(mktemp "$(dirname "${MOCK_LN_REPLACE_EARLIER_DESTINATION:?}")/.regular-occupant.XXXXXX")"
  printf '%s\n' "${MOCK_LN_REPLACE_CONTENT:?}" > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$MOCK_LN_REPLACE_EARLIER_DESTINATION"
  exit 83
fi
exec "${REAL_LN:?}" "$@"
EOF_LN

chmod +x "$mock_bin"/*

export MOCK_RELEASE="$release"
export MOCK_COMMAND_LOG="$command_log"
export REAL_LN="$real_ln"
export MOCK_DEPMOD_SNAPSHOT_FINGERPRINT_FILE="$depmod_snapshot_fingerprint"
export MOCK_INITRD_SNAPSHOT_FINGERPRINT_FILE="$initrd_snapshot_fingerprint"

fail() {
  echo "Error: $*" >&2
  if [ -n "$case_output" ]; then
    printf '%s\n' "$case_output" >&2
  fi
  exit 1
}

file_mode() {
  local mode
  if mode="$(stat -c '%a' -- "$1" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -f '%Lp' "$1"
  fi
}

file_fingerprint() {
  local path="$1" metadata
  if metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$path")"
  fi
  printf '%s:%s\n' "$metadata" "$(cksum "$path")"
}

exact_file_fingerprint() {
  local path="$1" metadata checksum
  if metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$path")"
  fi
  checksum="$(cksum "$path" | awk '{print $1 ":" $2}')"
  printf '%s:%s\n' "$metadata" "$checksum"
}

content_metadata_fingerprint() {
  local path="$1" metadata
  if metadata="$(stat -c '%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  else
    metadata="$(stat -f '%Lp:%u:%g:%z:%m' "$path")"
  fi
  printf '%s:%s\n' "$metadata" "$(cksum "$path")"
}

node_fingerprint() {
  local path="$1"
  if stat -c '%F:%d:%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null; then
    :
  else
    stat -f '%HT:%d:%i:%Lp:%u:%g:%z:%m' "$path"
  fi
}

create_module_input() {
  local directory="$1"
  mkdir -p "$directory"
  printf 'fixture gpi module\n' > "$directory/gpi.ko"
  printf 'fixture spi module\n' > "$directory/spi-geni-qcom.ko"
  printf 'fixture touch module\n' > "$directory/mshw0485_touch.ko"
  printf 'fixture manifest\n' > "$directory/sp11-touchscreen-modules-manifest.txt"
  chmod 0400 "$directory"/*.ko "$directory/sp11-touchscreen-modules-manifest.txt"
  chmod 0500 "$directory"
}

seed_target_root() {
  local root="$1" usrmerge="${2:-false}" module_tree

  mkdir -p \
    "$root/etc" \
    "$root/boot" \
    "$root/bin" \
    "$root/usr/sbin" \
    "$root/proc/device-tree"
  if [ "$usrmerge" = "true" ]; then
    mkdir -p "$root/usr/lib"
    ln -s usr/lib "$root/lib"
  else
    mkdir -p "$root/lib"
  fi
  module_tree="$root/lib/modules/$release"
  mkdir -p \
    "$module_tree" \
    "$root/lib/firmware/$release/device-tree/qcom" \
    "$root/lib/firmware/qcom/x1e80100"
  printf '%s\n' \
    'CONFIG_MODULES=y' \
    'CONFIG_QCOM_GPI_DMA=m' \
    'CONFIG_SPI_QCOM_GENI=m' > "$root/boot/config-$release"
  printf 'microsoft,denali-oled\0' > "$root/proc/device-tree/compatible"
  printf 'fixture microsoft,mshw0485 dtb\n' > \
    "$root/lib/firmware/$release/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb"
  printf 'fixture QUP firmware\n' > "$root/lib/firmware/qcom/x1e80100/qupv3fw.elf"
  printf '#!/bin/sh\nexit 0\n' > "$root/bin/sh"
  printf '#!/bin/sh\nexit 0\n' > "$root/usr/sbin/update-initramfs"
  chmod 0755 "$root/bin/sh" "$root/usr/sbin/update-initramfs"
  printf 'old modules.dep bytes\n' > "$module_tree/modules.dep"
  printf 'old modules.alias bytes\n' > "$module_tree/modules.alias"
  chmod 0640 "$module_tree/modules.dep" "$module_tree/modules.alias"
  printf 'old initramfs bytes\n' > "$root/boot/initrd.img-$release"
  chmod 0640 "$root/boot/initrd.img-$release"
}

managed_paths() {
  local root="$1"
  printf '%s\n' \
    "$root/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko" \
    "$root/lib/modules/$release/updates/drivers/spi/spi-geni-qcom.ko" \
    "$root/lib/modules/$release/updates/drivers/input/touchscreen/mshw0485_touch.ko" \
    "$root/etc/modprobe.d/sp11-touchscreen.conf" \
    "$root/etc/modules-load.d/sp11-touchscreen.conf" \
    "$root/etc/initramfs-tools/hooks/sp11-touchscreen" \
    "$root/etc/dracut.conf.d/91-sp11-touchscreen.conf" \
    "$root/etc/sp11-touchscreen/releases/$release"
}

seed_managed_files() {
  local root="$1" path index=0

  while IFS= read -r path; do
    mkdir -p "$(dirname "$path")"
    printf 'old managed bytes %s\n' "$index" > "$path"
    chmod 0640 "$path"
    index=$((index + 1))
  done < <(managed_paths "$root")
}

managed_state() {
  local root="$1" path

  while IFS= read -r path; do
    printf '%s:%s\n' "$path" "$(file_fingerprint "$path")"
  done < <(managed_paths "$root")
  printf '%s:%s\n' \
    "$root/lib/modules/$release/modules.dep" \
    "$(content_metadata_fingerprint "$root/lib/modules/$release/modules.dep")"
  printf '%s:%s\n' \
    "$root/lib/modules/$release/modules.alias" \
    "$(content_metadata_fingerprint "$root/lib/modules/$release/modules.alias")"
  printf '%s:%s\n' \
    "$root/boot/initrd.img-$release" \
    "$(content_metadata_fingerprint "$root/boot/initrd.img-$release")"
}

direct_state_excluding() {
  local root="$1" excluded="${2:-}" path

  while IFS= read -r path; do
    [ "$path" = "$excluded" ] && continue
    printf '%s:%s\n' "$path" "$(file_fingerprint "$path")"
  done < <(managed_paths "$root")
}

find_single_backup() {
  local root="$1" pattern="$2" paths count

  paths="$(find "$root" -type d -name "$pattern" -print)"
  count="$(printf '%s\n' "$paths" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -eq 1 ] || fail "expected one $pattern backup below $root, found $count"
  printf '%s\n' "$paths"
}

assert_no_private_artifacts() {
  local root="$1"
  if find "$root" \
    \( -name '.sp11-touchscreen-stage.*' \
       -o -name '.sp11-touchscreen-backup.*' \
       -o -name '.sp11-touchscreen-depmod-backup.*' \
       -o -name '.sp11-touchscreen-initrd-backup.*' \
       -o -name '.sp11-touchscreen-restore.*' \) \
    -print | grep -q .; then
    fail "installer left a private transaction artifact below $root"
  fi
  if find "$private_tmp" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    fail "installer left its private work directory behind"
  fi
}

run_case() {
  local root="$1" modules="$2"
  shift 2
  : > "$command_log"
  if case_output="$(
    PATH="$mock_bin:/opt/homebrew/bin:/usr/bin:/bin" \
    TMPDIR="$private_tmp" \
    MOCK_DEPMOD_FAIL="${MOCK_DEPMOD_FAIL:-false}" \
    MOCK_DEPMOD_OCCUPY_NAME="${MOCK_DEPMOD_OCCUPY_NAME:-}" \
    MOCK_INITRAMFS_FAIL="${MOCK_INITRAMFS_FAIL:-false}" \
    MOCK_INITRAMFS_OCCUPY="${MOCK_INITRAMFS_OCCUPY:-false}" \
    MOCK_LN_FAIL_DESTINATION="${MOCK_LN_FAIL_DESTINATION:-}" \
    MOCK_LN_OCCUPY_DESTINATION="${MOCK_LN_OCCUPY_DESTINATION:-}" \
    MOCK_LN_OCCUPY_VICTIM="${MOCK_LN_OCCUPY_VICTIM:-}" \
    MOCK_LN_REPLACE_TRIGGER_DESTINATION="${MOCK_LN_REPLACE_TRIGGER_DESTINATION:-}" \
    MOCK_LN_REPLACE_EARLIER_DESTINATION="${MOCK_LN_REPLACE_EARLIER_DESTINATION:-}" \
    MOCK_LN_REPLACE_CONTENT="${MOCK_LN_REPLACE_CONTENT:-}" \
    MOCK_MODINFO_REPLACE_PATH="${MOCK_MODINFO_REPLACE_PATH:-}" \
    MOCK_MODINFO_REPLACE_CONTENT="${MOCK_MODINFO_REPLACE_CONTENT:-}" \
    MOCK_MODINFO_REPLACE_MARKER="${MOCK_MODINFO_REPLACE_MARKER:-$test_root/modinfo-replace.marker}" \
    MOCK_MODINFO_FAIL_AFTER_REPLACE="${MOCK_MODINFO_FAIL_AFTER_REPLACE:-false}" \
    MOCK_LSINITRAMFS_REPLACE_PATH="${MOCK_LSINITRAMFS_REPLACE_PATH:-}" \
    MOCK_LSINITRAMFS_REPLACE_CONTENT="${MOCK_LSINITRAMFS_REPLACE_CONTENT:-}" \
    MOCK_LSINITRAMFS_REPLACE_MARKER="${MOCK_LSINITRAMFS_REPLACE_MARKER:-$test_root/lsinitramfs-replace.marker}" \
    MOCK_DEPMOD_SNAPSHOT_FINGERPRINT_FILE="$depmod_snapshot_fingerprint" \
    MOCK_INITRD_SNAPSHOT_FINGERPRINT_FILE="$initrd_snapshot_fingerprint" \
      "$installer" \
        --modules-dir "$modules" \
        --release "$release" \
        --root "$root" "$@" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

expect_failure() {
  [ "$case_status" -ne 0 ] || fail "unsafe installer case unexpectedly succeeded"
}

assert_output_contains() {
  case "$case_output" in
    *"$1"*) ;;
    *) fail "installer output did not contain: $1" ;;
  esac
}

modules="$test_root/private-builder-snapshot"
create_module_input "$modules"

# A symlinked module-input directory must be rejected without reading through
# the alias or changing its physical source directory.
module_link="$test_root/module-input-link"
module_victim_before="$(file_fingerprint "$modules/gpi.ko")"
ln -s "$modules" "$module_link"
input_link_root="$test_root/input-link-root"
seed_target_root "$input_link_root"
seed_managed_files "$input_link_root"
input_link_state="$(managed_state "$input_link_root")"
run_case "$input_link_root" "$module_link"
expect_failure
assert_output_contains 'module input directory must not be a symlink'
[ "$(file_fingerprint "$modules/gpi.ko")" = "$module_victim_before" ] ||
  fail "symlinked input changed its module victim"
[ "$(managed_state "$input_link_root")" = "$input_link_state" ] ||
  fail "symlinked input changed the target before rejection"

# The root itself must be named by its canonical physical path. A symlink alias
# is rejected before the physical target receives any mutation.
root_link_victim="$test_root/root-link-victim"
root_link="$test_root/root-link"
seed_target_root "$root_link_victim"
seed_managed_files "$root_link_victim"
root_link_before="$(managed_state "$root_link_victim")"
ln -s "$root_link_victim" "$root_link"
run_case "$root_link" "$modules"
expect_failure
assert_output_contains 'target root must not be a symlink'
[ "$(managed_state "$root_link_victim")" = "$root_link_before" ] ||
  fail "symlinked target-root alias changed its physical victim"

# A target /lib symlink outside an offline root must fail before the external
# module tree or any otherwise-safe target file can be mutated.
lib_escape_root="$test_root/lib-escape-root"
lib_escape_victim="$test_root/lib-escape-victim"
mkdir -p \
  "$lib_escape_root/etc" \
  "$lib_escape_root/boot" \
  "$lib_escape_victim/modules/$release"
ln -s "$lib_escape_victim" "$lib_escape_root/lib"
printf 'outside module-tree victim\n' > "$lib_escape_victim/modules/$release/victim"
lib_victim_before="$(file_fingerprint "$lib_escape_victim/modules/$release/victim")"
run_case "$lib_escape_root" "$modules"
expect_failure
assert_output_contains 'managed target directory escapes target root'
[ "$(file_fingerprint "$lib_escape_victim/modules/$release/victim")" = "$lib_victim_before" ] ||
  fail "escaped /lib module-tree victim changed"

# A symlinked configuration parent resolving outside the offline root must not
# receive a file, and all existing direct peers must survive the preflight.
parent_escape_root="$test_root/parent-escape-root"
parent_escape_victim="$test_root/parent-escape-victim"
seed_target_root "$parent_escape_root"
seed_managed_files "$parent_escape_root"
mv "$parent_escape_root/etc/modprobe.d" "$parent_escape_root/etc/modprobe.saved"
mkdir -p "$parent_escape_victim"
printf 'external parent victim\n' > "$parent_escape_victim/victim"
ln -s "$parent_escape_victim" "$parent_escape_root/etc/modprobe.d"
parent_peer_before="$(file_fingerprint "$parent_escape_root/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko")"
parent_victim_before="$(file_fingerprint "$parent_escape_victim/victim")"
run_case "$parent_escape_root" "$modules"
expect_failure
assert_output_contains 'managed target directory escapes target root'
[ "$(file_fingerprint "$parent_escape_victim/victim")" = "$parent_victim_before" ] ||
  fail "escaped parent victim changed"
[ ! -e "$parent_escape_victim/sp11-touchscreen.conf" ] ||
  fail "escaped parent received a managed file"
[ "$(file_fingerprint "$parent_escape_root/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko")" = "$parent_peer_before" ] ||
  fail "parent preflight changed an earlier module peer"

# Symlink, FIFO, and directory leaves at different transaction positions must
# all fail before any regular peer is moved.
for collision in symlink fifo directory; do
  collision_root="$test_root/leaf-$collision-root"
  collision_victim="$test_root/leaf-$collision-victim"
  seed_target_root "$collision_root"
  seed_managed_files "$collision_root"
  case "$collision" in
    symlink)
      collision_path="$collision_root/etc/modules-load.d/sp11-touchscreen.conf"
      rm -f -- "$collision_path"
      printf 'external leaf victim\n' > "$collision_victim"
      ln -s "$collision_victim" "$collision_path"
      collision_before="$(file_fingerprint "$collision_victim")"
      ;;
    fifo)
      collision_path="$collision_root/etc/dracut.conf.d/91-sp11-touchscreen.conf"
      rm -f -- "$collision_path"
      mkfifo "$collision_path"
      collision_before="$(node_fingerprint "$collision_path")"
      ;;
    directory)
      collision_path="$collision_root/etc/sp11-touchscreen/releases/$release"
      rm -f -- "$collision_path"
      mkdir "$collision_path"
      printf 'directory victim\n' > "$collision_path/victim"
      collision_before="$(file_fingerprint "$collision_path/victim")"
      ;;
  esac
  early_peer="$collision_root/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko"
  early_before="$(file_fingerprint "$early_peer")"
  run_case "$collision_root" "$modules"
  expect_failure
  case "$collision" in
    symlink)
      assert_output_contains 'must not be a symlink'
      [ "$(file_fingerprint "$collision_victim")" = "$collision_before" ] ||
        fail "symlink leaf victim changed"
      ;;
    fifo)
      assert_output_contains 'must be absent or a regular file'
      [ "$(node_fingerprint "$collision_path")" = "$collision_before" ] ||
        fail "FIFO leaf changed"
      ;;
    directory)
      assert_output_contains 'must be absent or a regular file'
      [ "$(file_fingerprint "$collision_path/victim")" = "$collision_before" ] ||
        fail "directory leaf victim changed"
      ;;
  esac
  [ "$(file_fingerprint "$early_peer")" = "$early_before" ] ||
    fail "$collision leaf preflight changed an earlier peer"
done

# A special depmod metadata leaf and a symlinked initrd are part of the same
# all-before-mutation preflight as the eight direct destinations.
depmod_fifo_root="$test_root/depmod-fifo-root"
seed_target_root "$depmod_fifo_root"
seed_managed_files "$depmod_fifo_root"
rm -f -- "$depmod_fifo_root/lib/modules/$release/modules.alias"
mkfifo "$depmod_fifo_root/lib/modules/$release/modules.alias"
depmod_fifo_before="$(node_fingerprint "$depmod_fifo_root/lib/modules/$release/modules.alias")"
depmod_fifo_peer="$depmod_fifo_root/etc/modprobe.d/sp11-touchscreen.conf"
depmod_fifo_peer_before="$(file_fingerprint "$depmod_fifo_peer")"
run_case "$depmod_fifo_root" "$modules"
expect_failure
assert_output_contains 'depmod metadata destination must be absent or a regular file'
[ "$(node_fingerprint "$depmod_fifo_root/lib/modules/$release/modules.alias")" = "$depmod_fifo_before" ] ||
  fail "depmod FIFO changed during rejection"
[ "$(file_fingerprint "$depmod_fifo_peer")" = "$depmod_fifo_peer_before" ] ||
  fail "depmod FIFO preflight changed a direct peer"

initrd_link_root="$test_root/initrd-link-root"
initrd_link_victim="$test_root/initrd-link-victim"
seed_target_root "$initrd_link_root"
seed_managed_files "$initrd_link_root"
rm -f -- "$initrd_link_root/boot/initrd.img-$release"
printf 'external initrd victim\n' > "$initrd_link_victim"
ln -s "$initrd_link_victim" "$initrd_link_root/boot/initrd.img-$release"
initrd_link_before="$(file_fingerprint "$initrd_link_victim")"
initrd_link_peer="$initrd_link_root/etc/modprobe.d/sp11-touchscreen.conf"
initrd_link_peer_before="$(file_fingerprint "$initrd_link_peer")"
run_case "$initrd_link_root" "$modules"
expect_failure
assert_output_contains 'target initramfs must not be a symlink'
[ "$(file_fingerprint "$initrd_link_victim")" = "$initrd_link_before" ] ||
  fail "initrd symlink victim changed"
[ "$(file_fingerprint "$initrd_link_peer")" = "$initrd_link_peer_before" ] ||
  fail "initrd symlink preflight changed a direct peer"

# A failure publishing a late direct file occurs after every old destination
# has moved to a private backup. Rollback must restore byte and metadata identity
# across all eight peers without invoking depmod or initramfs regeneration.
publish_fail_root="$test_root/publish-fail-root"
seed_target_root "$publish_fail_root"
seed_managed_files "$publish_fail_root"
publish_fail_before="$(managed_state "$publish_fail_root")"
MOCK_LN_FAIL_DESTINATION="$publish_fail_root/etc/initramfs-tools/hooks/sp11-touchscreen"
export MOCK_LN_FAIL_DESTINATION
run_case "$publish_fail_root" "$modules"
expect_failure
assert_output_contains 'cannot publish touchscreen destination atomically'
[ "$(managed_state "$publish_fail_root")" = "$publish_fail_before" ] ||
  fail "direct publication rollback did not restore every managed peer"
if grep -E '^depmod ' "$command_log" >/dev/null; then
  fail "direct publication failure invoked a post-publication tool"
fi
assert_no_private_artifacts "$publish_fail_root"
MOCK_LN_FAIL_DESTINATION=""
export MOCK_LN_FAIL_DESTINATION

# If an unexpected node occupies the failing publication leaf after its old
# file moved aside, rollback must preserve both parties: the occupant remains
# untouched and the old inode remains recoverable in exactly one mode-0700
# backup. Every unobstructed peer is still restored normally.
publish_occupied_root="$test_root/publish-occupied-root"
publish_occupied_victim="$test_root/publish-occupied-victim"
seed_target_root "$publish_occupied_root"
seed_managed_files "$publish_occupied_root"
publish_occupied_destination="$publish_occupied_root/etc/initramfs-tools/hooks/sp11-touchscreen"
publish_occupied_old="$(exact_file_fingerprint "$publish_occupied_destination")"
publish_occupied_peers="$(direct_state_excluding \
  "$publish_occupied_root" "$publish_occupied_destination")"
publish_occupied_dep="$(exact_file_fingerprint \
  "$publish_occupied_root/lib/modules/$release/modules.dep")"
publish_occupied_initrd="$(exact_file_fingerprint \
  "$publish_occupied_root/boot/initrd.img-$release")"
printf 'unexpected publication occupant victim\n' > "$publish_occupied_victim"
publish_occupied_victim_before="$(exact_file_fingerprint "$publish_occupied_victim")"
MOCK_LN_OCCUPY_DESTINATION="$publish_occupied_destination"
MOCK_LN_OCCUPY_VICTIM="$publish_occupied_victim"
export MOCK_LN_OCCUPY_DESTINATION MOCK_LN_OCCUPY_VICTIM
run_case "$publish_occupied_root" "$modules"
expect_failure
assert_output_contains 'preserved recoverable touchscreen original:'
[ -L "$publish_occupied_destination" ] &&
  [ "$(readlink "$publish_occupied_destination")" = "$publish_occupied_victim" ] ||
  fail "direct rollback changed the unexpected destination occupant"
[ "$(exact_file_fingerprint "$publish_occupied_victim")" = \
  "$publish_occupied_victim_before" ] || fail "direct rollback changed the occupant victim"
[ "$(direct_state_excluding "$publish_occupied_root" "$publish_occupied_destination")" = \
  "$publish_occupied_peers" ] || fail "direct obstruction prevented peer rollback"
[ "$(exact_file_fingerprint "$publish_occupied_root/lib/modules/$release/modules.dep")" = \
  "$publish_occupied_dep" ] || fail "direct obstruction changed depmod metadata"
[ "$(exact_file_fingerprint "$publish_occupied_root/boot/initrd.img-$release")" = \
  "$publish_occupied_initrd" ] || fail "direct obstruction changed the initramfs"
publish_occupied_backup="$(find_single_backup \
  "$publish_occupied_root" '.sp11-touchscreen-backup.*')"
[ "$(file_mode "$publish_occupied_backup")" = "700" ] ||
  fail "preserved direct backup is not mode 0700"
[ "$(exact_file_fingerprint "$publish_occupied_backup/original")" = \
  "$publish_occupied_old" ] || fail "preserved direct original lost identity or metadata"
if find "$publish_occupied_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-depmod-backup.*' \
     -o -name '.sp11-touchscreen-initrd-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "direct obstruction retained an unrelated private artifact"
fi
MOCK_LN_OCCUPY_DESTINATION=""
MOCK_LN_OCCUPY_VICTIM=""
export MOCK_LN_OCCUPY_DESTINATION MOCK_LN_OCCUPY_VICTIM

# A later publication failure can race with replacement of an earlier regular
# hardlink. The recorded dev:inode/content/mode identity prevents rollback from
# deleting that unrecorded occupant and keeps the earlier original recoverable.
publish_regular_root="$test_root/publish-regular-root"
seed_target_root "$publish_regular_root"
seed_managed_files "$publish_regular_root"
publish_regular_earlier="$publish_regular_root/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko"
publish_regular_trigger="$publish_regular_root/etc/initramfs-tools/hooks/sp11-touchscreen"
publish_regular_old="$(exact_file_fingerprint "$publish_regular_earlier")"
publish_regular_peers="$(direct_state_excluding \
  "$publish_regular_root" "$publish_regular_earlier")"
MOCK_LN_REPLACE_TRIGGER_DESTINATION="$publish_regular_trigger"
MOCK_LN_REPLACE_EARLIER_DESTINATION="$publish_regular_earlier"
MOCK_LN_REPLACE_CONTENT='unexpected regular publication occupant'
export MOCK_LN_REPLACE_TRIGGER_DESTINATION
export MOCK_LN_REPLACE_EARLIER_DESTINATION
export MOCK_LN_REPLACE_CONTENT
run_case "$publish_regular_root" "$modules"
expect_failure
assert_output_contains 'preserving changed touchscreen rollback occupant:'
grep -Fxq 'unexpected regular publication occupant' "$publish_regular_earlier" ||
  fail "direct rollback deleted or changed the replacement regular occupant"
[ "$(file_mode "$publish_regular_earlier")" = "600" ] ||
  fail "direct rollback changed the replacement occupant mode"
[ "$(direct_state_excluding "$publish_regular_root" "$publish_regular_earlier")" = \
  "$publish_regular_peers" ] || fail "regular replacement prevented peer rollback"
publish_regular_backup="$(find_single_backup \
  "$publish_regular_root" '.sp11-touchscreen-backup.*')"
[ "$(file_mode "$publish_regular_backup")" = "700" ] ||
  fail "regular replacement recovery backup is not mode 0700"
[ "$(exact_file_fingerprint "$publish_regular_backup/original")" = \
  "$publish_regular_old" ] || fail "regular replacement lost the original identity"
if find "$publish_regular_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-depmod-backup.*' \
     -o -name '.sp11-touchscreen-initrd-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "regular direct replacement retained an unrelated private artifact"
fi
MOCK_LN_REPLACE_TRIGGER_DESTINATION=""
MOCK_LN_REPLACE_EARLIER_DESTINATION=""
MOCK_LN_REPLACE_CONTENT=""
export MOCK_LN_REPLACE_TRIGGER_DESTINATION
export MOCK_LN_REPLACE_EARLIER_DESTINATION
export MOCK_LN_REPLACE_CONTENT

# depmod can fail after replacing direct files and writing both existing and new
# modules.* leaves. The exact previous direct set, metadata set, and initrd must
# be restored, including removal of a newly-created modules.symbols.
depmod_fail_root="$test_root/depmod-fail-root"
seed_target_root "$depmod_fail_root"
seed_managed_files "$depmod_fail_root"
depmod_fail_before="$(managed_state "$depmod_fail_root")"
MOCK_DEPMOD_FAIL=true
export MOCK_DEPMOD_FAIL
run_case "$depmod_fail_root" "$modules"
expect_failure
assert_output_contains 'depmod failed for exact target ABI'
[ "$(managed_state "$depmod_fail_root")" = "$depmod_fail_before" ] ||
  fail "depmod failure did not restore the prior managed state"
[ ! -e "$depmod_fail_root/lib/modules/$release/modules.symbols" ] ||
  fail "depmod rollback retained newly-created metadata"
assert_no_private_artifacts "$depmod_fail_root"
MOCK_DEPMOD_FAIL=false
export MOCK_DEPMOD_FAIL

# A directory injected at an old modules.* leaf blocks only that restoration.
# The directory occupant is retained, the precise pre-mutation snapshot remains
# recoverable, and successfully-restored metadata snapshots are retired.
depmod_occupied_root="$test_root/depmod-occupied-root"
seed_target_root "$depmod_occupied_root"
seed_managed_files "$depmod_occupied_root"
depmod_occupied_direct="$(direct_state_excluding "$depmod_occupied_root")"
depmod_occupied_alias="$(content_metadata_fingerprint \
  "$depmod_occupied_root/lib/modules/$release/modules.alias")"
depmod_occupied_initrd="$(exact_file_fingerprint \
  "$depmod_occupied_root/boot/initrd.img-$release")"
MOCK_DEPMOD_OCCUPY_NAME=modules.dep
export MOCK_DEPMOD_OCCUPY_NAME
run_case "$depmod_occupied_root" "$modules"
expect_failure
assert_output_contains 'depmod rollback is incomplete; recovery files remain in'
depmod_occupied_destination="$depmod_occupied_root/lib/modules/$release/modules.dep"
[ -d "$depmod_occupied_destination" ] &&
  grep -Fxq 'unexpected depmod directory occupant' \
    "$depmod_occupied_destination/occupant" ||
  fail "depmod rollback changed the unexpected directory occupant"
[ "$(direct_state_excluding "$depmod_occupied_root")" = "$depmod_occupied_direct" ] ||
  fail "depmod obstruction prevented direct-file rollback"
[ "$(content_metadata_fingerprint \
  "$depmod_occupied_root/lib/modules/$release/modules.alias")" = \
  "$depmod_occupied_alias" ] || fail "depmod obstruction prevented alias rollback"
[ "$(exact_file_fingerprint "$depmod_occupied_root/boot/initrd.img-$release")" = \
  "$depmod_occupied_initrd" ] || fail "depmod obstruction changed the initramfs"
[ ! -e "$depmod_occupied_root/lib/modules/$release/modules.symbols" ] ||
  fail "depmod obstruction retained newly-created symbol metadata"
depmod_occupied_backup="$(find_single_backup \
  "$depmod_occupied_root" '.sp11-touchscreen-depmod-backup.*')"
[ "$(file_mode "$depmod_occupied_backup")" = "700" ] ||
  fail "preserved depmod backup is not mode 0700"
[ "$(exact_file_fingerprint "$depmod_occupied_backup/modules.dep")" = \
  "$(cat "$depmod_snapshot_fingerprint")" ] ||
  fail "preserved depmod snapshot changed after the restore obstruction"
[ "$(find "$depmod_occupied_backup" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ] ||
  fail "depmod obstruction retained snapshots that were already restored"
if find "$depmod_occupied_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-backup.*' \
     -o -name '.sp11-touchscreen-initrd-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "depmod obstruction retained an unrelated private artifact"
fi
MOCK_DEPMOD_OCCUPY_NAME=""
export MOCK_DEPMOD_OCCUPY_NAME

# After depmod returns, the installer records each generated regular leaf. A
# replacement before the later modinfo verification must not be mistaken for
# that generated inode, so the occupant and old metadata snapshot both survive.
depmod_regular_root="$test_root/depmod-regular-root"
seed_target_root "$depmod_regular_root"
seed_managed_files "$depmod_regular_root"
depmod_regular_destination="$depmod_regular_root/lib/modules/$release/modules.dep"
depmod_regular_direct="$(direct_state_excluding "$depmod_regular_root")"
depmod_regular_alias="$(content_metadata_fingerprint \
  "$depmod_regular_root/lib/modules/$release/modules.alias")"
depmod_regular_initrd="$(exact_file_fingerprint \
  "$depmod_regular_root/boot/initrd.img-$release")"
MOCK_MODINFO_REPLACE_PATH="$depmod_regular_destination"
MOCK_MODINFO_REPLACE_CONTENT='unexpected regular depmod occupant'
MOCK_MODINFO_REPLACE_MARKER="$test_root/depmod-regular-replaced"
MOCK_MODINFO_FAIL_AFTER_REPLACE=true
rm -f -- "$MOCK_MODINFO_REPLACE_MARKER"
export MOCK_MODINFO_REPLACE_PATH MOCK_MODINFO_REPLACE_CONTENT
export MOCK_MODINFO_REPLACE_MARKER MOCK_MODINFO_FAIL_AFTER_REPLACE
run_case "$depmod_regular_root" "$modules"
expect_failure
assert_output_contains 'preserving changed depmod rollback occupant:'
grep -Fxq 'unexpected regular depmod occupant' "$depmod_regular_destination" ||
  fail "depmod rollback deleted or changed the replacement regular occupant"
[ "$(file_mode "$depmod_regular_destination")" = "600" ] ||
  fail "depmod rollback changed the replacement occupant mode"
[ "$(direct_state_excluding "$depmod_regular_root")" = "$depmod_regular_direct" ] ||
  fail "depmod regular replacement prevented direct rollback"
[ "$(content_metadata_fingerprint \
  "$depmod_regular_root/lib/modules/$release/modules.alias")" = \
  "$depmod_regular_alias" ] || fail "depmod regular replacement prevented alias rollback"
[ "$(exact_file_fingerprint "$depmod_regular_root/boot/initrd.img-$release")" = \
  "$depmod_regular_initrd" ] || fail "depmod regular replacement changed the initramfs"
[ ! -e "$depmod_regular_root/lib/modules/$release/modules.symbols" ] ||
  fail "depmod regular replacement retained generated symbol metadata"
depmod_regular_backup="$(find_single_backup \
  "$depmod_regular_root" '.sp11-touchscreen-depmod-backup.*')"
[ "$(file_mode "$depmod_regular_backup")" = "700" ] ||
  fail "depmod regular replacement backup is not mode 0700"
[ "$(exact_file_fingerprint "$depmod_regular_backup/modules.dep")" = \
  "$(cat "$depmod_snapshot_fingerprint")" ] ||
  fail "depmod regular replacement changed the recoverable snapshot"
[ "$(find "$depmod_regular_backup" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ] ||
  fail "depmod regular replacement retained already-restored snapshots"
if find "$depmod_regular_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-backup.*' \
     -o -name '.sp11-touchscreen-initrd-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "depmod regular replacement retained an unrelated private artifact"
fi
MOCK_MODINFO_REPLACE_PATH=""
MOCK_MODINFO_REPLACE_CONTENT=""
MOCK_MODINFO_REPLACE_MARKER=""
MOCK_MODINFO_FAIL_AFTER_REPLACE=false
export MOCK_MODINFO_REPLACE_PATH MOCK_MODINFO_REPLACE_CONTENT
export MOCK_MODINFO_REPLACE_MARKER MOCK_MODINFO_FAIL_AFTER_REPLACE

# An initramfs failure occurs after successful direct publication and depmod.
# Its partially-written initrd and all earlier target mutations must roll back.
initramfs_fail_root="$test_root/initramfs-fail-root"
seed_target_root "$initramfs_fail_root"
seed_managed_files "$initramfs_fail_root"
initramfs_fail_before="$(managed_state "$initramfs_fail_root")"
MOCK_INITRAMFS_FAIL=true
export MOCK_INITRAMFS_FAIL
run_case "$initramfs_fail_root" "$modules"
expect_failure
[ "$(managed_state "$initramfs_fail_root")" = "$initramfs_fail_before" ] ||
  fail "initramfs failure did not restore the prior managed state"
[ ! -e "$initramfs_fail_root/lib/modules/$release/modules.symbols" ] ||
  fail "initramfs rollback retained newly-created depmod metadata"
assert_no_private_artifacts "$initramfs_fail_root"
MOCK_INITRAMFS_FAIL=false
export MOCK_INITRAMFS_FAIL

# A directory occupying the exact initrd leaf after the refresh starts must not
# be removed recursively. Direct files and depmod metadata roll back, while the
# exact pre-refresh snapshot remains recoverable in one mode-0700 container.
initramfs_occupied_root="$test_root/initramfs-occupied-root"
seed_target_root "$initramfs_occupied_root"
seed_managed_files "$initramfs_occupied_root"
initramfs_occupied_direct="$(direct_state_excluding "$initramfs_occupied_root")"
initramfs_occupied_dep="$(content_metadata_fingerprint \
  "$initramfs_occupied_root/lib/modules/$release/modules.dep")"
initramfs_occupied_alias="$(content_metadata_fingerprint \
  "$initramfs_occupied_root/lib/modules/$release/modules.alias")"
MOCK_INITRAMFS_OCCUPY=true
export MOCK_INITRAMFS_OCCUPY
run_case "$initramfs_occupied_root" "$modules"
expect_failure
assert_output_contains 'initramfs rollback is incomplete; recovery file remains at'
initramfs_occupied_destination="$initramfs_occupied_root/boot/initrd.img-$release"
[ -d "$initramfs_occupied_destination" ] &&
  grep -Fxq 'unexpected initramfs directory occupant' \
    "$initramfs_occupied_destination/occupant" ||
  fail "initramfs rollback changed the unexpected directory occupant"
[ "$(direct_state_excluding "$initramfs_occupied_root")" = \
  "$initramfs_occupied_direct" ] || fail "initramfs obstruction prevented direct rollback"
[ "$(content_metadata_fingerprint \
  "$initramfs_occupied_root/lib/modules/$release/modules.dep")" = \
  "$initramfs_occupied_dep" ] || fail "initramfs obstruction prevented modules.dep rollback"
[ "$(content_metadata_fingerprint \
  "$initramfs_occupied_root/lib/modules/$release/modules.alias")" = \
  "$initramfs_occupied_alias" ] || fail "initramfs obstruction prevented modules.alias rollback"
[ ! -e "$initramfs_occupied_root/lib/modules/$release/modules.symbols" ] ||
  fail "initramfs obstruction retained newly-created depmod metadata"
initramfs_occupied_backup="$(find_single_backup \
  "$initramfs_occupied_root" '.sp11-touchscreen-initrd-backup.*')"
[ "$(file_mode "$initramfs_occupied_backup")" = "700" ] ||
  fail "preserved initramfs backup is not mode 0700"
[ "$(exact_file_fingerprint "$initramfs_occupied_backup/original")" = \
  "$(cat "$initrd_snapshot_fingerprint")" ] ||
  fail "preserved initramfs snapshot changed after the restore obstruction"
if find "$initramfs_occupied_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-backup.*' \
     -o -name '.sp11-touchscreen-depmod-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "initramfs obstruction retained an unrelated private artifact"
fi
MOCK_INITRAMFS_OCCUPY=false
export MOCK_INITRAMFS_OCCUPY

# The refreshed initrd identity is recorded before inspection. If a regular
# occupant replaces it before lsinitramfs, rollback preserves that new inode and
# the exact pre-refresh snapshot instead of deleting an unrecorded file.
initramfs_regular_root="$test_root/initramfs-regular-root"
seed_target_root "$initramfs_regular_root"
seed_managed_files "$initramfs_regular_root"
initramfs_regular_destination="$initramfs_regular_root/boot/initrd.img-$release"
initramfs_regular_direct="$(direct_state_excluding "$initramfs_regular_root")"
initramfs_regular_dep="$(content_metadata_fingerprint \
  "$initramfs_regular_root/lib/modules/$release/modules.dep")"
initramfs_regular_alias="$(content_metadata_fingerprint \
  "$initramfs_regular_root/lib/modules/$release/modules.alias")"
MOCK_LSINITRAMFS_REPLACE_PATH="$initramfs_regular_destination"
MOCK_LSINITRAMFS_REPLACE_CONTENT='unexpected regular initramfs occupant'
MOCK_LSINITRAMFS_REPLACE_MARKER="$test_root/initramfs-regular-replaced"
rm -f -- "$MOCK_LSINITRAMFS_REPLACE_MARKER"
export MOCK_LSINITRAMFS_REPLACE_PATH
export MOCK_LSINITRAMFS_REPLACE_CONTENT
export MOCK_LSINITRAMFS_REPLACE_MARKER
run_case "$initramfs_regular_root" "$modules"
expect_failure
assert_output_contains 'preserving changed initramfs rollback occupant:'
grep -Fxq 'unexpected regular initramfs occupant' "$initramfs_regular_destination" ||
  fail "initramfs rollback deleted or changed the replacement regular occupant"
[ "$(file_mode "$initramfs_regular_destination")" = "600" ] ||
  fail "initramfs rollback changed the replacement occupant mode"
[ "$(direct_state_excluding "$initramfs_regular_root")" = \
  "$initramfs_regular_direct" ] || fail "initramfs regular replacement prevented direct rollback"
[ "$(content_metadata_fingerprint \
  "$initramfs_regular_root/lib/modules/$release/modules.dep")" = \
  "$initramfs_regular_dep" ] ||
  fail "initramfs regular replacement prevented modules.dep rollback"
[ "$(content_metadata_fingerprint \
  "$initramfs_regular_root/lib/modules/$release/modules.alias")" = \
  "$initramfs_regular_alias" ] ||
  fail "initramfs regular replacement prevented modules.alias rollback"
[ ! -e "$initramfs_regular_root/lib/modules/$release/modules.symbols" ] ||
  fail "initramfs regular replacement retained generated depmod metadata"
initramfs_regular_backup="$(find_single_backup \
  "$initramfs_regular_root" '.sp11-touchscreen-initrd-backup.*')"
[ "$(file_mode "$initramfs_regular_backup")" = "700" ] ||
  fail "initramfs regular replacement backup is not mode 0700"
[ "$(exact_file_fingerprint "$initramfs_regular_backup/original")" = \
  "$(cat "$initrd_snapshot_fingerprint")" ] ||
  fail "initramfs regular replacement changed the recoverable snapshot"
if find "$initramfs_regular_root" \
  \( -name '.sp11-touchscreen-stage.*' \
     -o -name '.sp11-touchscreen-backup.*' \
     -o -name '.sp11-touchscreen-depmod-backup.*' \
     -o -name '.sp11-touchscreen-restore.*' \) -print | grep -q .; then
  fail "initramfs regular replacement retained an unrelated private artifact"
fi
MOCK_LSINITRAMFS_REPLACE_PATH=""
MOCK_LSINITRAMFS_REPLACE_CONTENT=""
MOCK_LSINITRAMFS_REPLACE_MARKER=""
export MOCK_LSINITRAMFS_REPLACE_PATH
export MOCK_LSINITRAMFS_REPLACE_CONTENT
export MOCK_LSINITRAMFS_REPLACE_MARKER

# A contained relative /lib -> usr/lib merge is valid. The installer must accept
# the builder's private 0500/0400 snapshot, publish exact 0644/0755 leaves, keep
# unrelated files, and commit the new depmod and initramfs state.
success_root="$test_root/usrmerge-success-root"
seed_target_root "$success_root" true
printf 'unrelated module-tree file\n' > "$success_root/usr/lib/modules/$release/unrelated"
run_case "$success_root" "$modules"
[ "$case_status" -eq 0 ] || fail "valid usr-merged offline install failed"
while IFS= read -r path; do
  [ -f "$path" ] && [ ! -L "$path" ] || fail "valid install omitted $path"
done < <(managed_paths "$success_root")
cmp -s "$modules/gpi.ko" \
  "$success_root/usr/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko" ||
  fail "valid install changed gpi module bytes"
cmp -s "$modules/spi-geni-qcom.ko" \
  "$success_root/usr/lib/modules/$release/updates/drivers/spi/spi-geni-qcom.ko" ||
  fail "valid install changed SPI module bytes"
cmp -s "$modules/mshw0485_touch.ko" \
  "$success_root/usr/lib/modules/$release/updates/drivers/input/touchscreen/mshw0485_touch.ko" ||
  fail "valid install changed touchscreen module bytes"
for path in \
  "$success_root/usr/lib/modules/$release/updates/drivers/dma/qcom/gpi.ko" \
  "$success_root/usr/lib/modules/$release/updates/drivers/spi/spi-geni-qcom.ko" \
  "$success_root/usr/lib/modules/$release/updates/drivers/input/touchscreen/mshw0485_touch.ko" \
  "$success_root/etc/modprobe.d/sp11-touchscreen.conf" \
  "$success_root/etc/modules-load.d/sp11-touchscreen.conf" \
  "$success_root/etc/dracut.conf.d/91-sp11-touchscreen.conf" \
  "$success_root/etc/sp11-touchscreen/releases/$release"; do
  [ "$(file_mode "$path")" = "644" ] || fail "valid install set the wrong mode on $path"
done
[ "$(file_mode "$success_root/etc/initramfs-tools/hooks/sp11-touchscreen")" = "755" ] ||
  fail "valid install set the wrong initramfs-hook mode"
grep -Fxq 'new depmod metadata' "$success_root/usr/lib/modules/$release/modules.dep" ||
  fail "valid install did not retain regenerated depmod metadata"
grep -Fxq 'new initramfs bytes' "$success_root/boot/initrd.img-$release" ||
  fail "valid install did not retain the regenerated initramfs"
grep -Fxq 'unrelated module-tree file' "$success_root/usr/lib/modules/$release/unrelated" ||
  fail "valid install changed an unrelated module-tree file"
assert_no_private_artifacts "$success_root"
[ "$(file_mode "$modules")" = "500" ] || fail "installer changed private input directory mode"
for path in "$modules"/*.ko; do
  [ "$(file_mode "$path")" = "400" ] || fail "installer changed private input module mode"
done

echo "Touchscreen installer path-safety and rollback tests passed."
