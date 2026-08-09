#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
installer="$repo_dir/scripts/install-sp11-support.sh"

fail() {
  echo "Error: $*" >&2
  exit 1
}

if [ "$EUID" -ne 0 ]; then
  fail "run this regression as root against its disposable offline target"
fi

test_parent="$(mktemp -d /tmp/sp11-support-retirement.XXXXXX)"
if [ -z "$test_parent" ] || [ "$test_parent" = "/" ] || [ ! -d "$test_parent" ]; then
  fail "could not create a bounded disposable test directory"
fi
case "$test_parent" in
  /tmp/sp11-support-retirement.*|/private/tmp/sp11-support-retirement.*) ;;
  *) fail "disposable test directory escaped the expected temporary root" ;;
esac

cleanup() {
  if [ -n "${test_parent:-}" ] && [ "$test_parent" != "/" ] && [ -d "$test_parent" ]; then
    rm -rf -- "$test_parent"
  fi
}
trap cleanup EXIT HUP INT TERM

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

file_fingerprint() {
  local path="$1" metadata

  if metadata="$(stat -c '%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%i:%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    fail "could not stat $path"
  fi
  printf '%s:%s\n' "$(sha256_file "$path")" "$metadata"
}

file_preservation_fingerprint() {
  local path="$1" metadata

  if metadata="$(stat -c '%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    fail "could not stat $path"
  fi
  printf '%s:%s\n' "$(sha256_file "$path")" "$metadata"
}

file_mode() {
  local mode

  if mode="$(stat -c '%a' -- "$1" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)"; then
    :
  else
    fail "could not stat mode for $1"
  fi
  printf '%s\n' "$mode"
}

node_fingerprint() {
  local path="$1" metadata

  if metadata="$(stat -c '%F:%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%HT:%i:%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    fail "could not stat node $path"
  fi
  printf '%s\n' "$metadata"
}

link_fingerprint() {
  local path="$1" metadata

  if metadata="$(stat -c '%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%i:%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    fail "could not stat symlink $path"
  fi
  printf '%s:%s\n' "$(readlink "$path")" "$metadata"
}

tree_snapshot_excluding_managed() {
  local root="$1" rel

  (
    cd "$root"
    printf '%s\n' 'directories:'
    find . -type d -print | LC_ALL=C sort
    printf '%s\n' 'files-and-links:'
    find . -mindepth 1 \( -type f -o -type l \) \
      ! -path './usr/local/sbin/sp11-grub-inject-dtb' \
      ! -path './etc/kernel/postinst.d/zzzz-surface-pro-11-dtb' \
      ! -path './etc/kernel/postrm.d/zzzz-surface-pro-11-dtb' \
      -print | LC_ALL=C sort |
      while IFS= read -r rel; do
        if [ -L "$rel" ]; then
          printf 'link:%s:%s\n' "$rel" "$(readlink "$rel")"
        else
          printf 'file:%s:%s\n' "$rel" \
            "$(file_fingerprint "$root/${rel#./}")"
        fi
      done
  )
}

assert_absent() {
  local path="$1"

  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "expected managed artifact to be absent: $path"
  fi
}

assert_present() {
  local path="$1"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    fail "expected unrelated artifact to remain: $path"
  fi
}

assert_no_retirement_backups() {
  local root="$1"

  if find "$root" -type d \
    -name '.sp11-loose-dtb-retirement-backup.*' -print -quit | grep -q .; then
    fail "successful or complete rollback left a retirement backup in $root"
  fi
}

assert_single_recovery_backup() {
  local root="$1" expected_parent="$2" expected_fingerprint="$3"
  local originals backup original_count

  originals="$(find "$root" -type f \
    -path '*/.sp11-loose-dtb-retirement-backup.*/original' -print)"
  original_count="$(printf '%s\n' "$originals" | awk 'NF { count++ } END { print count + 0 }')"
  [ "$original_count" -eq 1 ] ||
    fail "expected exactly one recoverable retirement original in $root"
  backup="$(dirname "$originals")"
  [ "$(dirname "$backup")" = "$expected_parent" ] ||
    fail "recovery backup was not kept beside its original destination"
  [ "$(file_mode "$backup")" = "700" ] ||
    fail "recovery backup is not mode 0700: $backup"
  [ "$(file_preservation_fingerprint "$backup/original")" = \
    "$expected_fingerprint" ] ||
    fail "recovery backup did not preserve original bytes and metadata"
}

assert_single_recovery_occupant() {
  local root="$1" expected_parent="$2" expected_text="$3"
  local occupants recovery backup occupant_count

  occupants="$(find "$root" -type f \
    -path '*/.sp11-loose-dtb-retirement-backup.*/rollback-current' -print)"
  occupant_count="$(printf '%s\n' "$occupants" |
    awk 'NF { count++ } END { print count + 0 }')"
  [ "$occupant_count" -eq 1 ] ||
    fail "expected exactly one preserved rollback occupant in $root"
  recovery="$occupants"
  backup="$(dirname "$recovery")"
  [ "$(dirname "$backup")" = "$expected_parent" ] ||
    fail "rollback occupant was not preserved beside its destination"
  [ "$(file_mode "$backup")" = "700" ] ||
    fail "rollback occupant backup is not mode 0700: $backup"
  grep -F "$expected_text" "$recovery" >/dev/null ||
    fail "preserved rollback occupant has unexpected bytes"
}

mock_bin="$test_parent/mock-bin"
tripwire="$test_parent/update-grub.called"
mkdir -p "$mock_bin"
cat > "$mock_bin/update-grub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "${SP11_UPDATE_GRUB_TRIPWIRE:?}"
exit 97
EOF
chmod 0755 "$mock_bin/update-grub"

run_offline_installer() {
  local root="$1"
  shift

  SP11_UPDATE_GRUB_TRIPWIRE="$tripwire" \
  PATH="$mock_bin:$PATH" \
    "$installer" --root "$root" "$@"
}

expect_offline_installer_failure() {
  local root="$1" output="$2"
  shift 2

  if run_offline_installer "$root" "$@" > "$output" 2>&1; then
    fail "installer accepted an unsafe offline target path"
  fi
  grep -F 'Unsafe offline target path ' "$output" >/dev/null ||
    fail "unsafe offline target failure did not identify the path guard"
  [ ! -e "$tripwire" ] || fail "unsafe offline target invoked update-grub"
}

live_repo="$test_parent/live-repo"
live_installer="$live_repo/scripts/install-sp11-support.sh"
live_mock_bin="$test_parent/live-mock-bin"
mkdir -p "$(dirname "$live_installer")" "$live_mock_bin"

live_override_count="$(grep -c '^LIVE_ROOT="false"$' "$installer")"
[ "$live_override_count" -eq 1 ] ||
  fail "could not identify the single live-root decision for the fixture copy"
awk '
  !replaced && $0 == "LIVE_ROOT=\"false\"" {
    print "LIVE_ROOT=\"true\""
    replaced = 1
    next
  }
  { print }
  END { if (!replaced) exit 1 }
' "$installer" > "$live_installer"
chmod 0755 "$live_installer"

cat > "$live_mock_bin/update-grub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture_root="${SP11_RETIREMENT_FIXTURE_ROOT:?}"
mode="${SP11_RETIREMENT_FIXTURE_MODE:?}"
grub_cfg="$fixture_root/boot/grub/grub.cfg"

write_clean_grub() {
  printf '%s\n' \
    "menuentry 'generated embedded-DTB kernel' {" \
    '  linux /vmlinuz-generated' \
    '}' > "$grub_cfg"
}

