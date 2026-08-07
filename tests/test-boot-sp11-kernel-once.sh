#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/scripts/boot-sp11-kernel-once.sh"
test_root="$(mktemp -d)"
mock_bin="$test_root/bin"
boot_dir="$test_root/boot"
grub_dir="$boot_dir/grub"
grubenv="$grub_dir/grubenv"
command_log="$test_root/commands.log"
experimental_abi="fixture-experimental-qcom-x1e"
fallback_abi="fixture-fallback-qcom-x1e"
fallback_title="Advanced options>Fixture, with Linux $fallback_abi"
fallback_id="fixture-advanced>fixture-fallback"
case_output=""
case_status=0
mock_grub_fs="ext2"
mock_mount_options="rw,relatime"

trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$mock_bin" "$grub_dir"

cat > "$mock_bin/uname" <<'EOF_UNAME'
#!/bin/sh
printf '%s\n' "$MOCK_RUNNING_ABI"
EOF_UNAME

cat > "$mock_bin/grub-editenv" <<'EOF_EDITENV'
#!/bin/sh
printf 'grub-editenv %s\n' "$*" >> "$MOCK_COMMAND_LOG"
if [ "$#" -eq 2 ] && [ "$2" = "list" ]; then
  exec cat "$1"
fi
exit 97
EOF_EDITENV

cat > "$mock_bin/findmnt" <<'EOF_FINDMNT'
#!/bin/sh
if [ "$MOCK_MOUNT_OPTIONS" = "probe-failure" ]; then
  exit 1
fi
printf '%s\n' "$MOCK_MOUNT_OPTIONS"
EOF_FINDMNT

cat > "$mock_bin/grub-probe" <<'EOF_PROBE'
#!/bin/sh
case "$*" in
  *--target=fs*)
    if [ "$MOCK_GRUB_FS" = "probe-failure" ]; then
      exit 1
    fi
    printf '%s\n' "$MOCK_GRUB_FS"
    ;;
  *--target=abstraction*)
    exit 0
    ;;
  *)
    exit 96
    ;;
esac
EOF_PROBE

cat > "$mock_bin/grub-reboot" <<'EOF_REBOOT'
#!/bin/sh
printf 'grub-reboot %s\n' "$*" >> "$MOCK_COMMAND_LOG"
exit 98
EOF_REBOOT

cat > "$mock_bin/grub-set-default" <<'EOF_SET_DEFAULT'
#!/bin/sh
printf 'grub-set-default %s\n' "$*" >> "$MOCK_COMMAND_LOG"
exit 99
EOF_SET_DEFAULT

