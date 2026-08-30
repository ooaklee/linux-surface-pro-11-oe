#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail
export LC_ALL=C

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
collector="$repo_dir/scripts/collect-sp11-usb4-diagnostics.sh"
adr="$repo_dir/docs/adr/adr-0068-sp11-usb4-dp-integration.md"
guide="$repo_dir/docs/how-to/how-to-test-sp11-usb4-dp.md"
test_root=""

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [[ -n "$test_root" && -d "$test_root" ]]; then
		rm -rf -- "$test_root"
	fi
}

trap cleanup EXIT

assert_contains() {
	local path="$1"
	local text="$2"

	grep -Fq -- "$text" "$path" || fail "$path is missing: $text"
}

file_mode() {
	local path="$1"
	local mode

	if mode="$(stat -c '%a' -- "$path" 2>/dev/null)"; then
		printf '%s\n' "$mode"
	else
		stat -f '%Lp' -- "$path"
	fi
}

assert_mode() {
	local path="$1"
	local expected="$2"
	local actual

	actual="$(file_mode "$path")"
	[[ "$actual" == "$expected" ]] ||
		fail "$path has mode $actual; expected $expected"
}

verify_sha256sums() {
	local directory="$1"

	if command -v sha256sum >/dev/null 2>&1; then
		(cd "$directory" && sha256sum -c SHA256SUMS >/dev/null)
	elif command -v shasum >/dev/null 2>&1; then
		(cd "$directory" && shasum -a 256 -c SHA256SUMS >/dev/null)
	else
		fail 'sha256sum or shasum is required to verify the collector manifest'
	fi
}

bash -n "$collector"
"$collector" --help >/dev/null

assert_contains "$adr" '7.2.0-jg-0sp11v20'
assert_contains "$adr" 'sp11/integration-7.2.x-usb4-support'
assert_contains "$adr" 'parade,disable-usb4'
assert_contains "$adr" 'does not establish full USB4 support'
assert_contains "$adr" 'linux_ms_dev_kit-sp11/pull/24'
assert_contains "$adr" '5b5f1d124b7ad43b9aac076ad65aa27fa3689ce9'
assert_contains "$adr" 'e056649b9b56622fedd806134d4f79dcf251a2f0'
assert_contains "$guide" 'Direct USB-C DisplayPort Alt Mode'
assert_contains "$guide" 'USB4-tunnel gate'
# This is a literal Markdown fragment, not shell command substitution.
# shellcheck disable=SC2016
assert_contains "$guide" 'Do not use `devmem`'
assert_contains "$collector" '--expected-kernel-commit'
assert_contains "$collector" 'Capture started UTC:'
assert_contains "$collector" 'Capture completed UTC:'
assert_contains "$collector" 'Collector source modified UTC:'
assert_contains "$collector" 'Boot ID:'
assert_contains "$collector" 'data_role'
assert_contains "$collector" 'usb4_version'
assert_contains "$collector" 'link_status'
assert_contains "$collector" 'SHA256SUMS'

if grep -Eq '(^|[[:space:]])(devmem|i2cget|i2cset|i2ctransfer|setpci)([[:space:]]|$)|/dev/mem|/sys/kernel/debug|(^|[[:space:]])tee[[:space:]]+/sys/' "$collector"; then
	fail 'collector contains a raw hardware-access command'
fi

sysfs_allowlist="$(sed -n \
	-e '/^typec_attributes=(/,/^)/p' \
	-e '/^thunderbolt_attributes=(/,/^)/p' \
	-e '/^drm_attributes=(/,/^)/p' "$collector")"
if printf '%s\n' "$sysfs_allowlist" |
	grep -Eqi '(^|[^A-Za-z0-9_])(edid|unique_id|uuid|serial_number)([^A-Za-z0-9_]|$)'; then
	fail 'sysfs allowlist contains a prohibited persistent identifier'
fi