case "$mode" in
  success)
    write_clean_grub
    ;;
  update-grub-failure)
    printf '%s\n' 'partial generated grub.cfg' > "$grub_cfg"
    exit 41
    ;;
  postcheck-failure)
    printf '%s\n' \
      "menuentry 'stale loose DTB' {" \
      '  linux /vmlinuz-generated' \
      '  devicetree /sp11-denali.dtb' \
      '}' > "$grub_cfg"
    ;;
  trailing-space-postcheck-failure)
    printf '%s\n' \
      "menuentry 'stale loose DTB with padding' {" \
      '  linux /vmlinuz-generated' \
      '  devicetree /sp11-denali.dtb   ' \
      '}' > "$grub_cfg"
    ;;
  rollback-replace-generated-grub)
    printf '%s\n' \
      "menuentry 'generated cfg awaiting rollback replacement' {" \
      '  linux /vmlinuz-generated' \
      '  devicetree /sp11-denali.dtb' \
      '}' > "$grub_cfg"
    ;;
  historical-dtb-mutation)
    write_clean_grub
    printf '%s\n' 'mutated loose DTB occupant' > \
      "$fixture_root/boot/sp11-denali.dtb"
    ;;
  grubenv-mutation)
    write_clean_grub
    printf '%s\n' 'saved_entry=changed-by-update-grub' > \
      "$fixture_root/boot/grub/grubenv"
    ;;
  occupied-destination)
    write_clean_grub
    printf '%s\n' 'concurrent managed-leaf occupant' > \
      "$fixture_root/usr/local/sbin/sp11-grub-inject-dtb"
    chmod 0703 "$fixture_root/usr/local/sbin/sp11-grub-inject-dtb"
    touch -t 202202030405.06 \
      "$fixture_root/usr/local/sbin/sp11-grub-inject-dtb"
    ;;
  *)
    echo "unknown retirement fixture mode: $mode" >&2
    exit 99
    ;;
esac
EOF
chmod 0755 "$live_mock_bin/update-grub"

cat > "$live_mock_bin/fault-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command_name="${0##*/}"
fixture_root="${SP11_RETIREMENT_FIXTURE_ROOT:?}"
mode="${SP11_RETIREMENT_FIXTURE_MODE:?}"
fault_state="${SP11_RETIREMENT_FAULT_STATE:?}"
helper="$fixture_root/usr/local/sbin/sp11-grub-inject-dtb"
grub_cfg="$fixture_root/boot/grub/grub.cfg"

case "$command_name" in
  stat) real_command="${SP11_REAL_STAT:?}" ;;
  mktemp) real_command="${SP11_REAL_MKTEMP:?}" ;;
  chmod) real_command="${SP11_REAL_CHMOD:?}" ;;
  cp) real_command="${SP11_REAL_CP:?}" ;;
  mv) real_command="${SP11_REAL_MV:?}" ;;
  *) exit 98 ;;
esac

case "$mode:$command_name" in
  prepare-stat-failure:stat)
    for argument in "$@"; do
      if [ "$argument" = "$helper" ]; then
        exit 71
      fi
    done
    ;;
  prepare-mktemp-failure:mktemp)
    case "${1:-}" in
      */.sp11-loose-dtb-retirement-backup.XXXXXX) exit 72 ;;
    esac
    ;;
  prepare-chmod-failure:chmod)
    if [ "${1:-}" = "0700" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*) exit 73 ;;
      esac
    fi
    ;;
  pre-stage-concurrent-replacement:cp)
    if [ "${3:-}" = "$fixture_root/boot/grub/grubenv" ]; then
      "$real_command" "$@"
      replacement="$fixture_root/usr/local/sbin/.sp11-concurrent-replacement"
      printf '%s\n' 'pre-stage concurrent managed-leaf occupant' > "$replacement"
      "${SP11_REAL_CHMOD:?}" 0705 "$replacement"
      "${SP11_REAL_MV:?}" "$replacement" "$helper"
      exit 0
    fi
    ;;
  grub-cfg-pre-stage-replacement:cp)
    if [ "${3:-}" = "$fixture_root/boot/grub/grubenv" ]; then
      "$real_command" "$@"
      replacement="$fixture_root/boot/grub/.sp11-concurrent-grub-cfg"
      printf '%s\n' 'pre-stage concurrent grub.cfg occupant' > "$replacement"
      "${SP11_REAL_CHMOD:?}" 0604 "$replacement"
      "${SP11_REAL_MV:?}" "$replacement" "$grub_cfg"
      exit 0
    fi
    ;;
  rollback-replace-original-grub:cp|rollback-replace-managed-current:cp|rollback-replace-monitored-current:cp)
    if [ "${3:-}" = "$fixture_root/boot/grub/grubenv" ]; then
      "$real_command" "$@"
      exit 76
    fi
    ;;
  move-then-fail:mv|signal-after-move:mv)
    if [ "${1:-}" = "$helper" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*/retired)
          if [ ! -e "$fault_state" ]; then
            "$real_command" "$@"
            : > "$fault_state"
            if [ "$mode" = "signal-after-move" ]; then
              kill -TERM "$PPID"
              exit 0
            fi
            exit 74
          fi
          ;;
      esac
    fi
    ;;
  grub-cfg-move-then-fail:mv|grub-cfg-signal-after-move:mv)
    if [ "${1:-}" = "$grub_cfg" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*/retired)
          if [ ! -e "$fault_state" ]; then
            "$real_command" "$@"
            : > "$fault_state"
            if [ "$mode" = "grub-cfg-signal-after-move" ]; then
              kill -TERM "$PPID"
              exit 0
            fi
            exit 75
          fi
          ;;
      esac
    fi
    ;;
  rollback-replace-original-grub:mv|rollback-replace-generated-grub:mv)
    if [ "${1:-}" = "$grub_cfg" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*/rollback-current)
          replacement="$fixture_root/boot/grub/.sp11-rollback-cfg-replacement"
          printf '%s\n' "rollback-time concurrent grub.cfg occupant: $mode" > \
            "$replacement"
          "${SP11_REAL_CHMOD:?}" 0606 "$replacement"
          "${SP11_REAL_MV:?}" "$replacement" "$grub_cfg"
          "$real_command" "$@"
          exit 0
          ;;
      esac
    fi
    ;;
  rollback-replace-managed-current:mv)
    if [ "${1:-}" = "$helper" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*/rollback-current)
          replacement="$fixture_root/usr/local/sbin/.sp11-rollback-helper-replacement"
          printf '%s\n' 'rollback-time concurrent managed-leaf occupant' > \
            "$replacement"
          "${SP11_REAL_CHMOD:?}" 0706 "$replacement"
          "${SP11_REAL_MV:?}" "$replacement" "$helper"
          "$real_command" "$@"
          exit 0
          ;;
      esac
    fi
    ;;
  rollback-replace-monitored-current:mv)
    if [ "${1:-}" = "$fixture_root/boot/grub/grubenv" ]; then
      case "${2:-}" in
        */.sp11-loose-dtb-retirement-backup.*/rollback-current)
          replacement="$fixture_root/boot/grub/.sp11-rollback-grubenv-replacement"
          printf '%s\n' 'rollback-time concurrent grubenv occupant' > \
            "$replacement"
          "${SP11_REAL_CHMOD:?}" 0606 "$replacement"
          "${SP11_REAL_MV:?}" "$replacement" \
            "$fixture_root/boot/grub/grubenv"
          "$real_command" "$@"
          exit 0
          ;;
      esac
    fi
    ;;
esac

exec "$real_command" "$@"
EOF
chmod 0755 "$live_mock_bin/fault-command"
for fault_command in stat mktemp chmod cp mv; do
  ln -s fault-command "$live_mock_bin/$fault_command"
done

prepare_live_retirement_root() {
  local root="$1"

  mkdir -p \
    "$root/usr/local/sbin" \
    "$root/etc/kernel/postinst.d" \
    "$root/etc/kernel/postrm.d" \
    "$root/boot/grub"
  printf '%s\n' 'managed helper original' > \
    "$root/usr/local/sbin/sp11-grub-inject-dtb"
  printf '%s\n' 'managed postinst original' > \
    "$root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
  printf '%s\n' 'managed postrm original' > \
    "$root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
  printf '%s\n' 'historical loose DTB original' > \
    "$root/boot/sp11-denali.dtb"
  printf '%s\n' \
    "menuentry 'known-good historical fallback' {" \
    '  linux /vmlinuz-known-good' \
    '  devicetree /sp11-denali.dtb' \
    '}' > "$root/boot/grub/grub.cfg"
  printf '%s\n' 'saved_entry=known-good' > "$root/boot/grub/grubenv"
  chmod 0751 "$root/usr/local/sbin/sp11-grub-inject-dtb"
  chmod 0752 "$root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
  chmod 0754 "$root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
  chmod 0600 "$root/boot/sp11-denali.dtb"
  chmod 0640 "$root/boot/grub/grub.cfg"
  chmod 0600 "$root/boot/grub/grubenv"
  touch -t 202001020301.02 \
    "$root/usr/local/sbin/sp11-grub-inject-dtb"
  touch -t 202001020302.03 \
    "$root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
  touch -t 202001020303.04 \
    "$root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
  touch -t 202001020304.05 "$root/boot/sp11-denali.dtb"
  touch -t 202001020305.06 "$root/boot/grub/grub.cfg"
  touch -t 202001020306.07 "$root/boot/grub/grubenv"
}

