#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fqx -- "$expected" "$path" || fail "$path does not contain: $expected"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then
    fail "$path unexpectedly contains: $unexpected"
  fi
}

verify_sha256sums() {
  local directory="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$directory" && sha256sum -c SHA256SUMS >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$directory" && shasum -a 256 -c SHA256SUMS >/dev/null)
  else
    fail "sha256sum or shasum is required for checksum tests"
  fi
}

file_mode() {
  local path="$1"
  local mode=""

  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -f '%Lp' "$path"
  fi
}

write_build_manifest() {
  local path="$1"
  local source_head="$2"
  local patch_record="$3"

  {
    echo "Source mode: git"
    echo "Source URL: https://github.com/example/linux.git"
    echo "Source ref: test"
    echo "Source HEAD: $source_head"
    printf '%s\n' "$patch_record"
    echo "Build target: binary-indep binary-qcom-x1e"
    echo "Jobs: 1"
    echo "Rules runner: debian/rules"
  } > "$path"
}

run_release_helper() {
  local fixture="$1"
  shift
  (
    cd "$fixture"
    ./scripts/prepare-sp11-kernel-release-assets.sh \
      --kernel-debs-dir payload/kernel-debs \
      --artifacts-dir artifacts \
      --source-asset source.tar.xz \
      --allow-dirty \
      "$@"
  )
}

run_release_tests() {
  local test_root fixture source_head release_dir
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-release-patches.XXXXXX")"
  fixture="$test_root/support"
  trap 'rm -rf "$test_root"' RETURN

  mkdir -p \
    "$fixture/scripts" \
    "$fixture/payload/kernel-debs" \
    "$fixture/artifacts" \
    "$fixture/patches/legacy-one"
  cp "$repo_dir/scripts/prepare-sp11-kernel-release-assets.sh" "$fixture/scripts/"
  chmod +x "$fixture/scripts/prepare-sp11-kernel-release-assets.sh"

  : > "$fixture/payload/kernel-debs/linux-qcom-x1e-headers-7.2-test_7.2-test_all.deb"
  : > "$fixture/payload/kernel-debs/linux-headers-7.2-test-qcom-x1e_7.2-test_arm64.deb"
  : > "$fixture/payload/kernel-debs/linux-image-7.2-test-qcom-x1e_7.2-test_arm64.deb"
  : > "$fixture/payload/kernel-debs/linux-modules-7.2-test-qcom-x1e_7.2-test_arm64.deb"
  : > "$fixture/source.tar.xz"
  printf 'test patch\n' > "$fixture/patches/legacy-one/0001-test.patch"

  git -C "$fixture" init -q
  git -C "$fixture" config user.name "Kernel helper test"
  git -C "$fixture" config user.email "kernel-helper-test@example.invalid"
  git -C "$fixture" add scripts/prepare-sp11-kernel-release-assets.sh
  git -C "$fixture" commit -qm "Add release helper"
  source_head="$(git -C "$fixture" rev-parse HEAD)"

  write_build_manifest "$fixture/artifacts/sp11-kernel-build-manifest.txt" \
    "$source_head" "Local patches: none"
  run_release_helper "$fixture"
  release_dir="$(find "$fixture/build/release" -mindepth 1 -maxdepth 1 -type d -name '*-baseline1' -print -quit)"
  [ -n "$release_dir" ] || fail "no-patch release did not derive a baseline1 name"
  assert_contains "$release_dir/sp11-kernel-release-manifest.txt" "Local patches: none"
  assert_contains "$release_dir/RELEASE-NOTES.md" "- Local patches: none"
  assert_not_contains "$release_dir/sp11-kernel-release-manifest.txt" "0001-test.patch"

  write_build_manifest "$fixture/artifacts/sp11-kernel-build-manifest.txt" \
    "$source_head" "Unrelated field: none"
  if run_release_helper "$fixture" --release-name test-missing-patch-state >/dev/null 2>&1; then
    fail "release helper accepted a manifest with missing patch provenance"
  fi

  write_build_manifest "$fixture/artifacts/sp11-kernel-build-manifest.txt" \
    "$source_head" $'Patch directory: /build/legacy-one\nLocal patches: none'
  if run_release_helper "$fixture" --release-name test-contradictory-patch-state \
       --patch-dir patches/legacy-one >/dev/null 2>&1; then
    fail "release helper accepted contradictory patch provenance"
  fi

  write_build_manifest "$fixture/artifacts/sp11-kernel-build-manifest.txt" \
    "$source_head" "Patch directory: /build/legacy-one"
  if run_release_helper "$fixture" --release-name test-omitted-patch-dir >/dev/null 2>&1; then
    fail "release helper accepted a patched manifest without --patch-dir"
  fi
  run_release_helper "$fixture" --release-name test-explicit-patch-dir \
    --patch-dir patches/legacy-one >/dev/null
  assert_contains \
    "$fixture/build/release/test-explicit-patch-dir/sp11-kernel-release-manifest.txt" \
    "- patches/legacy-one/0001-test.patch"

  write_build_manifest "$fixture/artifacts/sp11-kernel-build-manifest.txt" \
    "$source_head" "Local patches: none"
  if run_release_helper "$fixture" --release-name test-unexpected-patch-dir \
       --patch-dir patches/legacy-one >/dev/null 2>&1; then
    fail "release helper accepted --patch-dir for a no-patch manifest"
  fi

  trap - RETURN
  rm -rf "$test_root"
}

