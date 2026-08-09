#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_helper="$repo_dir/scripts/prepare-sp11-installed-system.sh"
test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
fixture_repo="$test_root/repo"
mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
mount_state="$test_root/mounts"
victim="$test_root/outside-victim"
case_output=""
case_status=0

trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$fixture_repo/scripts" "$mock_bin" "$victim"
cp "$source_helper" "$fixture_repo/scripts/prepare-sp11-installed-system.sh"
chmod +x "$fixture_repo/scripts/prepare-sp11-installed-system.sh"
printf '%s\n' 'outside victim bytes must survive' > "$victim/sentinel"
: > "$command_log"
: > "$mount_state"

cat > "$fixture_repo/scripts/install-sp11-support.sh" <<'EOF_INSTALLER'
#!/bin/sh
set -eu

printf 'installer' >> "$MOCK_COMMAND_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >> "$MOCK_COMMAND_LOG"
done
printf '\n' >> "$MOCK_COMMAND_LOG"

if [ -n "${MOCK_INSTALL_SWAP_LEAF:-}" ]; then
  target_root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        target_root="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  [ -n "$target_root" ]
  /bin/rmdir "$target_root/$MOCK_INSTALL_SWAP_LEAF"
  /bin/ln -s "$MOCK_OUTSIDE_VICTIM" "$target_root/$MOCK_INSTALL_SWAP_LEAF"
fi
EOF_INSTALLER

cat > "$mock_bin/id" <<'EOF_ID'
#!/bin/sh
[ "${1:-}" = "-u" ] || exit 90
printf '0\n'
EOF_ID

cat > "$mock_bin/mountpoint" <<'EOF_MOUNTPOINT'
#!/bin/sh
set -eu

path=""
for argument in "$@"; do
  case "$argument" in
    -q|--) ;;
    *) path="$argument" ;;
  esac
done
[ -n "$path" ] || exit 90
if [ "$path" = "$MOCK_TARGET_ROOT" ] &&
   [ "${MOCK_ROOT_IS_MOUNTPOINT:-true}" = "true" ]; then
  exit 0
fi
grep -Fxq -- "$path" "$MOCK_MOUNT_STATE"
EOF_MOUNTPOINT

cat > "$mock_bin/stat" <<'EOF_STAT'
#!/bin/sh
set -eu

path=""
for argument in "$@"; do
  case "$argument" in
    -Lc|-f|--|%*) ;;
    *) path="$argument" ;;
  esac
done
[ -n "$path" ] || exit 90

if [ "$path" = "${MOCK_WRONG_MOUNT_PATH:-}" ]; then
  printf '999:999\n'
  exit 0
fi

case "$path" in
  /dev|"$MOCK_TARGET_ROOT/dev") printf '101:101\n' ;;
  /proc|"$MOCK_TARGET_ROOT/proc") printf '102:102\n' ;;
  /sys|"$MOCK_TARGET_ROOT/sys") printf '103:103\n' ;;
  /run|"$MOCK_TARGET_ROOT/run") printf '104:104\n' ;;
  *) exit 91 ;;
esac
EOF_STAT

cat > "$mock_bin/mount" <<'EOF_MOUNT'
#!/bin/sh
set -eu

[ "$#" -eq 3 ] && [ "$1" = "--bind" ] || exit 90
source_path="$2"
destination="$3"
printf 'mount %s %s\n' "$source_path" "$destination" >> "$MOCK_COMMAND_LOG"
printf '%s\n' "$destination" >> "$MOCK_MOUNT_STATE"

if [ "${MOCK_SWAP_AFTER_MOUNT_FS:-}" = "${source_path#/}" ] &&
   [ -n "${MOCK_MOUNT_SWAP_LEAF:-}" ]; then
  /bin/rmdir "$MOCK_TARGET_ROOT/$MOCK_MOUNT_SWAP_LEAF"
  /bin/ln -s "$MOCK_OUTSIDE_VICTIM" \
    "$MOCK_TARGET_ROOT/$MOCK_MOUNT_SWAP_LEAF"
fi
EOF_MOUNT

cat > "$mock_bin/umount" <<'EOF_UMOUNT'
#!/bin/sh
set -eu

[ "$#" -eq 2 ] && [ "$1" = "--" ] || exit 90
destination="$2"
printf 'umount %s\n' "$destination" >> "$MOCK_COMMAND_LOG"
if [ "$destination" = "${MOCK_UMOUNT_FAIL_PATH:-}" ]; then
  exit 1
fi
temporary_state="$MOCK_MOUNT_STATE.next"
awk -v destination="$destination" '$0 != destination { print }' \
  "$MOCK_MOUNT_STATE" > "$temporary_state"
mv "$temporary_state" "$MOCK_MOUNT_STATE"
EOF_UMOUNT

cat > "$mock_bin/chroot" <<'EOF_CHROOT'
#!/bin/sh
set -eu

printf 'chroot' >> "$MOCK_COMMAND_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >> "$MOCK_COMMAND_LOG"
done
printf '\n' >> "$MOCK_COMMAND_LOG"
EOF_CHROOT