live_retirement_state_fingerprint() {
  local root="$1" rel

  for rel in \
    usr/local/sbin/sp11-grub-inject-dtb \
    etc/kernel/postinst.d/zzzz-surface-pro-11-dtb \
    etc/kernel/postrm.d/zzzz-surface-pro-11-dtb \
    boot/sp11-denali.dtb \
    boot/grub/grub.cfg \
    boot/grub/grubenv; do
    printf '%s:%s\n' "$rel" "$(file_fingerprint "$root/$rel")"
  done
}

run_live_retirement() {
  local root="$1" mode="$2" output="$3"

  SP11_RETIREMENT_FIXTURE_ROOT="$root" \
  SP11_RETIREMENT_FIXTURE_MODE="$mode" \
  SP11_RETIREMENT_FAULT_STATE="$root/.retirement-fault-fired" \
  SP11_REAL_STAT="$(command -v stat)" \
  SP11_REAL_MKTEMP="$(command -v mktemp)" \
  SP11_REAL_CHMOD="$(command -v chmod)" \
  SP11_REAL_CP="$(command -v cp)" \
  SP11_REAL_MV="$(command -v mv)" \
  PATH="$live_mock_bin:$PATH" \
    "$live_installer" --root "$root" --retire-loose-dtb-only > \
      "$output" 2>&1
}

expect_live_retirement_failure() {
  local root="$1" mode="$2" output="$3"

  if run_live_retirement "$root" "$mode" "$output"; then
    fail "live retirement fixture unexpectedly succeeded: $mode"
  fi
  grep -F 'DO NOT REBOOT. DO NOT RUN apt OR dpkg' "$output" >/dev/null ||
    fail "live retirement failure omitted the stop warning: $mode"
}

assert_no_false_complete_rollback() {
  local output="$1"

  if grep -F 'The prior managed leaves and GRUB state were restored.' \
    "$output" >/dev/null; then
    fail "obstructed rollback falsely claimed complete restoration"
  fi
  grep -F 'Rollback was obstructed;' "$output" >/dev/null ||
    fail "obstructed rollback omitted its incomplete-recovery message"
}

usr_escape_root="$test_parent/usr-parent-symlink-root"
usr_escape_victim_dir="$test_parent/usr-parent-symlink-victim"
usr_escape_victim="$usr_escape_victim_dir/sbin/sp11-grub-inject-dtb"
usr_escape_safe_postinst="$usr_escape_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
usr_escape_safe_postrm="$usr_escape_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
mkdir -p \
  "$usr_escape_root/usr" \
  "$(dirname "$usr_escape_safe_postinst")" \
  "$(dirname "$usr_escape_safe_postrm")" \
  "$(dirname "$usr_escape_victim")"
ln -s "$usr_escape_victim_dir" "$usr_escape_root/usr/local"
printf '%s\n' 'external helper victim' > "$usr_escape_victim"
printf '%s\n' 'safe managed postinst' > "$usr_escape_safe_postinst"
printf '%s\n' 'safe managed postrm' > "$usr_escape_safe_postrm"
chmod 0751 "$usr_escape_victim"
touch -t 202001020306.07 "$usr_escape_victim"
usr_escape_victim_before="$(file_fingerprint "$usr_escape_victim")"
usr_escape_link_before="$(link_fingerprint "$usr_escape_root/usr/local")"
usr_escape_postinst_before="$(file_fingerprint "$usr_escape_safe_postinst")"
usr_escape_postrm_before="$(file_fingerprint "$usr_escape_safe_postrm")"

expect_offline_installer_failure \
  "$usr_escape_root" "$test_parent/usr-parent-symlink.out" \
  --retire-loose-dtb-only
[ "$(file_fingerprint "$usr_escape_victim")" = "$usr_escape_victim_before" ] ||
  fail "usr/local parent escape changed external victim bytes or metadata"
[ "$(link_fingerprint "$usr_escape_root/usr/local")" = "$usr_escape_link_before" ] ||
  fail "usr/local parent escape changed the target symlink"
[ "$(file_fingerprint "$usr_escape_safe_postinst")" = "$usr_escape_postinst_before" ] ||
  fail "usr/local parent escape mutated the safe postinst artifact before failure"
[ "$(file_fingerprint "$usr_escape_safe_postrm")" = "$usr_escape_postrm_before" ] ||
  fail "usr/local parent escape mutated the safe postrm artifact before failure"

etc_escape_root="$test_parent/etc-parent-symlink-root"
etc_escape_victim_dir="$test_parent/etc-parent-symlink-victim"
etc_escape_postinst="$etc_escape_victim_dir/postinst.d/zzzz-surface-pro-11-dtb"
etc_escape_postrm="$etc_escape_victim_dir/postrm.d/zzzz-surface-pro-11-dtb"
etc_escape_safe_helper="$etc_escape_root/usr/local/sbin/sp11-grub-inject-dtb"
mkdir -p \
  "$etc_escape_root/etc" \
  "$(dirname "$etc_escape_safe_helper")" \
  "$(dirname "$etc_escape_postinst")" \
  "$(dirname "$etc_escape_postrm")"
ln -s "$etc_escape_victim_dir" "$etc_escape_root/etc/kernel"
printf '%s\n' 'external postinst victim' > "$etc_escape_postinst"
printf '%s\n' 'external postrm victim' > "$etc_escape_postrm"
printf '%s\n' 'safe managed helper' > "$etc_escape_safe_helper"
chmod 0751 "$etc_escape_postinst" "$etc_escape_postrm"
touch -t 202001020307.08 "$etc_escape_postinst" "$etc_escape_postrm"
etc_escape_postinst_before="$(file_fingerprint "$etc_escape_postinst")"
etc_escape_postrm_before="$(file_fingerprint "$etc_escape_postrm")"
etc_escape_link_before="$(link_fingerprint "$etc_escape_root/etc/kernel")"
etc_escape_helper_before="$(file_fingerprint "$etc_escape_safe_helper")"

expect_offline_installer_failure \
  "$etc_escape_root" "$test_parent/etc-parent-symlink.out" \
  --retire-loose-dtb-only
[ "$(file_fingerprint "$etc_escape_postinst")" = "$etc_escape_postinst_before" ] ||
  fail "etc/kernel parent escape changed the external postinst victim"
[ "$(file_fingerprint "$etc_escape_postrm")" = "$etc_escape_postrm_before" ] ||
  fail "etc/kernel parent escape changed the external postrm victim"
[ "$(link_fingerprint "$etc_escape_root/etc/kernel")" = "$etc_escape_link_before" ] ||
  fail "etc/kernel parent escape changed the target symlink"
[ "$(file_fingerprint "$etc_escape_safe_helper")" = "$etc_escape_helper_before" ] ||
  fail "etc/kernel parent escape mutated the safe helper before failure"

leaf_escape_root="$test_parent/managed-leaf-symlink-root"
leaf_escape_victim="$test_parent/managed-leaf-symlink-victim"
leaf_escape_link="$leaf_escape_root/usr/local/sbin/sp11-grab-fw"
leaf_escape_helper="$leaf_escape_root/usr/local/sbin/sp11-grub-inject-dtb"
leaf_escape_postinst="$leaf_escape_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
leaf_escape_postrm="$leaf_escape_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
mkdir -p \
  "$(dirname "$leaf_escape_link")" \
  "$(dirname "$leaf_escape_postinst")" \
  "$(dirname "$leaf_escape_postrm")"
