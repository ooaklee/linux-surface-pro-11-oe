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