run_build_helper_tests() {
  local test_root wrapper_dir fixture source_head checkout manifest
  local checksum_helper checksum_fixture failure_fixture scenario
  local expected_checksum_names actual_checksum_names
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/sp11-build-patches.XXXXXX")"
  trap 'rm -rf "$test_root"' RETURN

  wrapper_dir="$test_root/wrapper"
  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel-docker.sh" \
    --source git \
    --git-url "$repo_dir" \
    --git-branch main \
    --image ubuntu:26.04 \
    --work-dir "$wrapper_dir" \
    --linux-work-volume sp11-patch-selection-test-unused \
    --jobs 1 \
    --dry-run >/dev/null
  if grep -Eq '^--patch-dir(s)?$' "$wrapper_dir/docker-build-args.txt"; then
    fail "wrapper forwarded a patch option when none was supplied"
  fi

  checksum_helper="$test_root/artifact-checksum-helper.sh"
  {
    sed -n '/^find_qcom_kernel_debs() {/,/^}/p' \
      "$wrapper_dir/docker-build-inside.sh"
    sed -n '/^write_artifact_sha256sums() {/,/^}/p' \
      "$wrapper_dir/docker-build-inside.sh"
  } > "$checksum_helper"
  assert_contains "$checksum_helper" "find_qcom_kernel_debs() {"
  assert_contains "$checksum_helper" "write_artifact_sha256sums() {"
  # shellcheck source=/dev/null
  . "$checksum_helper"

  checksum_fixture="$test_root/checksum-artifacts"
  mkdir -p "$checksum_fixture"
  for deb in \
    linux-headers-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-image-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-modules-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-qcom-x1e-headers-7.2-test_7.2-test_all.deb; do
    printf 'fixture package: %s\n' "$deb" > "$checksum_fixture/$deb"
    printf '/linux-work/source/%s\n' "$deb" >> \
      "$checksum_fixture/sp11-kernel-debs.txt"
  done
  printf 'Source HEAD: fixture\nLocal patches: none\n' > \
    "$checksum_fixture/sp11-kernel-build-manifest.txt"
  printf 'unrelated stale file\n' > "$checksum_fixture/stale-note.txt"

  write_artifact_sha256sums "$checksum_fixture"
  [ "$(wc -l < "$checksum_fixture/SHA256SUMS" | tr -d '[:space:]')" -eq 6 ] || \
    fail "artifact checksum manifest does not contain exactly six entries"
  expected_checksum_names="$(printf '%s\n' \
    linux-headers-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-image-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-modules-7.2-test-qcom-x1e_7.2-test_arm64.deb \
    linux-qcom-x1e-headers-7.2-test_7.2-test_all.deb \
    sp11-kernel-build-manifest.txt \
    sp11-kernel-debs.txt)"
  actual_checksum_names="$(awk '{ print $2 }' "$checksum_fixture/SHA256SUMS")"
  [ "$actual_checksum_names" = "$expected_checksum_names" ] || \
    fail "artifact checksum manifest is not deterministic"
  assert_not_contains "$checksum_fixture/SHA256SUMS" "SHA256SUMS"
  assert_not_contains "$checksum_fixture/SHA256SUMS" "stale-note.txt"
  [ "$(file_mode "$checksum_fixture/SHA256SUMS")" = 644 ] || \
    fail "artifact checksum manifest is not mode 0644"
  verify_sha256sums "$checksum_fixture"

  for scenario in missing-deb extra-deb missing-build-manifest missing-deb-manifest; do
    failure_fixture="$test_root/checksum-$scenario"
    cp -R "$checksum_fixture" "$failure_fixture"
    case "$scenario" in
      missing-deb)
        rm -f "$failure_fixture/linux-image-7.2-test-qcom-x1e_7.2-test_arm64.deb"
        ;;
      extra-deb)
        printf 'stale package\n' > \
          "$failure_fixture/linux-modules-extra-7.2-test-qcom-x1e_7.2-test_arm64.deb"
        ;;
      missing-build-manifest)
        rm -f "$failure_fixture/sp11-kernel-build-manifest.txt"
        ;;
      missing-deb-manifest)
        rm -f "$failure_fixture/sp11-kernel-debs.txt"
        ;;
    esac
    if write_artifact_sha256sums "$failure_fixture" >/dev/null 2>&1; then
      fail "artifact checksum helper accepted $scenario"
    fi
    [ ! -e "$failure_fixture/SHA256SUMS" ] || \
      fail "artifact checksum helper retained SHA256SUMS after $scenario"
  done

  fixture="$test_root/source"
  git init -q "$fixture"
  git -C "$fixture" config user.name "Kernel helper test"
  git -C "$fixture" config user.email "kernel-helper-test@example.invalid"
  printf 'fixture\n' > "$fixture/README"
  git -C "$fixture" add README
  git -C "$fixture" commit -qm "Add fixture"
  git -C "$fixture" branch -M main
  source_head="$(git -C "$fixture" rev-parse HEAD)"

  "$repo_dir/scripts/build-sp11-qcom-x1e-kernel.sh" \
    --source git \
    --git-url "$fixture" \
    --git-branch main \
    --work-dir "$test_root/inner" \
    --prepare-only \
    --jobs 1 \
    --min-free-gb 1 > "$test_root/inner-output.txt"

  manifest="$test_root/inner/sp11-kernel-build-manifest.txt"
  checkout="$test_root/inner/source/git-main"
  assert_contains "$test_root/inner-output.txt" "No local patches requested."
  assert_contains "$manifest" "Local patches: none"
  assert_not_contains "$manifest" "Patch directory:"
  assert_not_contains "$manifest" "Patch directories:"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$source_head" ] || \
    fail "prepared source HEAD does not match fixture"
  [ -z "$(git -C "$checkout" status --porcelain)" ] || \
    fail "no-patch preparation modified the source tree"

  trap - RETURN
  rm -rf "$test_root"
}

case "${1:-}" in
  --release-only)
    run_release_tests
    ;;
  "")
    run_build_helper_tests
    if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
      run_release_tests
    else
      echo "SKIP: release-helper integration requires Bash 4 or newer." >&2
    fi
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac

echo "PASS: kernel patch selection"