printf '%s\n' 'external managed-file leaf victim' > "$leaf_escape_victim"
chmod 0641 "$leaf_escape_victim"
touch -t 202001020308.09 "$leaf_escape_victim"
ln -s "$leaf_escape_victim" "$leaf_escape_link"
printf '%s\n' 'managed helper must survive preflight' > "$leaf_escape_helper"
printf '%s\n' 'managed postinst must survive preflight' > "$leaf_escape_postinst"
printf '%s\n' 'managed postrm must survive preflight' > "$leaf_escape_postrm"
leaf_escape_victim_before="$(file_fingerprint "$leaf_escape_victim")"
leaf_escape_link_before="$(link_fingerprint "$leaf_escape_link")"
leaf_escape_helper_before="$(file_fingerprint "$leaf_escape_helper")"
leaf_escape_postinst_before="$(file_fingerprint "$leaf_escape_postinst")"
leaf_escape_postrm_before="$(file_fingerprint "$leaf_escape_postrm")"

expect_offline_installer_failure \
  "$leaf_escape_root" "$test_parent/managed-leaf-symlink.out" \
  --installed-system
[ "$(file_fingerprint "$leaf_escape_victim")" = "$leaf_escape_victim_before" ] ||
  fail "managed-file leaf escape changed external victim bytes or metadata"
[ "$(link_fingerprint "$leaf_escape_link")" = "$leaf_escape_link_before" ] ||
  fail "managed-file leaf escape changed the target symlink"
[ "$(file_fingerprint "$leaf_escape_helper")" = "$leaf_escape_helper_before" ] ||
  fail "managed-file leaf escape retired the helper before full-install preflight"
[ "$(file_fingerprint "$leaf_escape_postinst")" = "$leaf_escape_postinst_before" ] ||
  fail "managed-file leaf escape retired postinst before full-install preflight"
[ "$(file_fingerprint "$leaf_escape_postrm")" = "$leaf_escape_postrm_before" ] ||
  fail "managed-file leaf escape retired postrm before full-install preflight"
assert_absent "$leaf_escape_root/etc/default/grub.d/99-surface-pro-11.cfg"
assert_absent "$leaf_escape_root/etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup"

# The three systemd links are managed as symlinks. Existing regular files,
# directories, or special nodes must stop the full install before retirement.
managed_link_rel_paths=(
  etc/systemd/system/alsa-restore.service
  etc/systemd/system/alsa-state.service
  etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service
)
for collision_type in regular directory fifo; do
  for collision_index in 0 1 2; do
    link_root="$test_parent/managed-link-$collision_type-$collision_index"
    link_helper="$link_root/usr/local/sbin/sp11-grub-inject-dtb"
    link_postinst="$link_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
    link_postrm="$link_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
    collision_path="$link_root/${managed_link_rel_paths[$collision_index]}"
    mkdir -p \
      "$(dirname "$link_helper")" \
      "$(dirname "$link_postinst")" \
      "$(dirname "$link_postrm")" \
      "$(dirname "$collision_path")"
    printf '%s\n' 'managed helper must survive link preflight' > "$link_helper"
    printf '%s\n' 'managed postinst must survive link preflight' > "$link_postinst"
    printf '%s\n' 'managed postrm must survive link preflight' > "$link_postrm"
    case "$collision_type" in
      regular) printf '%s\n' 'unexpected regular link leaf' > "$collision_path" ;;
      directory) mkdir "$collision_path" ;;
      fifo) mkfifo "$collision_path" ;;
    esac

    link_helper_before="$(file_fingerprint "$link_helper")"
    link_postinst_before="$(file_fingerprint "$link_postinst")"
    link_postrm_before="$(file_fingerprint "$link_postrm")"
    collision_before="$(node_fingerprint "$collision_path")"

    expect_offline_installer_failure \
      "$link_root" \
      "$test_parent/managed-link-$collision_type-$collision_index.out" \
      --installed-system

    [ "$(file_fingerprint "$link_helper")" = "$link_helper_before" ] ||
      fail "managed-link preflight retired the helper before failure"
    [ "$(file_fingerprint "$link_postinst")" = "$link_postinst_before" ] ||
      fail "managed-link preflight retired postinst before failure"
    [ "$(file_fingerprint "$link_postrm")" = "$link_postrm_before" ] ||
      fail "managed-link preflight retired postrm before failure"
    [ "$(node_fingerprint "$collision_path")" = "$collision_before" ] ||
      fail "managed-link preflight changed the collision node"
  done
done

# Retirement is a preflighted three-file transaction. A directory or FIFO at
# any one of the exact managed paths must preserve all three nodes unchanged.
retirement_rel_paths=(
  usr/local/sbin/sp11-grub-inject-dtb
  etc/kernel/postinst.d/zzzz-surface-pro-11-dtb
  etc/kernel/postrm.d/zzzz-surface-pro-11-dtb
)
for unexpected_type in directory fifo; do
  for unexpected_index in 0 1 2; do
    unexpected_root="$test_parent/retirement-$unexpected_type-$unexpected_index"
    retirement_paths=()
    retirement_before=()
    for path_index in 0 1 2; do
      managed_path="$unexpected_root/${retirement_rel_paths[$path_index]}"
      retirement_paths+=("$managed_path")
      mkdir -p "$(dirname "$managed_path")"
      printf 'managed retirement fixture %s\n' "$path_index" > "$managed_path"
      chmod 0750 "$managed_path"
    done

    unexpected_path="${retirement_paths[$unexpected_index]}"
    rm -f -- "$unexpected_path"
    case "$unexpected_type" in
      directory) mkdir "$unexpected_path" ;;
      fifo) mkfifo "$unexpected_path" ;;
    esac

    for path_index in 0 1 2; do
      if [ "$path_index" -eq "$unexpected_index" ]; then
        retirement_before[$path_index]="$(node_fingerprint "${retirement_paths[$path_index]}")"
      else
        retirement_before[$path_index]="$(file_fingerprint "${retirement_paths[$path_index]}")"
      fi
    done

    expect_offline_installer_failure \
      "$unexpected_root" \
      "$test_parent/retirement-$unexpected_type-$unexpected_index.out" \
      --retire-loose-dtb-only

    for path_index in 0 1 2; do
      if [ "$path_index" -eq "$unexpected_index" ]; then
        [ "$(node_fingerprint "${retirement_paths[$path_index]}")" = \
          "${retirement_before[$path_index]}" ] ||
          fail "retirement preflight changed an unexpected $unexpected_type node"
      else
        [ "$(file_fingerprint "${retirement_paths[$path_index]}")" = \
          "${retirement_before[$path_index]}" ] ||
          fail "retirement preflight partially removed a managed regular file"
      fi
    done
  done
done

retire_root="$test_parent/retire-only-root"
retire_helper="$retire_root/usr/local/sbin/sp11-grub-inject-dtb"
retire_postinst="$retire_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
retire_postrm="$retire_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
retire_unrelated_helper="$retire_root/usr/local/sbin/sp11-grub-inject-dtb.local"
retire_unrelated_postinst="$retire_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb.local"
retire_unrelated_postrm="$retire_root/etc/kernel/postrm.d/zzzz-surface-pro-11-other"
retire_legacy_dtb="$retire_root/boot/sp11-denali.dtb"
retire_grub_cfg="$retire_root/boot/grub/grub.cfg"
retire_grub_defaults="$retire_root/etc/default/grub.d/99-surface-pro-11.cfg"
retire_apt_hook="$retire_root/etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup"
retire_support_helper="$retire_root/usr/local/sbin/sp11-grab-fw"
retire_systemd_link="$retire_root/etc/systemd/system/alsa-restore.service"

mkdir -p \
  "$retire_root/etc" \
  "$(dirname "$retire_helper")" \
  "$(dirname "$retire_postinst")" \
  "$(dirname "$retire_postrm")" \
  "$(dirname "$retire_grub_cfg")" \
  "$(dirname "$retire_grub_defaults")" \
  "$(dirname "$retire_apt_hook")" \
  "$(dirname "$retire_systemd_link")"

