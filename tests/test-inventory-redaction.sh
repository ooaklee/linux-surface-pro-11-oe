#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$repo_dir/tests/fixtures/inventory-redaction"
raw_input="$(mktemp)"
actual="$(mktemp)"
inventory_actual="$(mktemp)"
mock_bin="$(mktemp -d)"
trap 'rm -f "$raw_input" "$actual" "$inventory_actual"; rm -rf "$mock_bin"' EXIT

linux_segment="home"
mac_segment="Users"
tunnel_domain="ngrok.io"
linux_home="/$linux_segment/example-user"
mac_home="/$mac_segment/example-user"
remote_endpoint="example.$tunnel_domain:12345"
fixture_secret="DEVICE-SECRET-123"

sed \
  -e "s#@LINUX_HOME@#$linux_home#g" \
  -e "s#@MAC_HOME@#$mac_home#g" \
  -e "s#@REMOTE_ENDPOINT@#$remote_endpoint#g" \
  "$fixture_dir/input.txt" > "$raw_input"

"$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" \
  --redact-stdin < "$raw_input" > "$actual"

diff -u "$fixture_dir/expected.txt" "$actual"

true_path="$(type -P true)"
[ -n "$true_path" ] && [ -x "$true_path" ]
ln -s "$true_path" "$mock_bin/iptsd"
printf '%s\n' \
  '#!/bin/sh' \
  "printf '%s\\n' 'Serial Number: $fixture_secret'" > "$mock_bin/lsusb"
chmod +x "$mock_bin/lsusb"
PATH="$mock_bin:$PATH" \
  "$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" > "$inventory_actual"
grep -Fx 'IPTSD executable: [installed]' "$inventory_actual" >/dev/null
grep -Eq '^Collected \(UTC\): [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$' \
  "$inventory_actual"
if grep -F "$mock_bin/iptsd" "$inventory_actual" >/dev/null; then
  echo "Inventory leaked the IPTSD executable path." >&2
  exit 1
fi
grep -F 'Serial Number: <redacted-identifier>' "$inventory_actual" >/dev/null
if grep -F "$fixture_secret" "$inventory_actual" >/dev/null; then
  echo "Inventory leaked an identifier from a collected command." >&2
  exit 1
fi

echo "Inventory redaction fixture passed."