if git -C "$repo_dir" ls-files --cached --others --exclude-standard |
	grep -Eiq '(^|/)(sp11-usb4-uc-fw\.(bin|mbn|elf)|[^/]+\.(etl|evtx|sys|pdb|tmf))$'; then
	fail 'tracked proprietary USB4 firmware, Windows driver, or ETL artifact found'
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-usb4-policy.XXXXXX")"
fake_bin="$test_root/fake-bin"
capture_dir="$test_root/capture"
nonempty_dir="$test_root/nonempty"
invalid_dir="$test_root/invalid-commit"
expected_commit="0123456789abcdef0123456789abcdef01234567"
mkdir -p "$fake_bin" "$nonempty_dir"

printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" "fake lsusb tree"' >"$fake_bin/lsusb"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" "fake lspci failure" >&2' \
	'exit 7' >"$fake_bin/lspci"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" "fake bolt topology" "  uuid: 01234567-89ab-cdef-0123-456789abcdef" "  serial: PRIVATE-SERIAL"' \
	>"$fake_bin/boltctl"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'printf "%s\n" "fake kernel log"' >"$fake_bin/journalctl"
chmod 700 "$fake_bin"/*

PATH="$fake_bin:$PATH" "$collector" \
	--out "$capture_dir" \
	--port-label top \
	--phase baseline \
	--expected-kernel-commit "$expected_commit" >/dev/null

assert_mode "$capture_dir" 700
for generated_file in "$capture_dir"/*; do
	[[ -f "$generated_file" ]] || continue
	assert_mode "$generated_file" 600
done

assert_contains "$capture_dir/metadata.txt" "Expected kernel source commit: $expected_commit"
assert_contains "$capture_dir/metadata.txt" 'Expected commit verification: metadata-only'
assert_contains "$capture_dir/metadata.txt" 'Capture started UTC:'
assert_contains "$capture_dir/metadata.txt" 'Capture completed UTC:'
assert_contains "$capture_dir/metadata.txt" 'Collector source SHA-256:'
assert_contains "$capture_dir/metadata.txt" 'Boot ID:'
assert_contains "$capture_dir/lsusb-tree.txt" 'Available: yes'
assert_contains "$capture_dir/lsusb-tree.txt" 'Exit status: 0'
assert_contains "$capture_dir/lspci-nnk.txt" 'Available: yes'
assert_contains "$capture_dir/lspci-nnk.txt" 'Exit status: 7'
assert_contains "$capture_dir/boltctl-list.txt" 'Exit status: 0'
assert_contains "$capture_dir/boltctl-list.txt" 'uuid: <redacted>'
assert_contains "$capture_dir/boltctl-list.txt" 'serial: <redacted>'
if grep -Fq 'PRIVATE-SERIAL' "$capture_dir/boltctl-list.txt"; then
	fail 'boltctl output retained a persistent serial value'
fi
if grep -Fq '01234567-89ab-cdef-0123-456789abcdef' "$capture_dir/boltctl-list.txt"; then
	fail 'boltctl output retained a persistent UUID value'
fi
assert_contains "$capture_dir/kernel-log.txt" 'Exit status: 0'
verify_sha256sums "$capture_dir"

if grep -Fq 'SHA256SUMS' "$capture_dir/SHA256SUMS"; then
	fail 'SHA256SUMS must not include itself'
fi

printf 'sentinel\n' >"$nonempty_dir/keep.txt"
if "$collector" --out "$nonempty_dir" --port-label top >/dev/null 2>&1; then
	fail 'collector accepted a nonempty output directory'
fi
assert_contains "$nonempty_dir/keep.txt" 'sentinel'

if "$collector" \
	--out "$invalid_dir" \
	--port-label top \
	--expected-kernel-commit short >/dev/null 2>&1; then
	fail 'collector accepted a non-full expected kernel commit'
fi
[[ ! -e "$invalid_dir" ]] || fail 'invalid commit input created an output directory'

printf 'PASS: USB4 integration policy\n'