printf '%s\n' 'managed helper' > "$retire_helper"
printf '%s\n' 'managed postinst hook' > "$retire_postinst"
printf '%s\n' 'managed postrm hook' > "$retire_postrm"
printf '%s\n' 'unrelated helper' > "$retire_unrelated_helper"
printf '%s\n' 'unrelated postinst hook' > "$retire_unrelated_postinst"
printf '%s\n' 'unrelated postrm hook' > "$retire_unrelated_postrm"
printf '%s\n' 'existing GRUB defaults' > "$retire_grub_defaults"
printf '%s\n' 'existing apt hook' > "$retire_apt_hook"
printf '%s\n' 'existing support helper' > "$retire_support_helper"
chmod 0755 \
  "$retire_helper" "$retire_postinst" "$retire_postrm" \
  "$retire_unrelated_helper" "$retire_unrelated_postinst" \
  "$retire_unrelated_postrm" "$retire_support_helper"
ln -s /dev/null "$retire_systemd_link"

printf '%s\n' 'legacy loose DTB recovery evidence' > "$retire_legacy_dtb"
chmod 0600 "$retire_legacy_dtb"
touch -t 202001020304.05 "$retire_legacy_dtb"

printf '%s\n' \
  "menuentry 'historical fallback' {" \
  '  linux /vmlinuz-fallback' \
  '  devicetree /sp11-denali.dtb' \
  '}' > "$retire_grub_cfg"
chmod 0640 "$retire_grub_cfg"
touch -t 202001020305.06 "$retire_grub_cfg"

retire_tree_before="$(tree_snapshot_excluding_managed "$retire_root")"
retire_dtb_before="$(file_fingerprint "$retire_legacy_dtb")"
retire_grub_before="$(file_fingerprint "$retire_grub_cfg")"

run_offline_installer "$retire_root" --retire-loose-dtb-only > \
  "$test_parent/retire-only.out"

assert_absent "$retire_helper"
assert_absent "$retire_postinst"
assert_absent "$retire_postrm"
assert_present "$retire_unrelated_helper"
assert_present "$retire_unrelated_postinst"
assert_present "$retire_unrelated_postrm"
[ "$(file_fingerprint "$retire_legacy_dtb")" = "$retire_dtb_before" ] ||
  fail "retire-only mode changed the legacy loose DTB"
[ "$(file_fingerprint "$retire_grub_cfg")" = "$retire_grub_before" ] ||
  fail "offline retire-only mode changed grub.cfg"
[ "$(tree_snapshot_excluding_managed "$retire_root")" = "$retire_tree_before" ] ||
  fail "retire-only mode changed files outside the three managed paths"
[ ! -e "$tripwire" ] || fail "offline retire-only mode invoked update-grub"
grep -F 'Retired installed loose-DTB integration in ' \
  "$test_parent/retire-only.out" >/dev/null
if grep -F 'Installed Surface Pro 11 support helpers into ' \
  "$test_parent/retire-only.out" >/dev/null; then
  fail "retire-only mode continued into full support installation"
fi

empty_retire_root="$test_parent/empty-retire-only-root"
mkdir -p "$empty_retire_root"
run_offline_installer "$empty_retire_root" --retire-loose-dtb-only > \
  "$test_parent/empty-retire-only.out"
assert_absent "$empty_retire_root/usr/local/sbin/sp11-grub-inject-dtb"
assert_absent \
  "$empty_retire_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
assert_absent \
  "$empty_retire_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
assert_absent "$empty_retire_root/boot/sp11-denali.dtb"
assert_no_retirement_backups "$empty_retire_root"
[ ! -e "$tripwire" ] ||
  fail "artifact-free offline retirement invoked update-grub"

live_success_root="$test_parent/live-success-root"
prepare_live_retirement_root "$live_success_root"
live_success_dtb_before="$(
  file_fingerprint "$live_success_root/boot/sp11-denali.dtb"
)"
live_success_grubenv_before="$(
  file_fingerprint "$live_success_root/boot/grub/grubenv"
)"
run_live_retirement \
  "$live_success_root" success "$test_parent/live-success.out"
assert_absent "$live_success_root/usr/local/sbin/sp11-grub-inject-dtb"
assert_absent \
  "$live_success_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
assert_absent \
  "$live_success_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
[ "$(file_fingerprint "$live_success_root/boot/sp11-denali.dtb")" = \
  "$live_success_dtb_before" ] ||
  fail "successful retirement changed historical loose-DTB identity"
[ "$(file_fingerprint "$live_success_root/boot/grub/grubenv")" = \
  "$live_success_grubenv_before" ] ||
  fail "successful retirement changed grubenv identity"
grep -F 'generated embedded-DTB kernel' \
  "$live_success_root/boot/grub/grub.cfg" >/dev/null ||
  fail "successful retirement did not retain generated grub.cfg"
if grep -E '^[[:space:]]*devicetree[[:space:]]+.*/sp11-denali\.dtb' \
  "$live_success_root/boot/grub/grub.cfg" >/dev/null; then
  fail "successful retirement retained the loose-DTB GRUB reference"
fi
assert_no_retirement_backups "$live_success_root"
grep -F 'Retired installed loose-DTB integration in ' \
  "$test_parent/live-success.out" >/dev/null ||
  fail "successful live retirement omitted its completion message"

for prepare_failure_mode in \
  prepare-stat-failure \
  prepare-mktemp-failure \
  prepare-chmod-failure; do
  prepare_failure_root="$test_parent/$prepare_failure_mode-root"
  prepare_live_retirement_root "$prepare_failure_root"
  prepare_failure_before="$(
    live_retirement_state_fingerprint "$prepare_failure_root"
  )"
  expect_live_retirement_failure \
    "$prepare_failure_root" "$prepare_failure_mode" \
    "$test_parent/$prepare_failure_mode.out"
  [ "$(live_retirement_state_fingerprint "$prepare_failure_root")" = \
    "$prepare_failure_before" ] ||
    fail "$prepare_failure_mode changed the pre-transaction files"
  assert_no_retirement_backups "$prepare_failure_root"
  if [ "$prepare_failure_mode" = "prepare-stat-failure" ]; then
    assert_no_false_complete_rollback \
      "$test_parent/$prepare_failure_mode.out"
  else
    grep -F 'The prior managed leaves and GRUB state were restored.' \
      "$test_parent/$prepare_failure_mode.out" >/dev/null ||
      fail "$prepare_failure_mode did not report its unchanged state"
  fi
done

live_pre_stage_root="$test_parent/live-pre-stage-replacement-root"
prepare_live_retirement_root "$live_pre_stage_root"
live_pre_stage_helper_original="$(file_preservation_fingerprint \
  "$live_pre_stage_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_pre_stage_postinst_before="$(file_fingerprint \
  "$live_pre_stage_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_pre_stage_postrm_before="$(file_fingerprint \
  "$live_pre_stage_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_pre_stage_cfg_before="$(file_fingerprint \
  "$live_pre_stage_root/boot/grub/grub.cfg")"
live_pre_stage_dtb_before="$(file_fingerprint \
  "$live_pre_stage_root/boot/sp11-denali.dtb")"
live_pre_stage_grubenv_before="$(file_fingerprint \
  "$live_pre_stage_root/boot/grub/grubenv")"
expect_live_retirement_failure \
  "$live_pre_stage_root" pre-stage-concurrent-replacement \
  "$test_parent/live-pre-stage-replacement.out"
