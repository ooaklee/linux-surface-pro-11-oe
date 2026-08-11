#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
preflight="$repo_dir/scripts/preflight-sp11-kernel-test.sh"

target_abi="7.2-rc5-jg-1100-qcom-x1e"
target_base="${target_abi%-qcom-x1e}"
fallback_abi="6.17.0-1008-qcom-x1e"
bundle_version="7.2-rc5-jg-1100.1"

expected_image="linux-image-$target_abi"
expected_modules="linux-modules-$target_abi"
expected_headers="linux-headers-$target_abi"
expected_common_headers="linux-qcom-x1e-headers-$target_base"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-kernel-preflight.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fake_dpkg_deb="$test_root/fake-dpkg-deb"
case_number=0
fixture=""
deb_dir=""
root_dir=""
case_target="$target_abi"
case_fallback="$fallback_abi"
case_running="$fallback_abi"
pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$fake_dpkg_deb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 3 ] && [ "$1" = "-f" ] || exit 2
file="$2"
field="$3"

awk -v key="$field=" '
  index($0, key) == 1 {
    print substr($0, length(key) + 1)
    found = 1
    exit
  }
  END { if (!found) exit 1 }
' "$file"
EOF
chmod +x "$fake_dpkg_deb"

write_deb() {
  local path="$1"
  local package="$2"
  local version="$3"
  local architecture="$4"
  local depends="$5"

  {
    printf 'Package=%s\n' "$package"
    printf 'Version=%s\n' "$version"
    printf 'Architecture=%s\n' "$architecture"
    printf 'Depends=%s\n' "$depends"
  } > "$path"
}

write_grub_entry() {
  local title="$1"
  local abi="$2"
  local path="$3"
  local menu_options="${4:-}"

  {
    printf "menuentry '%s'%s {\n" "$title" "$menu_options"
    printf '  linux /boot/vmlinuz-%s root=UUID=fixture ro\n' "$abi"
    printf '  initrd /boot/initrd.img-%s\n' "$abi"
    printf '}\n'
  } >> "$path"
}

make_fixture() {
  case_number=$((case_number + 1))
  fixture="$test_root/case-$case_number"
  deb_dir="$fixture/debs"
  root_dir="$fixture/root"
  case_target="$target_abi"
  case_fallback="$fallback_abi"
  case_running="$fallback_abi"

  mkdir -p \
    "$deb_dir" \
    "$root_dir/boot/grub" \
    "$root_dir/lib/modules/$fallback_abi/kernel/drivers"

  write_deb \
    "$deb_dir/${expected_image}_${bundle_version}_arm64.deb" \
    "$expected_image" "$bundle_version" arm64 \
    "kmod, linux-base (>= 4.5), $expected_modules"
  write_deb \
    "$deb_dir/${expected_modules}_${bundle_version}_arm64.deb" \
    "$expected_modules" "$bundle_version" arm64 \
    "wireless-regdb"
  write_deb \
    "$deb_dir/${expected_headers}_${bundle_version}_arm64.deb" \
    "$expected_headers" "$bundle_version" arm64 \
    "$expected_common_headers, libc6 (>= 2.38)"
  write_deb \
    "$deb_dir/${expected_common_headers}_${bundle_version}_all.deb" \
    "$expected_common_headers" "$bundle_version" all \
    "coreutils"

  printf 'fallback kernel\n' > "$root_dir/boot/vmlinuz-$fallback_abi"
  printf 'fallback initrd\n' > "$root_dir/boot/initrd.img-$fallback_abi"
  printf 'fallback module\n' > \
    "$root_dir/lib/modules/$fallback_abi/kernel/drivers/fixture.ko"
  printf 'kernel/drivers/fixture.ko:\n' > \
    "$root_dir/lib/modules/$fallback_abi/modules.dep"

  : > "$root_dir/boot/grub/grub.cfg"
  write_grub_entry "Ubuntu" \
    "$fallback_abi" "$root_dir/boot/grub/grub.cfg"
  write_grub_entry "Ubuntu, with Linux $fallback_abi" \
    "$fallback_abi" "$root_dir/boot/grub/grub.cfg"
  write_grub_entry "Ubuntu, mit Linux $fallback_abi (Wiederherstellungsmodus)" \
    "$fallback_abi" "$root_dir/boot/grub/grub.cfg" " --class recovery"
}