chmod +x "$mock_bin"/*

cat > "$grub_dir/grub.cfg" <<'EOF_GRUB'
if [ "${next_entry}" ]; then
  set default="${next_entry}"
  set next_entry=
  if [ "${env_block}" ]; then
    save_env -f "${env_block}" next_entry
  else
    save_env next_entry
  fi
  set boot_once=true
else
  set default="${saved_entry}"
fi

submenu 'Advanced options' $menuentry_id_option 'fixture-advanced' {
  menuentry 'Fixture, with Linux fixture-experimental-qcom-x1e' $menuentry_id_option 'fixture-experimental' {
  }
  menuentry 'Fixture, with Linux fixture-experimental-qcom-x1e (recovery mode)' $menuentry_id_option 'fixture-experimental-recovery' {
  }
  menuentry 'Fixture, with Linux fixture-fallback-qcom-x1e' $menuentry_id_option 'fixture-fallback' {
  }
}
EOF_GRUB

printf '%s\n' 'fixture experimental kernel' > "$boot_dir/vmlinuz-$experimental_abi"
printf '%s\n' 'fixture experimental initramfs' > "$boot_dir/initrd.img-$experimental_abi"
printf '%s\n' 'fixture fallback kernel' > "$boot_dir/vmlinuz-$fallback_abi"
printf '%s\n' 'fixture fallback initramfs' > "$boot_dir/initrd.img-$fallback_abi"

write_grubenv() {
  local saved_entry="$1" next_entry="${2:-}"

  printf 'saved_entry=%s\nnext_entry=%s\n' "$saved_entry" "$next_entry" > "$grubenv"
}

run_dry_run() {
  : > "$command_log"
  if case_output="$(
    PATH="$mock_bin:/usr/bin:/bin" \
      MOCK_RUNNING_ABI="$fallback_abi" \
      MOCK_COMMAND_LOG="$command_log" \
      MOCK_GRUB_FS="$mock_grub_fs" \
      MOCK_MOUNT_OPTIONS="$mock_mount_options" \
      "$helper" \
      --boot-directory "$boot_dir" \
      --experimental-abi "$experimental_abi" \
      --fallback-abi "$fallback_abi" 2>&1
  )"; then
    case_status=0
  else
    case_status=$?
  fi
}

assert_status() {
  local expected="$1"

  if [ "$case_status" -ne "$expected" ]; then
    printf 'Expected status %s, got %s. Output:\n%s\n' \
      "$expected" "$case_status" "$case_output" >&2
    exit 1
  fi
}

assert_output_contains() {
  local expected="$1"

  if ! grep -Fq -- "$expected" <<< "$case_output"; then
    printf 'Missing expected output: %s\nFull output:\n%s\n' \
      "$expected" "$case_output" >&2
    exit 1
  fi
}

assert_output_excludes() {
  local unexpected="$1"

  if grep -Fq -- "$unexpected" <<< "$case_output"; then
    printf 'Unexpected output: %s\nFull output:\n%s\n' \
      "$unexpected" "$case_output" >&2
    exit 1
  fi
}

assert_no_mutating_commands() {
  if grep -Eq 'grub-(reboot|set-default)' "$command_log"; then
    printf 'Dry run invoked a mutating GRUB command:\n' >&2
    cat "$command_log" >&2
    exit 1
  fi
}

assert_read_only_commands() {
  assert_no_mutating_commands
  if ! grep -Fq 'grub-editenv ' "$command_log"; then
    echo 'Dry run did not inspect grubenv.' >&2
    exit 1
  fi
  if grep -F 'grub-editenv ' "$command_log" | grep -Fqv ' list'; then
    printf 'Dry run used grub-editenv for more than a list operation:\n' >&2
    cat "$command_log" >&2
    exit 1
  fi
}

assert_grubenv_unchanged() {
  local before="$1" after

  after="$(cat "$grubenv")"
  if [ "$after" != "$before" ]; then
    printf 'Dry run changed grubenv.\nBefore:\n%s\nAfter:\n%s\n' \
      "$before" "$after" >&2
    exit 1
  fi
}

use_static_grub_default() {
  sed 's/set default="${saved_entry}"/set default="Fixture static default"/' \
    "$grub_dir/grub.cfg" > "$grub_dir/grub.cfg.static"
  mv "$grub_dir/grub.cfg.static" "$grub_dir/grub.cfg"
}

# Exact composite title is accepted.
write_grubenv "$fallback_title"
title_before="$(cat "$grubenv")"
run_dry_run
assert_status 0
assert_output_contains 'preflight passed'
assert_output_contains 'DRY RUN: no GRUB state was changed.'
assert_read_only_commands
assert_grubenv_unchanged "$title_before"

# Exact composite menu ID is accepted.
write_grubenv "$fallback_id"
id_before="$(cat "$grubenv")"
run_dry_run
assert_status 0
assert_output_contains 'preflight passed'
assert_output_contains "Fallback selector:      $fallback_id"
assert_read_only_commands
assert_grubenv_unchanged "$id_before"

# A saved entry for another ABI blocks the preflight and provides remediation.
write_grubenv 'Advanced options>Fixture, with Linux fixture-old-qcom-x1e'
mismatch_before="$(cat "$grubenv")"
run_dry_run
assert_status 1
assert_output_contains 'preflight blocked'
assert_output_contains 'saved_entry does not identify the declared fallback ABI'
assert_output_contains "sudo grub-set-default '$fallback_title'"
assert_output_contains 'No GRUB state was changed.'
assert_output_excludes 'preflight passed'
assert_read_only_commands
assert_grubenv_unchanged "$mismatch_before"

# An existing one-shot selection is never overwritten.
write_grubenv "$fallback_title" 'fixture-advanced>fixture-already-queued'
queued_before="$(cat "$grubenv")"
run_dry_run
assert_status 1
assert_output_contains 'GRUB already has a queued next_entry'
assert_output_excludes 'preflight passed'
assert_read_only_commands
assert_grubenv_unchanged "$queued_before"

# Filesystems without verified GRUB environment writes fail closed.
write_grubenv "$fallback_title"
for unsafe_fs in btrfs zfs; do
  mock_grub_fs="$unsafe_fs"
  unsafe_before="$(cat "$grubenv")"
  run_dry_run
  assert_status 1
  assert_output_contains "filesystem '$unsafe_fs' is unsafe"
  assert_output_contains 'no GRUB state was changed'
  assert_no_mutating_commands
  assert_grubenv_unchanged "$unsafe_before"
done

mock_grub_fs="mysteryfs"
unknown_before="$(cat "$grubenv")"
run_dry_run
assert_status 1
assert_output_contains "filesystem 'mysteryfs' is outside the verified ext-family allowlist"
assert_no_mutating_commands
assert_grubenv_unchanged "$unknown_before"

mock_grub_fs="probe-failure"
probe_failure_before="$(cat "$grubenv")"
run_dry_run
assert_status 1
assert_output_contains 'Could not determine the GRUB environment filesystem'
assert_no_mutating_commands
assert_grubenv_unchanged "$probe_failure_before"

# The containing filesystem must be positively verified writable.
mock_grub_fs="ext2"
for unsafe_mount in ro,relatime probe-failure mystery-options; do
  mock_mount_options="$unsafe_mount"
  mount_before="$(cat "$grubenv")"
  run_dry_run
  assert_status 1
  assert_output_contains 'no GRUB state was changed'
  assert_no_mutating_commands
  assert_grubenv_unchanged "$mount_before"
done

# A matching saved_entry is insufficient when the generated default is static.
mock_grub_fs="ext2"
mock_mount_options="rw,relatime"
write_grubenv "$fallback_title"
use_static_grub_default
static_before="$(cat "$grubenv")"
run_dry_run
assert_status 1
assert_output_contains 'preflight blocked'
assert_output_contains 'non-one-shot path does not consume saved_entry'
assert_output_contains 'GRUB_DEFAULT=saved'
assert_output_contains 'sudo update-grub'
assert_output_contains 'grub-set-default alone is insufficient'
assert_output_excludes 'preflight passed'
assert_read_only_commands
assert_grubenv_unchanged "$static_before"

echo 'One-shot kernel boot guard fixtures passed.'
