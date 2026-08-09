#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$repo_dir/tests/fixtures/inventory-redaction"
g6_fixture_dir="$repo_dir/tests/fixtures/g6-stats-filter"
kernel_log_fixture_dir="$repo_dir/tests/fixtures/kernel-log-filter"
raw_input="$(mktemp)"
actual="$(mktemp)"
inventory_actual="$(mktemp)"
kernel_log_raw="$(mktemp)"
mock_bin="$(mktemp -d)"
trap 'rm -f "$raw_input" "$actual" "$inventory_actual" "$kernel_log_raw"; rm -rf "$mock_bin"' EXIT

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

"$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" \
  --filter-g6-stats-stdin < "$g6_fixture_dir/input.txt" > "$inventory_actual"
diff -u "$g6_fixture_dir/expected.txt" "$inventory_actual"

sed "s#@LINUX_HOME@#$linux_home#g" \
  "$kernel_log_fixture_dir/input.txt" > "$kernel_log_raw"
"$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" \
  --filter-kernel-log-stdin < "$kernel_log_raw" > "$inventory_actual"
diff -u "$kernel_log_fixture_dir/expected.txt" "$inventory_actual"

for camera_token in I2C_QCOM_CCI VIDEO_OV02C10 i2c_qcom_cci ov02c10; do
  grep -F "$camera_token" \
    "$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" >/dev/null || {
    echo "Inventory collector is missing camera token: $camera_token" >&2
    exit 1
  }
done

for touchscreen_token in behavior_stats profile initialization_stage \
  irq_transport_errors mode_config_fix windows_read_cadence mshw0485-touch \
  spi:mshw0485 microsoft,mshw0485; do
  grep -F "$touchscreen_token" \
    "$repo_dir/scripts/collect-sp11-feature-parity-inventory.sh" >/dev/null || {
    echo "Inventory collector is missing safe touchscreen field: $touchscreen_token" >&2
    exit 1
  }
done
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
grep -Fx 'Schema: 3' "$inventory_actual" >/dev/null
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
