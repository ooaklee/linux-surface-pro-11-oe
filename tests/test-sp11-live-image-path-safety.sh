#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-image-paths.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected image-path fixture: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

temporary_root="$(mktemp -d "$temporary_parent/sp11-image-paths.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
fixture_repo="$temporary_root/repo"
outside="$temporary_root/outside"
mkdir -p \
  "$fixture_repo/scripts" "$fixture_repo/build" "$fixture_repo/payload" \
  "$fixture_repo/mock-bin" "$outside"
cp "$repo_dir/scripts/build-sp11-live-usb-image.sh" "$fixture_repo/scripts/"
grep -Fq 'PAYLOAD_DIR="payload/kernel-debs"' \
  "$fixture_repo/scripts/build-sp11-live-usb-image.sh"
grep -Fq 'mkdir -p "$work_abs/payload/kernel-debs"' \
  "$fixture_repo/scripts/build-sp11-live-usb-image.sh"
grep -Fq 'bash /validator/extract-sp11-image-bindings.sh' \
  "$fixture_repo/scripts/build-sp11-live-usb-image.sh"
grep -Fq 'chmod 0644 "$binding_output"' \
  "$fixture_repo/scripts/build-sp11-live-usb-image.sh"
grep -Fq 'ESP boot SHA256: $esp_boot_sha' \
  "$fixture_repo/scripts/build-sp11-live-usb-image.sh"
printf 'fixture ISO\n' > "$fixture_repo/input.iso"
printf 'do not overwrite\n' > "$outside/tripwire"
cat > "$fixture_repo/mock-bin/shasum" <<'EOF_SHASUM'
#!/usr/bin/env bash
exit 99
EOF_SHASUM
cp "$fixture_repo/mock-bin/shasum" "$fixture_repo/mock-bin/docker"
chmod 755 "$fixture_repo/mock-bin/shasum" "$fixture_repo/mock-bin/docker"
export PATH="$fixture_repo/mock-bin:$PATH"

expect_rejection() {
  local label="$1" expected="$2"
  shift 2
  if (cd "$fixture_repo" && bash scripts/build-sp11-live-usb-image.sh \
      --iso input.iso "$@") > "$temporary_root/$label.log" 2>&1; then
    echo "live-image builder accepted unsafe $label" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$temporary_root/$label.log"; then
    cat "$temporary_root/$label.log" >&2
    echo "live-image builder rejected $label for an unexpected reason" >&2
    exit 1
  fi
  grep -Fxq 'do not overwrite' "$outside/tripwire"
}

expect_rejection dot-work 'unsafe component' --work-dir .
expect_rejection parent-work 'unsafe component' --work-dir build/..

ln -s "$outside" "$fixture_repo/build/work-link"
expect_rejection symlink-work 'symlink component' --work-dir build/work-link

expect_rejection escaping-output 'unsafe component' --out ../tripwire.img
ln -s "$outside/tripwire" "$fixture_repo/build/output-link.img"
expect_rejection symlink-output 'symlink component' --out build/output-link.img

ln -s "$outside/tripwire" "$fixture_repo/build/manifest-link.txt"
expect_rejection symlink-manifest 'symlink component' \
  --build-manifest build/manifest-link.txt

expect_rejection broad-payload 'dedicated repository payload/kernel-debs' --payload payload
ln -s "$outside" "$fixture_repo/payload/kernel-debs"
expect_rejection symlink-payload 'symlink component' --payload payload/kernel-debs

expect_rejection invalid-extra-space '--extra-mb must be a positive integer' --extra-mb '1 2'
expect_rejection invalid-extra-range '--extra-mb must be between' --extra-mb 999999

ln -s "$outside/tripwire" "$fixture_repo/symlink.iso"
mkdir -p "$fixture_repo/payload-real/kernel-debs"
rm "$fixture_repo/payload/kernel-debs"
mkdir "$fixture_repo/payload/kernel-debs"

unsafe_url_index=0
overlong_iso_url="https://fixtures.example.com/$(printf '%2050s' '' | tr ' ' a)"
for unsafe_url in \
    HTTPS://fixtures.example.com/ubuntu.iso \
    https://localhost/ubuntu.iso \
    https://localhost.example.com/ubuntu.iso \
    https://192.168.1.20/ubuntu.iso \
    https://169.254.10.20/ubuntu.iso \
    https://8.8.8.8/ubuntu.iso \
    https://127.1/ubuntu.iso \
    https://999.999.999.999/ubuntu.iso \
    https://mirror/ubuntu.iso \
    https://fixtures.invalid/ubuntu.iso \
    https://fixtures.example.com/ \
    https://fixtures.example.com:443/ubuntu.iso \
    'https://fixtures.example.com/path|name.iso' \
    "$overlong_iso_url"; do
  unsafe_url_index=$((unsafe_url_index + 1))
  expect_rejection "unsafe-iso-url-$unsafe_url_index" 'ISO provenance URL' \
    --iso-source-url "$unsafe_url"
done

if (cd "$fixture_repo" && bash scripts/build-sp11-live-usb-image.sh \
    --iso symlink.iso --work-dir build/safe-work) \
    > "$temporary_root/symlink-iso.log" 2>&1; then
  echo 'live-image builder accepted a symlinked ISO input' >&2
  exit 1
fi
grep -Fq 'non-symlinked file' "$temporary_root/symlink-iso.log"
grep -Fxq 'do not overwrite' "$outside/tripwire"

echo 'Live-image path-safety fixtures passed.'