[ "$(file_preservation_fingerprint \
  "$live_pre_stage_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_pre_stage_helper_original" ] ||
  fail "pre-stage rollback did not restore the original managed helper"
[ "$(file_fingerprint \
  "$live_pre_stage_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_pre_stage_postinst_before" ] ||
  fail "pre-stage rollback changed the postinst hook"
[ "$(file_fingerprint \
  "$live_pre_stage_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_pre_stage_postrm_before" ] ||
  fail "pre-stage rollback changed the postrm hook"
[ "$(file_fingerprint "$live_pre_stage_root/boot/grub/grub.cfg")" = \
  "$live_pre_stage_cfg_before" ] ||
  fail "pre-stage rollback changed grub.cfg"
[ "$(file_fingerprint "$live_pre_stage_root/boot/sp11-denali.dtb")" = \
  "$live_pre_stage_dtb_before" ] ||
  fail "pre-stage rollback changed the historical loose DTB"
[ "$(file_fingerprint "$live_pre_stage_root/boot/grub/grubenv")" = \
  "$live_pre_stage_grubenv_before" ] ||
  fail "pre-stage rollback changed grubenv"
assert_single_recovery_backup \
  "$live_pre_stage_root" "$live_pre_stage_root/usr/local/sbin" \
  "$live_pre_stage_helper_original"
assert_single_recovery_occupant \
  "$live_pre_stage_root" "$live_pre_stage_root/usr/local/sbin" \
  'pre-stage concurrent managed-leaf occupant'
assert_no_false_complete_rollback \
  "$test_parent/live-pre-stage-replacement.out"

live_grub_pre_stage_root="$test_parent/live-grub-pre-stage-replacement-root"
prepare_live_retirement_root "$live_grub_pre_stage_root"
live_grub_pre_stage_cfg_original="$(file_preservation_fingerprint \
  "$live_grub_pre_stage_root/boot/grub/grub.cfg")"
live_grub_pre_stage_helper_before="$(file_fingerprint \
  "$live_grub_pre_stage_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_grub_pre_stage_postinst_before="$(file_fingerprint \
  "$live_grub_pre_stage_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_grub_pre_stage_postrm_before="$(file_fingerprint \
  "$live_grub_pre_stage_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_grub_pre_stage_dtb_before="$(file_fingerprint \
  "$live_grub_pre_stage_root/boot/sp11-denali.dtb")"
live_grub_pre_stage_grubenv_before="$(file_fingerprint \
  "$live_grub_pre_stage_root/boot/grub/grubenv")"
expect_live_retirement_failure \
  "$live_grub_pre_stage_root" grub-cfg-pre-stage-replacement \
  "$test_parent/live-grub-pre-stage-replacement.out"
[ "$(file_preservation_fingerprint \
  "$live_grub_pre_stage_root/boot/grub/grub.cfg")" = \
  "$live_grub_pre_stage_cfg_original" ] ||
  fail "grub.cfg pre-stage rollback did not restore the original grub.cfg"
[ "$(file_fingerprint \
  "$live_grub_pre_stage_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_grub_pre_stage_helper_before" ] ||
  fail "grub.cfg pre-stage rollback changed the managed helper"
[ "$(file_fingerprint \
  "$live_grub_pre_stage_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_grub_pre_stage_postinst_before" ] ||
  fail "grub.cfg pre-stage rollback changed the postinst hook"
[ "$(file_fingerprint \
  "$live_grub_pre_stage_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_grub_pre_stage_postrm_before" ] ||
  fail "grub.cfg pre-stage rollback changed the postrm hook"
[ "$(file_fingerprint \
  "$live_grub_pre_stage_root/boot/sp11-denali.dtb")" = \
  "$live_grub_pre_stage_dtb_before" ] ||
  fail "grub.cfg pre-stage rollback changed the historical loose DTB"
[ "$(file_fingerprint \
  "$live_grub_pre_stage_root/boot/grub/grubenv")" = \
  "$live_grub_pre_stage_grubenv_before" ] ||
  fail "grub.cfg pre-stage rollback changed grubenv"
assert_single_recovery_backup \
  "$live_grub_pre_stage_root" "$live_grub_pre_stage_root/boot/grub" \
  "$live_grub_pre_stage_cfg_original"
assert_single_recovery_occupant \
  "$live_grub_pre_stage_root" "$live_grub_pre_stage_root/boot/grub" \
  'pre-stage concurrent grub.cfg occupant'
assert_no_false_complete_rollback \
  "$test_parent/live-grub-pre-stage-replacement.out"

for move_failure_mode in move-then-fail signal-after-move; do
  move_failure_root="$test_parent/$move_failure_mode-root"
  prepare_live_retirement_root "$move_failure_root"
  move_failure_before="$(
    live_retirement_state_fingerprint "$move_failure_root"
  )"
  expect_live_retirement_failure \
    "$move_failure_root" "$move_failure_mode" \
    "$test_parent/$move_failure_mode.out"
  [ "$(live_retirement_state_fingerprint "$move_failure_root")" = \
    "$move_failure_before" ] ||
    fail "$move_failure_mode did not restore exact pre-transaction state"
  assert_no_retirement_backups "$move_failure_root"
  grep -F 'The prior managed leaves and GRUB state were restored.' \
    "$test_parent/$move_failure_mode.out" >/dev/null ||
    fail "$move_failure_mode did not report complete rollback"
done

for grub_move_failure_mode in \
  grub-cfg-move-then-fail \
  grub-cfg-signal-after-move; do
  grub_move_failure_root="$test_parent/$grub_move_failure_mode-root"
  prepare_live_retirement_root "$grub_move_failure_root"
  grub_move_failure_before="$(
    live_retirement_state_fingerprint "$grub_move_failure_root"
  )"
  expect_live_retirement_failure \
    "$grub_move_failure_root" "$grub_move_failure_mode" \
    "$test_parent/$grub_move_failure_mode.out"
  [ "$(live_retirement_state_fingerprint "$grub_move_failure_root")" = \
    "$grub_move_failure_before" ] ||
    fail "$grub_move_failure_mode did not restore exact pre-transaction state"
  assert_no_retirement_backups "$grub_move_failure_root"
  grep -F 'The prior managed leaves and GRUB state were restored.' \
    "$test_parent/$grub_move_failure_mode.out" >/dev/null ||
      fail "$grub_move_failure_mode did not report complete rollback"
done

for rollback_cfg_race_mode in \
  rollback-replace-original-grub \
  rollback-replace-generated-grub; do
  rollback_cfg_race_root="$test_parent/$rollback_cfg_race_mode-root"
  prepare_live_retirement_root "$rollback_cfg_race_root"
  rollback_cfg_race_original="$(file_preservation_fingerprint \
    "$rollback_cfg_race_root/boot/grub/grub.cfg")"
  expect_live_retirement_failure \
    "$rollback_cfg_race_root" "$rollback_cfg_race_mode" \
    "$test_parent/$rollback_cfg_race_mode.out"
  [ "$(file_preservation_fingerprint \
    "$rollback_cfg_race_root/boot/grub/grub.cfg")" = \
    "$rollback_cfg_race_original" ] ||
    fail "$rollback_cfg_race_mode did not restore the original grub.cfg"
  assert_single_recovery_backup \
    "$rollback_cfg_race_root" "$rollback_cfg_race_root/boot/grub" \
    "$rollback_cfg_race_original"
  assert_single_recovery_occupant \
    "$rollback_cfg_race_root" "$rollback_cfg_race_root/boot/grub" \
    "rollback-time concurrent grub.cfg occupant: $rollback_cfg_race_mode"
  assert_no_false_complete_rollback \
    "$test_parent/$rollback_cfg_race_mode.out"
done

rollback_managed_race_root="$test_parent/rollback-managed-current-root"
prepare_live_retirement_root "$rollback_managed_race_root"
rollback_managed_race_original="$(file_preservation_fingerprint \
  "$rollback_managed_race_root/usr/local/sbin/sp11-grub-inject-dtb")"
expect_live_retirement_failure \
  "$rollback_managed_race_root" rollback-replace-managed-current \
  "$test_parent/rollback-managed-current.out"
[ "$(file_preservation_fingerprint \
  "$rollback_managed_race_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$rollback_managed_race_original" ] ||
  fail "rollback-time managed replacement did not restore the original helper"
assert_single_recovery_backup \
  "$rollback_managed_race_root" \
  "$rollback_managed_race_root/usr/local/sbin" \
  "$rollback_managed_race_original"
assert_single_recovery_occupant \
  "$rollback_managed_race_root" \
  "$rollback_managed_race_root/usr/local/sbin" \
  'rollback-time concurrent managed-leaf occupant'
assert_no_false_complete_rollback \
  "$test_parent/rollback-managed-current.out"

rollback_monitored_race_root="$test_parent/rollback-monitored-current-root"
prepare_live_retirement_root "$rollback_monitored_race_root"
rollback_monitored_race_original="$(file_preservation_fingerprint \
  "$rollback_monitored_race_root/boot/grub/grubenv")"
expect_live_retirement_failure \
  "$rollback_monitored_race_root" rollback-replace-monitored-current \
  "$test_parent/rollback-monitored-current.out"
[ "$(file_preservation_fingerprint \
  "$rollback_monitored_race_root/boot/grub/grubenv")" = \
  "$rollback_monitored_race_original" ] ||
  fail "rollback-time grubenv replacement did not restore original grubenv"
assert_single_recovery_backup \
  "$rollback_monitored_race_root" \
  "$rollback_monitored_race_root/boot/grub" \
  "$rollback_monitored_race_original"
assert_single_recovery_occupant \
  "$rollback_monitored_race_root" \
  "$rollback_monitored_race_root/boot/grub" \
  'rollback-time concurrent grubenv occupant'
assert_no_false_complete_rollback \
  "$test_parent/rollback-monitored-current.out"

live_update_failure_root="$test_parent/live-update-failure-root"
prepare_live_retirement_root "$live_update_failure_root"
live_update_helper_before="$(file_fingerprint \
  "$live_update_failure_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_update_postinst_before="$(file_fingerprint \
  "$live_update_failure_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_update_postrm_before="$(file_fingerprint \
  "$live_update_failure_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_update_cfg_before="$(file_fingerprint \
  "$live_update_failure_root/boot/grub/grub.cfg")"
live_update_dtb_before="$(file_fingerprint \
  "$live_update_failure_root/boot/sp11-denali.dtb")"
live_update_grubenv_before="$(file_fingerprint \
  "$live_update_failure_root/boot/grub/grubenv")"
expect_live_retirement_failure \
  "$live_update_failure_root" update-grub-failure \
  "$test_parent/live-update-failure.out"
[ "$(file_fingerprint \
  "$live_update_failure_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_update_helper_before" ] ||
  fail "update-grub failure did not restore the exact managed helper"
[ "$(file_fingerprint \
  "$live_update_failure_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_update_postinst_before" ] ||
  fail "update-grub failure did not restore the exact postinst hook"
[ "$(file_fingerprint \
  "$live_update_failure_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_update_postrm_before" ] ||
  fail "update-grub failure did not restore the exact postrm hook"
[ "$(file_fingerprint \
  "$live_update_failure_root/boot/grub/grub.cfg")" = \
  "$live_update_cfg_before" ] ||
  fail "update-grub failure did not restore exact prior grub.cfg"
[ "$(file_fingerprint "$live_update_failure_root/boot/sp11-denali.dtb")" = \
  "$live_update_dtb_before" ] ||
  fail "update-grub failure changed the historical loose DTB"
[ "$(file_fingerprint "$live_update_failure_root/boot/grub/grubenv")" = \
  "$live_update_grubenv_before" ] ||
  fail "update-grub failure changed grubenv"
assert_no_retirement_backups "$live_update_failure_root"

live_postcheck_root="$test_parent/live-postcheck-failure-root"
prepare_live_retirement_root "$live_postcheck_root"
live_postcheck_helper_before="$(file_fingerprint \
  "$live_postcheck_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_postcheck_postinst_before="$(file_fingerprint \
  "$live_postcheck_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_postcheck_postrm_before="$(file_fingerprint \
  "$live_postcheck_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_postcheck_cfg_before="$(file_fingerprint \
  "$live_postcheck_root/boot/grub/grub.cfg")"
expect_live_retirement_failure \
  "$live_postcheck_root" postcheck-failure \
  "$test_parent/live-postcheck-failure.out"
[ "$(file_fingerprint \
  "$live_postcheck_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_postcheck_helper_before" ] ||
  fail "postcheck failure did not restore the exact managed helper"
[ "$(file_fingerprint \
  "$live_postcheck_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_postcheck_postinst_before" ] ||
  fail "postcheck failure did not restore the exact postinst hook"
[ "$(file_fingerprint \
  "$live_postcheck_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_postcheck_postrm_before" ] ||
  fail "postcheck failure did not restore the exact postrm hook"
[ "$(file_fingerprint "$live_postcheck_root/boot/grub/grub.cfg")" = \
  "$live_postcheck_cfg_before" ] ||
  fail "postcheck failure did not restore exact prior grub.cfg"
assert_no_retirement_backups "$live_postcheck_root"

live_trailing_postcheck_root="$test_parent/live-trailing-postcheck-root"
prepare_live_retirement_root "$live_trailing_postcheck_root"
live_trailing_postcheck_before="$(
  live_retirement_state_fingerprint "$live_trailing_postcheck_root"
)"
expect_live_retirement_failure \
  "$live_trailing_postcheck_root" trailing-space-postcheck-failure \
  "$test_parent/live-trailing-postcheck.out"
[ "$(live_retirement_state_fingerprint "$live_trailing_postcheck_root")" = \
  "$live_trailing_postcheck_before" ] ||
  fail "trailing-space GRUB postcheck did not restore exact prior state"
assert_no_retirement_backups "$live_trailing_postcheck_root"
grep -F 'Generated grub.cfg still contains the project-managed loose-DTB reference.' \
  "$test_parent/live-trailing-postcheck.out" >/dev/null ||
  fail "trailing-space loose-DTB line evaded the generated GRUB postcheck"

live_dtb_mutation_root="$test_parent/live-dtb-mutation-root"
prepare_live_retirement_root "$live_dtb_mutation_root"
live_dtb_mutation_original="$(file_preservation_fingerprint \
  "$live_dtb_mutation_root/boot/sp11-denali.dtb")"
live_dtb_mutation_helper_before="$(file_fingerprint \
  "$live_dtb_mutation_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_dtb_mutation_postinst_before="$(file_fingerprint \
  "$live_dtb_mutation_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_dtb_mutation_postrm_before="$(file_fingerprint \
  "$live_dtb_mutation_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_dtb_mutation_cfg_before="$(file_fingerprint \
  "$live_dtb_mutation_root/boot/grub/grub.cfg")"
expect_live_retirement_failure \
  "$live_dtb_mutation_root" historical-dtb-mutation \
  "$test_parent/live-dtb-mutation.out"
[ "$(file_preservation_fingerprint \
  "$live_dtb_mutation_root/boot/sp11-denali.dtb")" = \
  "$live_dtb_mutation_original" ] ||
  fail "historical-DTB mutation did not restore the original loose DTB"
[ "$(file_fingerprint \
  "$live_dtb_mutation_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_dtb_mutation_helper_before" ] ||
  fail "historical-DTB mutation did not restore the exact managed helper"
[ "$(file_fingerprint \
  "$live_dtb_mutation_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_dtb_mutation_postinst_before" ] ||
  fail "historical-DTB mutation did not restore the exact postinst hook"
[ "$(file_fingerprint \
  "$live_dtb_mutation_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_dtb_mutation_postrm_before" ] ||
  fail "historical-DTB mutation did not restore the exact postrm hook"
[ "$(file_fingerprint "$live_dtb_mutation_root/boot/grub/grub.cfg")" = \
  "$live_dtb_mutation_cfg_before" ] ||
  fail "historical-DTB mutation did not restore exact prior grub.cfg"
assert_single_recovery_backup \
  "$live_dtb_mutation_root" "$live_dtb_mutation_root/boot" \
  "$live_dtb_mutation_original"
assert_single_recovery_occupant \
  "$live_dtb_mutation_root" "$live_dtb_mutation_root/boot" \
  'mutated loose DTB occupant'

live_grubenv_mutation_root="$test_parent/live-grubenv-mutation-root"
prepare_live_retirement_root "$live_grubenv_mutation_root"
live_grubenv_mutation_original="$(file_preservation_fingerprint \
  "$live_grubenv_mutation_root/boot/grub/grubenv")"
live_grubenv_mutation_helper_before="$(file_fingerprint \
  "$live_grubenv_mutation_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_grubenv_mutation_cfg_before="$(file_fingerprint \
  "$live_grubenv_mutation_root/boot/grub/grub.cfg")"
expect_live_retirement_failure \
  "$live_grubenv_mutation_root" grubenv-mutation \
  "$test_parent/live-grubenv-mutation.out"
[ "$(file_preservation_fingerprint \
  "$live_grubenv_mutation_root/boot/grub/grubenv")" = \
  "$live_grubenv_mutation_original" ] ||
  fail "grubenv mutation did not restore the original grubenv"
[ "$(file_fingerprint \
  "$live_grubenv_mutation_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_grubenv_mutation_helper_before" ] ||
  fail "grubenv mutation did not restore the exact managed helper"
[ "$(file_fingerprint "$live_grubenv_mutation_root/boot/grub/grub.cfg")" = \
  "$live_grubenv_mutation_cfg_before" ] ||
  fail "grubenv mutation did not restore exact prior grub.cfg"
assert_single_recovery_backup \
  "$live_grubenv_mutation_root" "$live_grubenv_mutation_root/boot/grub" \
  "$live_grubenv_mutation_original"
assert_single_recovery_occupant \
  "$live_grubenv_mutation_root" "$live_grubenv_mutation_root/boot/grub" \
  'saved_entry=changed-by-update-grub'

live_occupied_root="$test_parent/live-occupied-root"
prepare_live_retirement_root "$live_occupied_root"
live_occupied_helper_original="$(file_preservation_fingerprint \
  "$live_occupied_root/usr/local/sbin/sp11-grub-inject-dtb")"
live_occupied_postinst_before="$(file_fingerprint \
  "$live_occupied_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")"
live_occupied_postrm_before="$(file_fingerprint \
  "$live_occupied_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")"
live_occupied_cfg_before="$(file_fingerprint \
  "$live_occupied_root/boot/grub/grub.cfg")"
expect_live_retirement_failure \
  "$live_occupied_root" occupied-destination \
  "$test_parent/live-occupied.out"
[ "$(file_preservation_fingerprint \
  "$live_occupied_root/usr/local/sbin/sp11-grub-inject-dtb")" = \
  "$live_occupied_helper_original" ] ||
  fail "occupied-destination rollback did not restore the original helper"
[ "$(file_fingerprint \
  "$live_occupied_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb")" = \
  "$live_occupied_postinst_before" ] ||
  fail "occupied-destination rollback did not restore exact postinst hook"
[ "$(file_fingerprint \
  "$live_occupied_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb")" = \
  "$live_occupied_postrm_before" ] ||
  fail "occupied-destination rollback did not restore exact postrm hook"
[ "$(file_fingerprint "$live_occupied_root/boot/grub/grub.cfg")" = \
  "$live_occupied_cfg_before" ] ||
  fail "occupied-destination rollback did not restore exact prior grub.cfg"
assert_single_recovery_backup \
  "$live_occupied_root" "$live_occupied_root/usr/local/sbin" \
  "$live_occupied_helper_original"
assert_single_recovery_occupant \
  "$live_occupied_root" "$live_occupied_root/usr/local/sbin" \
  'concurrent managed-leaf occupant'

offline_root="$test_parent/root-with-dtb"
managed_helper="$offline_root/usr/local/sbin/sp11-grub-inject-dtb"
managed_postinst="$offline_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb"
managed_postrm="$offline_root/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb"
unrelated_helper="$offline_root/usr/local/sbin/sp11-grub-inject-dtb.local"
unrelated_postinst="$offline_root/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb.local"
unrelated_postrm="$offline_root/etc/kernel/postrm.d/zzzz-surface-pro-11-other"
legacy_dtb="$offline_root/boot/sp11-denali.dtb"
grub_cfg="$offline_root/boot/grub/grub.cfg"

mkdir -p \
  "$offline_root/etc" \
  "$(dirname "$managed_helper")" \
  "$(dirname "$managed_postinst")" \
  "$(dirname "$managed_postrm")" \
  "$(dirname "$grub_cfg")"

printf '%s\n' 'managed helper' > "$managed_helper"
printf '%s\n' 'managed postinst hook' > "$managed_postinst"
printf '%s\n' 'managed postrm hook' > "$managed_postrm"
printf '%s\n' 'unrelated helper' > "$unrelated_helper"
printf '%s\n' 'unrelated postinst hook' > "$unrelated_postinst"
printf '%s\n' 'unrelated postrm hook' > "$unrelated_postrm"
chmod 0755 \
  "$managed_helper" "$managed_postinst" "$managed_postrm" \
  "$unrelated_helper" "$unrelated_postinst" "$unrelated_postrm"

printf '%s\n' 'legacy loose DTB recovery evidence' > "$legacy_dtb"
chmod 0600 "$legacy_dtb"
touch -t 202001020304.05 "$legacy_dtb"

printf '%s\n' \
  "menuentry 'historical fallback' {" \
  '  linux /vmlinuz-fallback' \
  '  devicetree /sp11-denali.dtb' \
  '}' > "$grub_cfg"
chmod 0640 "$grub_cfg"
touch -t 202001020305.06 "$grub_cfg"

dtb_before="$(file_fingerprint "$legacy_dtb")"
grub_before="$(file_fingerprint "$grub_cfg")"

run_offline_installer "$offline_root" --installed-system > "$test_parent/first.out"

assert_absent "$managed_helper"
assert_absent "$managed_postinst"
assert_absent "$managed_postrm"
assert_present "$unrelated_helper"
assert_present "$unrelated_postinst"
assert_present "$unrelated_postrm"
[ "$(file_fingerprint "$legacy_dtb")" = "$dtb_before" ] ||
  fail "offline install changed the legacy loose DTB"
[ "$(file_fingerprint "$grub_cfg")" = "$grub_before" ] ||
  fail "offline install changed grub.cfg"
[ ! -e "$tripwire" ] || fail "offline install invoked update-grub"
grep -F 'Existing /boot/sp11-denali.dtb was left untouched as inert recovery evidence.' \
  "$test_parent/first.out" >/dev/null
grep -F 'GRUB regeneration deferred for offline target root; target grub.cfg was not modified.' \
  "$test_parent/first.out" >/dev/null

run_offline_installer "$offline_root/./" --installed-system > "$test_parent/second.out"

assert_absent "$managed_helper"
assert_absent "$managed_postinst"
assert_absent "$managed_postrm"
assert_present "$unrelated_helper"
assert_present "$unrelated_postinst"
assert_present "$unrelated_postrm"
[ "$(file_fingerprint "$legacy_dtb")" = "$dtb_before" ] ||
  fail "idempotent install changed the legacy loose DTB"
[ "$(file_fingerprint "$grub_cfg")" = "$grub_before" ] ||
  fail "idempotent install changed grub.cfg"
[ ! -e "$tripwire" ] || fail "idempotent offline install invoked update-grub"

empty_root="$test_parent/root-without-dtb"
mkdir -p "$empty_root/etc"
run_offline_installer "$empty_root" --installed-system > "$test_parent/empty.out"
assert_absent "$empty_root/boot/sp11-denali.dtb"
assert_absent "$empty_root/boot/grub/grub.cfg"
[ ! -e "$tripwire" ] || fail "DTB-absent offline install invoked update-grub"

"$installer" --help > "$test_parent/help.out"
grep -F 'Usage:' "$test_parent/help.out" >/dev/null
grep -F -- '--retire-loose-dtb-only' "$test_parent/help.out" >/dev/null

if "$installer" --root > "$test_parent/missing-root.out" 2>&1; then
  fail "installer accepted --root without a value"
else
  missing_root_status="$?"
fi
[ "$missing_root_status" -eq 2 ] || fail "missing --root value did not exit with status 2"
grep -F 'Missing value for --root.' "$test_parent/missing-root.out" >/dev/null

if "$installer" --installed-system --root relative-root > "$test_parent/relative.out" 2>&1; then
  fail "installer accepted a relative target root"
else
  relative_status="$?"
fi
[ "$relative_status" -eq 2 ] || fail "relative target root did not exit with status 2"
grep -F -- '--root must be an absolute path: relative-root' \
  "$test_parent/relative.out" >/dev/null

if ! awk '
  /^install_kernel_debs\(\) \{/ {
    in_function = 1
    next
  }
  in_function && /--retire-loose-dtb-only/ {
    if (saw_retire || saw_apt || saw_full_install) exit 1
    saw_retire = 1
    next
  }
  in_function && /as_root apt install --reinstall/ {
    if (!saw_retire || saw_apt || saw_full_install) exit 1
    saw_apt = 1
    next
  }
  in_function && /install-sp11-support\.sh.*--installed-system/ {
    if (!saw_retire || !saw_apt || saw_full_install) exit 1
    saw_full_install = 1
    next
  }
  in_function && /^}/ {
    found_end = 1
    exit !(saw_retire && saw_apt && saw_full_install)
  }
  END {
    if (!found_end) exit 1
  }
' "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh"; then
  fail "kernel install flow is not ordered retire-only, apt, then full support install"
fi

echo "Installed Stubble loose-DTB retirement passed."