invoke_preflight() {
  "$preflight" \
    --deb-dir "$deb_dir" \
    --target-abi "$case_target" \
    --fallback-abi "$case_fallback" \
    --root "$root_dir" \
    --running-release "$case_running" \
    --dpkg-deb "$fake_dpkg_deb"
}

fixture_state() {
  find "$fixture" -type f -exec cksum {} \; | LC_ALL=C sort
}

expect_pass() {
  local label="$1"
  local output=""

  if ! output="$(invoke_preflight 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$label was rejected"
  fi
  case "$output" in
    *"preflight passed"*"No packages were installed"*)
      ;;
    *)
      printf '%s\n' "$output" >&2
      fail "$label did not report the read-only success state"
      ;;
  esac
  pass_count=$((pass_count + 1))
}

expect_fail() {
  local label="$1"
  local expected="$2"
  local output=""

  if output="$(invoke_preflight 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$label was accepted"
  fi
  case "$output" in
    *"$expected"*)
      ;;
    *)
      printf '%s\n' "$output" >&2
      fail "$label did not fail with: $expected"
      ;;
  esac
  pass_count=$((pass_count + 1))
}

expect_direct_fail() {
  local label="$1"
  local expected="$2"
  shift 2
  local output=""

  if output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$label was accepted"
  fi
  case "$output" in
    *"$expected"*)
      ;;
    *)
      printf '%s\n' "$output" >&2
      fail "$label did not fail with: $expected"
      ;;
  esac
  pass_count=$((pass_count + 1))
}

make_fixture
state_before="$(fixture_state)"
expect_pass "valid real-style unversioned dependency fixture"
state_after="$(fixture_state)"
[ "$state_after" = "$state_before" ] || fail "valid preflight modified its fixture"

make_fixture
mkdir -p "$root_dir/usr/lib/modules"
mv "$root_dir/lib/modules/$fallback_abi" "$root_dir/usr/lib/modules/"
expect_pass "valid merged-usr module fixture"

make_fixture
case_target="$fallback_abi"
expect_fail "target equal to fallback and running ABI" "Target ABI must differ from fallback ABI"

make_fixture
case_running="6.17.0-1009-qcom-x1e"
expect_fail "fallback not currently running" "Running ABI must exactly match fallback ABI"

make_fixture
root_dir="/"
expect_fail "live-root running ABI override" "allowed only with an alternate --root fixture"

make_fixture
expect_direct_fail "live-root GRUB path override" \
  "--grub-cfg is allowed only with an alternate --root fixture" \
  "$preflight" \
  --deb-dir "$deb_dir" \
  --target-abi "$target_abi" \
  --fallback-abi "$fallback_abi" \
  --root / \
  --grub-cfg "$root_dir/boot/grub/grub.cfg"

make_fixture
expect_direct_fail "live-root dpkg-deb override" \
  "dpkg-deb override is allowed only with an alternate --root fixture" \
  "$preflight" \
  --deb-dir "$deb_dir" \
  --target-abi "$target_abi" \
  --fallback-abi "$fallback_abi" \
  --root / \
  --dpkg-deb "$fake_dpkg_deb"