chmod +x \
  "$fixture_repo/scripts/install-sp11-support.sh" \
  "$mock_bin/id" "$mock_bin/mountpoint" "$mock_bin/stat" \
  "$mock_bin/mount" "$mock_bin/umount" "$mock_bin/chroot"

helper="$fixture_repo/scripts/prepare-sp11-installed-system.sh"

make_target() {
  local path="$1"

  mkdir -p "$path/etc" "$path/dev" "$path/proc" "$path/sys" "$path/run"
  printf '%s\n' 'ID=ubuntu' > "$path/etc/os-release"
}

reset_case_state() {
  : > "$command_log"
  : > "$mount_state"
  unset MOCK_INSTALL_SWAP_LEAF MOCK_SWAP_AFTER_MOUNT_FS
  unset MOCK_MOUNT_SWAP_LEAF MOCK_WRONG_MOUNT_PATH
  unset MOCK_UMOUNT_FAIL_PATH
}

run_case() {
  local target="$1"

  if case_output="$(
    PATH="$mock_bin:/usr/bin:/bin" \
      MOCK_COMMAND_LOG="$command_log" \
      MOCK_MOUNT_STATE="$mount_state" \
      MOCK_TARGET_ROOT="$target" \
      MOCK_OUTSIDE_VICTIM="$victim" \
      MOCK_ROOT_IS_MOUNTPOINT="${MOCK_ROOT_IS_MOUNTPOINT:-true}" \
      MOCK_INSTALL_SWAP_LEAF="${MOCK_INSTALL_SWAP_LEAF:-}" \
      MOCK_SWAP_AFTER_MOUNT_FS="${MOCK_SWAP_AFTER_MOUNT_FS:-}" \
      MOCK_MOUNT_SWAP_LEAF="${MOCK_MOUNT_SWAP_LEAF:-}" \
      MOCK_WRONG_MOUNT_PATH="${MOCK_WRONG_MOUNT_PATH:-}" \
      MOCK_UMOUNT_FAIL_PATH="${MOCK_UMOUNT_FAIL_PATH:-}" \
      "$helper" --target "$target" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

assert_failure_before_mutation() {
  local label="$1" target="$2"

  reset_case_state
  run_case "$target"
  if [ "$case_status" -eq 0 ]; then
    printf '%s unexpectedly succeeded. Output:\n%s\n' "$label" "$case_output" >&2
    exit 1
  fi
  if [ -s "$command_log" ]; then
    printf '%s invoked a mutating command before rejection:\n' "$label" >&2
    cat "$command_log" >&2
    exit 1
  fi
  if [ -s "$mount_state" ]; then
    printf '%s left a mock mount behind.\n' "$label" >&2
    exit 1
  fi
  grep -Fxq 'outside victim bytes must survive' "$victim/sentinel" || {
    printf '%s changed the outside victim.\n' "$label" >&2
    exit 1
  }
}

base_target="$test_root/installed-root"
make_target "$base_target"

assert_failure_before_mutation 'running-root target' '/'
assert_failure_before_mutation 'relative target' 'installed-root'
assert_failure_before_mutation 'parent-traversal target' "$base_target/../installed-root"
assert_failure_before_mutation 'duplicate-separator target' \
  "${base_target%/*}//${base_target##*/}"
assert_failure_before_mutation 'trailing-separator target' "$base_target/"
assert_failure_before_mutation 'control-character target' "${base_target}"$'\n''changed'
assert_failure_before_mutation 'escape-character target' "${base_target}"$'\033''changed'

target_link="$test_root/installed-root-link"
ln -s "$base_target" "$target_link"
assert_failure_before_mutation 'symlinked target root' "$target_link"

linked_parent="$test_root/linked-parent"
real_parent="$test_root/real-parent"
mkdir "$real_parent"
make_target "$real_parent/root"
ln -s "$real_parent" "$linked_parent"
assert_failure_before_mutation 'symlinked target parent' "$linked_parent/root"

MOCK_ROOT_IS_MOUNTPOINT=false
assert_failure_before_mutation 'unmounted target root' "$base_target"
unset MOCK_ROOT_IS_MOUNTPOINT

for leaf in dev proc sys run; do
  symlink_target="$test_root/symlink-$leaf-root"
  make_target "$symlink_target"
  rmdir "$symlink_target/$leaf"
  ln -s "$victim" "$symlink_target/$leaf"
  assert_failure_before_mutation "symlinked /$leaf leaf" "$symlink_target"

  fifo_target="$test_root/fifo-$leaf-root"
  make_target "$fifo_target"
  rmdir "$fifo_target/$leaf"
  mkfifo "$fifo_target/$leaf"
  assert_failure_before_mutation "FIFO /$leaf leaf" "$fifo_target"

  file_target="$test_root/file-$leaf-root"
  make_target "$file_target"
  rmdir "$file_target/$leaf"
  printf '%s\n' 'not a directory' > "$file_target/$leaf"
  assert_failure_before_mutation "regular-file /$leaf leaf" "$file_target"
done

missing_target="$test_root/missing-run-root"
make_target "$missing_target"
rmdir "$missing_target/run"
assert_failure_before_mutation 'missing /run leaf' "$missing_target"

wrong_mount_target="$test_root/wrong-mount-root"
make_target "$wrong_mount_target"
reset_case_state
printf '%s\n' "$wrong_mount_target/dev" > "$mount_state"
MOCK_WRONG_MOUNT_PATH="$wrong_mount_target/dev"
run_case "$wrong_mount_target"
if [ "$case_status" -eq 0 ] || [ -s "$command_log" ]; then
  printf 'Unexpected existing /dev mount did not fail before mutation:\n%s\n' \
    "$case_output" >&2
  exit 1
fi
unset MOCK_WRONG_MOUNT_PATH

installer_swap_target="$test_root/installer-swap-root"
make_target "$installer_swap_target"
reset_case_state
MOCK_INSTALL_SWAP_LEAF=sys
run_case "$installer_swap_target"
if [ "$case_status" -eq 0 ]; then
  printf 'Post-installer target swap unexpectedly succeeded:\n%s\n' \
    "$case_output" >&2
  exit 1
fi
grep -Fxq \
  "installer --installed-system --root $installer_swap_target" "$command_log"
if grep -Eq '^(mount|chroot) ' "$command_log"; then
  printf 'Post-installer target swap reached mount/chroot:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
grep -Fxq 'outside victim bytes must survive' "$victim/sentinel"
unset MOCK_INSTALL_SWAP_LEAF

mount_swap_target="$test_root/mount-swap-root"
make_target "$mount_swap_target"
reset_case_state
MOCK_SWAP_AFTER_MOUNT_FS=dev
MOCK_MOUNT_SWAP_LEAF=proc
run_case "$mount_swap_target"
if [ "$case_status" -eq 0 ]; then
  printf 'Between-mount target swap unexpectedly succeeded:\n%s\n' \
    "$case_output" >&2
  exit 1
fi
grep -Fxq "mount /dev $mount_swap_target/dev" "$command_log"
grep -Fxq "umount $mount_swap_target/dev" "$command_log"
if grep -Eq '^chroot ' "$command_log"; then
  printf 'Between-mount target swap reached chroot:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
[ ! -s "$mount_state" ] || {
  echo 'Between-mount target swap left a helper-created mount behind.' >&2
  exit 1
}
grep -Fxq 'outside victim bytes must survive' "$victim/sentinel"
unset MOCK_SWAP_AFTER_MOUNT_FS MOCK_MOUNT_SWAP_LEAF

success_target="$test_root/success-root"
make_target "$success_target"
reset_case_state
run_case "$success_target"
if [ "$case_status" -ne 0 ]; then
  printf 'Valid installed target failed with status %s:\n%s\n' \
    "$case_status" "$case_output" >&2
  exit 1
fi

expected_log="$test_root/expected-success.log"
cat > "$expected_log" <<EOF_EXPECTED
installer --installed-system --root $success_target
mount /dev $success_target/dev
mount /proc $success_target/proc
mount /sys $success_target/sys
mount /run $success_target/run
chroot $success_target update-grub
chroot $success_target update-initramfs -u -k all
umount $success_target/run
umount $success_target/sys
umount $success_target/proc
umount $success_target/dev
EOF_EXPECTED
diff -u "$expected_log" "$command_log"
[ ! -s "$mount_state" ] || {
  echo 'Successful installed-system preparation left a helper-created mount behind.' >&2
  exit 1
}

cleanup_failure_target="$test_root/cleanup-failure-root"
make_target "$cleanup_failure_target"
reset_case_state
MOCK_UMOUNT_FAIL_PATH="$cleanup_failure_target/proc"
run_case "$cleanup_failure_target"
if [ "$case_status" -eq 0 ]; then
  printf 'Failed bind cleanup was reported as successful:\n%s\n' \
    "$case_output" >&2
  exit 1
fi
grep -Fq 'could not unmount helper-created target' <<< "$case_output"
if grep -Fq 'Installed system prepared for first Surface Pro 11 NVMe boot.' \
  <<< "$case_output"; then
  echo 'Helper printed success after a bind cleanup failure.' >&2
  exit 1
fi
grep -Fxq "$cleanup_failure_target/proc" "$mount_state" || {
  echo 'Cleanup-failure fixture did not preserve the failed mock mount state.' >&2
  exit 1
}
unset MOCK_UMOUNT_FAIL_PATH

preexisting_target="$test_root/preexisting-dev-root"
make_target "$preexisting_target"
reset_case_state
printf '%s\n' "$preexisting_target/dev" > "$mount_state"
run_case "$preexisting_target"
if [ "$case_status" -ne 0 ]; then
  printf 'Matching pre-existing /dev bind failed with status %s:\n%s\n' \
    "$case_status" "$case_output" >&2
  exit 1
fi
if grep -Fq "$preexisting_target/dev" "$command_log"; then
  printf 'Matching pre-existing /dev bind was mutated:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
if [ "$(cat "$mount_state")" != "$preexisting_target/dev" ]; then
  printf 'Matching pre-existing /dev bind was not preserved.\n' >&2
  exit 1
fi

echo 'Installed-system target containment and mount-transaction tests passed.'