make_fixture
rm "$deb_dir"/*.deb
expect_fail "empty bundle directory" "exactly four top-level .deb files; found 0"

make_fixture
rm "$deb_dir/${expected_headers}_${bundle_version}_arm64.deb"
expect_fail "missing package role" "exactly four top-level .deb files; found 3"

make_fixture
write_deb \
  "$deb_dir/${expected_modules}_${bundle_version}_arm64.deb" \
  "$expected_image" "$bundle_version" arm64 \
  "$expected_modules"
expect_fail "duplicate package role" "duplicate image packages"

make_fixture
other_modules="linux-modules-7.2-rc5-jg-1099-qcom-x1e"
write_deb \
  "$deb_dir/${expected_modules}_${bundle_version}_arm64.deb" \
  "$other_modules" "$bundle_version" arm64 \
  "wireless-regdb"
expect_fail "mixed target ABI packages" "unexpected package for target ABI"

make_fixture
write_deb \
  "$deb_dir/${expected_modules}_${bundle_version}_arm64.deb" \
  "$expected_modules" "7.2-rc5-jg-1100.2" arm64 \
  "wireless-regdb"
expect_fail "mixed package versions" "mixed package versions"

make_fixture
write_deb \
  "$deb_dir/${expected_image}_${bundle_version}_arm64.deb" \
  "$expected_image" "$bundle_version" amd64 \
  "$expected_modules"
expect_fail "wrong target architecture" "must have architecture arm64"

make_fixture
write_deb \
  "$deb_dir/${expected_common_headers}_${bundle_version}_all.deb" \
  "$expected_common_headers" "$bundle_version" arm64 \
  "coreutils"
expect_fail "wrong common header architecture" "must have architecture all"

make_fixture
write_deb \
  "$deb_dir/${expected_image}_${bundle_version}_arm64.deb" \
  "$expected_image" "$bundle_version" arm64 \
  "kmod, linux-base"
expect_fail "missing image-to-modules dependency" "must depend on $expected_modules"

make_fixture
write_deb \
  "$deb_dir/${expected_headers}_${bundle_version}_arm64.deb" \
  "$expected_headers" "$bundle_version" arm64 \
  "$expected_common_headers (= 7.2-rc5-jg-1100.2)"
expect_fail "mismatched local dependency version" "mismatched local dependency constraint"

make_fixture
printf 'stale module\n' > "$deb_dir/mshw0485_touch.ko"
expect_fail "stale top-level module" "stale top-level kernel module"

make_fixture
mkdir "$deb_dir/nested"
expect_fail "nested bundle content" "must be flat"

make_fixture
rm "$root_dir/boot/vmlinuz-$fallback_abi"
expect_fail "missing fallback image" "Fallback kernel image is missing"

make_fixture
rm "$root_dir/boot/initrd.img-$fallback_abi"
expect_fail "missing fallback initrd" "Fallback initrd is missing"

make_fixture
rm -rf "$root_dir/lib/modules/$fallback_abi"
expect_fail "missing fallback module tree" "Fallback module tree is missing"

make_fixture
rm "$root_dir/lib/modules/$fallback_abi/kernel/drivers/fixture.ko"
expect_fail "metadata-only fallback module tree" "lacks a loadable module or non-empty modules.dep"

make_fixture
write_grub_entry "Second Linux $fallback_abi" \
  "$fallback_abi" "$root_dir/boot/grub/grub.cfg"
expect_fail "duplicate fallback GRUB entry" "found 2"

make_fixture
: > "$root_dir/boot/grub/grub.cfg"
write_grub_entry "Ubuntu" \
  "$fallback_abi" "$root_dir/boot/grub/grub.cfg"
{
  printf "menuentry 'Ubuntu, with Linux %s' {\n" "$fallback_abi"
  printf '  linux /boot/vmlinuz-%s root=UUID=fixture ro\n' "$fallback_abi"
  printf '}\n'
} >> "$root_dir/boot/grub/grub.cfg"
expect_fail "fallback GRUB entry without initrd" "found 0"

make_fixture
: > "$root_dir/boot/grub/grub.cfg"
write_grub_entry "Ubuntu" \
  "$fallback_abi" "$root_dir/boot/grub/grub.cfg"
{
  printf "menuentry 'Ubuntu, with Linux %s' {\n" "$fallback_abi"
  printf '  linux /boot/vmlinuz-%s root=UUID=fixture ro\n' "$fallback_abi"
  printf '  initrd /boot/initrd.img-%s\n' "6.17.0-1009-qcom-x1e"
  printf '}\n'
} >> "$root_dir/boot/grub/grub.cfg"
expect_fail "fallback GRUB entry with wrong initrd" "found 0"

make_fixture
: > "$root_dir/boot/grub/grub.cfg"
write_grub_entry "Unrelated kernel" \
  "6.17.0-1010-qcom-x1e" "$root_dir/boot/grub/grub.cfg"
expect_fail "missing fallback GRUB entry" "found 0"

make_fixture
printf 'target kernel\n' > "$root_dir/boot/vmlinuz-$target_abi"
expect_fail "pre-existing target boot artifact" "Target ABI already has boot artifacts"

make_fixture
mkdir -p "$root_dir/lib/modules/$target_abi"
expect_fail "pre-existing target module tree" "Target ABI already has a module tree"

make_fixture
write_grub_entry "Ubuntu, with Linux $target_abi" \
  "$target_abi" "$root_dir/boot/grub/grub.cfg"
expect_fail "pre-existing target GRUB entry" "Target ABI already has GRUB entries"

echo "PASS: SP11 kernel test preflight ($pass_count cases)"
