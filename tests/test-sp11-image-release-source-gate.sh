#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/scripts/prepare-sp11-image-release-assets.sh"
identity_helper="$repo_dir/scripts/validate-sp11-payload-identity-list.sh"
test_root="$repo_dir/build/test-image-release-source-gate"
release_prefix="test-image-release-source-gate"
kernel_release_name="$release_prefix-kernel-bound"

cleanup() {
  local recovery_dir

  if [ -e "$test_root" ] && [ ! -L "$test_root" ]; then
    chmod -R u+w -- "$test_root" 2>/dev/null || true
  fi
  rm -rf \
    "$test_root" \
    "$repo_dir/build/$release_prefix-fixture.img" \
    "$repo_dir/build/$release_prefix-symlink.img" \
    "$repo_dir/build/$release_prefix-empty.img" \
    "$repo_dir/build/release/$release_prefix-draft" \
    "$repo_dir/build/release/$release_prefix-complete" \
    "$repo_dir/build/release/$release_prefix-bound" \
    "$repo_dir/build/release/$release_prefix-missing" \
    "$repo_dir/build/release/$release_prefix-symlink" \
    "$repo_dir/build/release/$release_prefix-empty" \
    "$repo_dir/build/release/$release_prefix-parent-path" \
    "$repo_dir/build/release/$release_prefix-colon-path" \
    "$repo_dir/build/release/$release_prefix-control-path" \
    "$repo_dir/build/release/$release_prefix-missing-role" \
    "$repo_dir/build/release/$release_prefix-gnome-iso" \
    "$repo_dir/build/release/$release_prefix-dtb-source" \
    "$repo_dir/build/release/$release_prefix-dtb-hash" \
    "$repo_dir/build/release/$release_prefix-esp-boot-hash" \
    "$repo_dir/build/release/$release_prefix-iso-url-ip" \
    "$repo_dir/build/release/$release_prefix-iso-url-short-ip" \
    "$repo_dir/build/release/$release_prefix-iso-url-root" \
    "$repo_dir/build/release/$release_prefix-iso-url-scheme" \
    "$repo_dir/build/release/$release_prefix-iso-url-port" \
    "$repo_dir/build/release/$release_prefix-iso-url-char" \
    "$repo_dir/build/release/$release_prefix-iso-url-long" \
    "$repo_dir/build/release/$release_prefix-iso-url-localhost" \
    "$repo_dir/build/release/$release_prefix-support-tamper" \
    "$repo_dir/build/release/$release_prefix-private-notice" \
    "$repo_dir/build/release/$release_prefix-private-manifest" \
    "$repo_dir/build/release/$release_prefix-legacy-binding" \
    "$repo_dir/build/release/$release_prefix-apt-tamper" \
    "$repo_dir/build/release/$release_prefix-apt-mismatch" \
    "$repo_dir/build/release/$release_prefix-inputs-tamper" \
    "$repo_dir/build/release/$release_prefix-release-order" \
    "$repo_dir/build/release/$release_prefix-image-swap" \
    "$repo_dir/build/release/$release_prefix-rollback" \
    "$repo_dir/build/release/$release_prefix-outline-rollback" \
    "$repo_dir/build/release/$release_prefix-outer-rollback" \
    "$repo_dir/build/release/$release_prefix-notes-rollback" \
    "$repo_dir/build/release/$release_prefix-checksums-rollback" \
    "$repo_dir/build/release/$release_prefix-source-checksums-rollback" \
    "$repo_dir/build/release/$release_prefix-special-prior" \
    "$repo_dir/build/release/$release_prefix-occupant-swap" \
    "$repo_dir/build/release/$release_prefix-prior-drift" \
    "$repo_dir/build/release/$release_prefix-prior-touch" \
    "$repo_dir/build/release/$release_prefix-quarantine-mv-failure" \
    "$repo_dir/build/release/$release_prefix-previous-mv-failure" \
    "$repo_dir/build/release/$release_prefix-retirement-boundary" \
    "$repo_dir/build/release/$release_prefix-retirement-failure" \
    "$repo_dir/build/release/$release_prefix-non-schema" \
    "$repo_dir/build/release/$release_prefix-local-tag" \
    "$repo_dir/build/release/$release_prefix-remote-tag" \
    "$repo_dir/build/release/$release_prefix-missing-origin"
  shopt -s nullglob
  for recovery_dir in \
    "$repo_dir/build/release/.$release_prefix-"*.previous.* \
    "$repo_dir/build/release/.$release_prefix-"*.failed.*; do
    rm -rf -- "$recovery_dir"
  done
  shopt -u nullglob
}
trap cleanup EXIT
cleanup
mkdir -p "$test_root"

image="$repo_dir/build/$release_prefix-fixture.img"
image_fixture_base="$(basename "$image")"
kernel_source="$test_root/fixture-patched-source.tar.xz"
touch_source="$test_root/sp11-touchscreen-modules-source-fixture.tar.xz"
source_notice="$test_root/SOURCE-NOTICE.md"

truncate -s 640M "$image"
printf '%s\n' 'kernel source fixture' > "$kernel_source"
printf '%s\n' 'touchscreen source fixture' > "$touch_source"
printf '%s\n' '# Source fixture' > "$source_notice"

symlink_image="$repo_dir/build/$release_prefix-symlink.img"
ln -s "$(basename "$image")" "$symlink_image"
set +e
symlink_output="$($helper \
  --image "${symlink_image#"$repo_dir"/}" \
  --release-name "$release_prefix-symlink" \
  --skip-validate \
  --allow-dirty 2>&1)"
symlink_status=$?
set -e
[ "$symlink_status" -eq 1 ]
printf '%s\n' "$symlink_output" |
  grep -F 'non-empty, regular, non-symlinked file' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-symlink" ]

empty_image="$repo_dir/build/$release_prefix-empty.img"
: > "$empty_image"
set +e
empty_output="$($helper \
  --image "${empty_image#"$repo_dir"/}" \
  --release-name "$release_prefix-empty" \
  --skip-validate \
  --allow-dirty 2>&1)"
empty_status=$?
set -e
[ "$empty_status" -eq 1 ]
printf '%s\n' "$empty_output" |
  grep -F 'non-empty, regular, non-symlinked file' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-empty" ]

path_victim="$test_root/path-victim"
printf 'do not overwrite\n' > "$path_victim"
expect_image_path_failure() {
  local label="$1" candidate="$2" output status
  set +e
  output="$($helper \
    --image "${candidate#"$repo_dir"/}" \
    --release-name "$release_prefix-$label" \
    --skip-validate \
    --allow-dirty 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" |
    grep -F 'direct child of the repository build directory' >/dev/null
  [ ! -e "$repo_dir/build/release/$release_prefix-$label" ]
  grep -Fxq 'do not overwrite' "$path_victim"
}

mkdir -p "$test_root/parent" "$test_root/unsafe:parent"
control_parent="$test_root/control"$'\n'parent
mkdir -p "$control_parent"
printf 'nested image\n' > "$test_root/parent/fixture.img"
printf 'colon-parent image\n' > "$test_root/unsafe:parent/fixture.img"
printf 'control-parent image\n' > "$control_parent/fixture.img"
expect_image_path_failure parent-path "$test_root/parent/fixture.img"
expect_image_path_failure colon-path "$test_root/unsafe:parent/fixture.img"
expect_image_path_failure control-path "$control_parent/fixture.img"

hash_a="$(printf 'a%.0s' {1..64})"
hash_b="$(printf 'b%.0s' {1..64})"
hash_c="$(printf 'c%.0s' {1..64})"
hash_d="$(printf 'd%.0s' {1..64})"
hash_e="$(printf 'e%.0s' {1..64})"
expected_payload="$test_root/expected-payload"
actual_payload="$test_root/actual-payload"
printf '%s  %s\n' \
  "$hash_a" linux-image-fixture_arm64.deb \
  "$hash_b" gpi.ko \
  "$hash_c" spi-geni-qcom.ko \
  "$hash_d" mshw0485_touch.ko \
  "$hash_e" sp11-touchscreen-modules-manifest.txt \
  > "$expected_payload"
cp "$expected_payload" "$actual_payload"
"$identity_helper" --expected "$expected_payload" --actual "$actual_payload" >/dev/null

expect_identity_failure() {
  local label="$1" expected="$2" actual="$3"
  if "$identity_helper" --expected "$expected" --actual "$actual" \
      > "$test_root/$label.log" 2>&1; then
    echo "Payload identity validator accepted $label." >&2
    exit 1
  fi
  grep -Fq 'do not exactly match' "$test_root/$label.log"
}

wrong_package="$test_root/wrong-package"
sed "s/^$hash_a /$hash_b /" "$actual_payload" > "$wrong_package"
expect_identity_failure wrong-package "$expected_payload" "$wrong_package"
wrong_module="$test_root/wrong-module"
sed "s/^$hash_b  gpi\.ko$/$hash_a  gpi.ko/" "$actual_payload" > "$wrong_module"
expect_identity_failure wrong-module "$expected_payload" "$wrong_module"
wrong_manifest="$test_root/wrong-manifest"
sed "s/^$hash_e  sp11-touchscreen-modules-manifest\.txt$/$hash_a  sp11-touchscreen-modules-manifest.txt/" \
  "$actual_payload" > "$wrong_manifest"
expect_identity_failure wrong-manifest "$expected_payload" "$wrong_manifest"
extra_payload="$test_root/extra-payload"
cp "$actual_payload" "$extra_payload"
printf '%s  %s\n' "$hash_a" linux-extra-fixture_arm64.deb >> "$extra_payload"
expect_identity_failure extra-payload "$expected_payload" "$extra_payload"

set +e
missing_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-missing" \
  --allow-dirty 2>&1)"
missing_status=$?
set -e
[ "$missing_status" -eq 1 ]
printf '%s\n' "$missing_output" |
  grep -F 'without bound corresponding source and payload manifests' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-missing" ]

set +e
unbound_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-missing" \
  --allow-dirty \
  --kernel-source-asset "${kernel_source#"$repo_dir"/}" \
  --touchscreen-source-asset "${touch_source#"$repo_dir"/}" \
  --source-notice "${source_notice#"$repo_dir"/}" 2>&1)"
unbound_status=$?
set -e
[ "$unbound_status" -eq 1 ]
printf '%s\n' "$unbound_output" |
  grep -F 'without bound corresponding source and payload manifests' >/dev/null

set +e
invalid_tag_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name 'invalid tag' \
  --skip-validate \
  --allow-dirty 2>&1)"
invalid_tag_status=$?
set -e
[ "$invalid_tag_status" -eq 1 ]
printf '%s\n' "$invalid_tag_output" | grep -F 'not a valid Git tag' >/dev/null

draft_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-draft" \
  --skip-validate \
  --allow-dirty \
  --part-size-bytes 1024 2>&1)"
printf '%s\n' "$draft_output" | grep -F 'Local draft only:' >/dev/null
if printf '%s\n' "$draft_output" | grep -F 'gh release create' >/dev/null; then
  echo 'Source-less draft printed a publish command.' >&2
  exit 1
fi
grep -F 'Not included; this output is a local draft' \
  "$repo_dir/build/release/$release_prefix-draft/sp11-live-image-release-manifest.txt" >/dev/null
grep -Fxq 'Release manifest schema: sp11-live-image-draft-v1' \
  "$repo_dir/build/release/$release_prefix-draft/sp11-live-image-release-manifest.txt"
grep -Fxq 'Kernel provenance propagation: incomplete' \
  "$repo_dir/build/release/$release_prefix-draft/sp11-live-image-release-manifest.txt"
grep -Fxq 'Publication state: blocked' \
  "$repo_dir/build/release/$release_prefix-draft/sp11-live-image-release-manifest.txt"
grep -F 'This local draft has incomplete kernel-provenance propagation' \
  "$repo_dir/build/release/$release_prefix-draft/RELEASE-NOTES.md" >/dev/null
if grep -F 'propagation attestation is complete' \
    "$repo_dir/build/release/$release_prefix-draft/RELEASE-NOTES.md" >/dev/null; then
  echo 'Draft release notes claimed complete kernel-provenance propagation.' >&2
  exit 1
fi
printf '%s\n' "$draft_output" | grep -F 'NO-PUBLISH:' >/dev/null

special_prior_dir="$repo_dir/build/release/$release_prefix-special-prior"
mkdir "$special_prior_dir"
mkfifo "$special_prior_dir/unsupported-node"
set +e
special_prior_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-special-prior" \
  --skip-validate \
  --allow-dirty \
  --part-size-bytes 1024 2>&1)"
special_prior_status=$?
set -e
[ "$special_prior_status" -eq 1 ]
printf '%s\n' "$special_prior_output" |
  grep -F 'special filesystem nodes are not supported' >/dev/null
[ -p "$special_prior_dir/unsupported-node" ]
if find "$repo_dir/build/release" -maxdepth 1 \
    -name ".$release_prefix-special-prior.previous.*" -print | grep -q .; then
  echo 'Special-node rejection left an empty previous-output recovery container.' >&2
  exit 1
fi

complete_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-complete" \
  --skip-validate \
  --allow-dirty \
  --part-size-bytes 1024 \
  --kernel-source-asset "${kernel_source#"$repo_dir"/}" \
  --touchscreen-source-asset "${touch_source#"$repo_dir"/}" \
  --source-notice "${source_notice#"$repo_dir"/}" 2>&1)"
printf '%s\n' "$complete_output" | grep -F 'Local draft only:' >/dev/null
if printf '%s\n' "$complete_output" | grep -F 'gh release create' >/dev/null; then
  echo 'Unvalidated or dirty output printed a publish command.' >&2
  exit 1
fi

complete_dir="$repo_dir/build/release/$release_prefix-complete"
(
  cd "$complete_dir"
  shasum -a 256 -c SHA256SUMS >/dev/null
  shasum -a 256 -c SOURCE-SHA256SUMS >/dev/null
)
grep -F 'fixture-patched-source.tar.xz' \
  "$complete_dir/sp11-live-image-release-manifest.txt" >/dev/null
grep -F 'sp11-touchscreen-modules-source-fixture.tar.xz' \
  "$complete_dir/sp11-live-image-release-manifest.txt" >/dev/null
grep -F 'of="$TARGET_DEVICE"' "$complete_dir/RELEASE-NOTES.md" >/dev/null
if grep -En '/image/|/tmp/tmp\.' \
  "$complete_dir/RELEASE-NOTES.md" \
  "$complete_dir/sp11-live-image-outline.txt" >/dev/null; then
  echo 'Generated public text contains a validator-internal path.' >&2
  exit 1
fi

if grep -F 'gh release create' "$helper" >/dev/null; then
  echo 'Image preparer still contains a direct publication command.' >&2
  exit 1
fi
grep -F 'NO-PUBLISH:' "$helper" >/dev/null
grep -F -- '--image "$IMAGE_SNAPSHOT"' "$helper" >/dev/null
grep -F -- '-v "$IMAGE_SNAPSHOT:/image/source.img:ro"' "$helper" >/dev/null
grep -F 'zstd -T0 -6 --force -o "$compressed_tmp" "$IMAGE_SNAPSHOT"' "$helper" >/dev/null
[ "$(grep -Fc 'python3 -I "$release_manifest_validator"' "$helper")" -eq 2 ] || {
  echo 'Image preparer manifest-validation calls are not exactly isolated.' >&2
  exit 1
}
touchscreen_validator="$repo_dir/scripts/validate-sp11-touchscreen-release.sh"
[ "$(grep -Fc 'python3 -I "$validator"' "$touchscreen_validator")" -eq 2 ] || {
  echo 'Release validator manifest-validation calls are not exactly isolated.' >&2
  exit 1
}
grep -F 'python3 -I "$build_inputs_validator" validate-attached' \
  "$touchscreen_validator" >/dev/null || {
  echo 'Release validator build-input validation is not isolated.' >&2
  exit 1
}

kernel_repo="$test_root/kernel-repo"
touch_repo="$test_root/touch-repo"
mkdir -p "$kernel_repo" "$touch_repo/phase55/modules"
git -C "$kernel_repo" init --quiet --initial-branch=fixture
git -C "$kernel_repo" config user.name 'SP11 image fixture'
git -C "$kernel_repo" config user.email 'sp11-image@example.invalid'
printf 'kernel source\n' > "$kernel_repo/kernel.c"
git -C "$kernel_repo" add .
git -C "$kernel_repo" commit --quiet -m 'Create image kernel source fixture'
kernel_tree="$(git -C "$kernel_repo" rev-parse 'HEAD^{tree}')"
bound_kernel_source="$test_root/bound-patched-source.tar.xz"
git -C "$kernel_repo" archive --format=tar --prefix=bound-kernel/ "$kernel_tree" |
  xz --threads=1 -6 > "$bound_kernel_source"

git -C "$touch_repo" init --quiet --initial-branch=fixture
git -C "$touch_repo" config user.name 'SP11 image fixture'
git -C "$touch_repo" config user.email 'sp11-image@example.invalid'
printf 'fixture licence\n' > "$touch_repo/LICENSE"
printf 'obj-m += fixture.o\n' > "$touch_repo/phase55/modules/Makefile"
printf 'int fixture(void) { return 0; }\n' > "$touch_repo/phase55/modules/fixture.c"
git -C "$touch_repo" add .
git -C "$touch_repo" commit --quiet -m 'Create image module source fixture'
touch_commit="$(git -C "$touch_repo" rev-parse 'HEAD^{commit}')"
touch_tree="$(git -C "$touch_repo" rev-parse "$touch_commit:phase55/modules")"
touch_license="$(git -C "$touch_repo" rev-parse "$touch_commit:LICENSE")"
bound_touch_source="$test_root/sp11-touchscreen-modules-source-$touch_commit.tar.xz"
git -C "$touch_repo" archive \
  --format=tar \
  --prefix="bound-touch-$touch_commit/" \
  "$touch_commit" LICENSE phase55/modules |
  xz --threads=1 -6 > "$bound_touch_source"

support_commit="$(git -C "$repo_dir" rev-parse 'HEAD^{commit}')"
support_manifest="$test_root/.sp11-support-tree-v1"
support_identities="$test_root/support-identities"
python3 "$repo_dir/scripts/sp11-support-tree-manifest.py" \
  --repo-dir "$repo_dir" \
  --commit "$support_commit" \
  --output "$support_manifest" \
  --output-identities "$support_identities" >/dev/null
support_manifest_sha="$(shasum -a 256 "$support_manifest" | awk '{print $1}')"
input_iso_sha="$(printf 'c%.0s' {1..64})"
source_commit=8f953dd060bc6e8fb86ca2ea8a92f258141c0169
config_sha="$(printf '2%.0s' {1..64})"
symvers_sha="$(printf '3%.0s' {1..64})"
system_map_sha="$(printf '4%.0s' {1..64})"
stubble_sha="$(printf '5%.0s' {1..64})"
oled_dtb_sha="$(printf '6%.0s' {1..64})"
oled_el2_dtb_sha="$(printf '7%.0s' {1..64})"
certificate_sha="$(printf '8%.0s' {1..64})"
common_headers_sha="$(printf '9%.0s' {1..64})"
headers_sha="$(printf 'a%.0s' {1..64})"
image_package_sha="$(printf 'b%.0s' {1..64})"
modules_package_sha="$(printf 'c%.0s' {1..64})"
gpi_sha="$(printf 'd%.0s' {1..64})"
spi_sha="$(printf 'e%.0s' {1..64})"
touch_sha="$(printf 'f%.0s' {1..64})"
diff_sha="$(printf '0%.0s' {1..64})"
container_digest=678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03
oci_platform_manifest=sha256:3fe5b610f5c41eeeb56c2995bd4afb4990ac5b80dc980e33f9251eaaa8013615
image_builder_digest=678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03
signing_fingerprint="$(printf 'AA:%.0s' {1..31})AA"
embedded_iso_sha="$input_iso_sha"
embedded_dtb_sha="$oled_dtb_sha"
esp_boot_size=4096
esp_boot_sha="$(printf '4%.0s' {1..64})"
esp_readme_size=81
esp_readme_sha=6163777e9eeca7cfb031dab492007471ed514ae99baea73c7da7de9ab51d0443
kernel_abi=7.2.0-1-sp11v3-qcom-x1e
package_version=7.2.0-1
common_headers_name=linux-qcom-x1e-headers-7.2.0-1-sp11v3_7.2.0-1_all.deb
headers_name=linux-headers-7.2.0-1-sp11v3-qcom-x1e_7.2.0-1_arm64.deb
image_name=linux-image-7.2.0-1-sp11v3-qcom-x1e_7.2.0-1_arm64.deb
modules_name=linux-modules-7.2.0-1-sp11v3-qcom-x1e_7.2.0-1_arm64.deb
standalone_release="$test_root/standalone-release"
mkdir -p "$standalone_release"
printf 'common headers fixture\n' > "$standalone_release/$common_headers_name"
printf 'architecture headers fixture\n' > "$standalone_release/$headers_name"
printf 'kernel image fixture\n' > "$standalone_release/$image_name"
printf 'kernel modules fixture\n' > "$standalone_release/$modules_name"
printf 'gpi module fixture\n' > "$standalone_release/gpi.ko"
printf 'spi module fixture\n' > "$standalone_release/spi-geni-qcom.ko"
printf 'touch module fixture\n' > "$standalone_release/mshw0485_touch.ko"
common_headers_sha="$(shasum -a 256 "$standalone_release/$common_headers_name" | awk '{print $1}')"
headers_sha="$(shasum -a 256 "$standalone_release/$headers_name" | awk '{print $1}')"
image_package_sha="$(shasum -a 256 "$standalone_release/$image_name" | awk '{print $1}')"
modules_package_sha="$(shasum -a 256 "$standalone_release/$modules_name" | awk '{print $1}')"
gpi_sha="$(shasum -a 256 "$standalone_release/gpi.ko" | awk '{print $1}')"
spi_sha="$(shasum -a 256 "$standalone_release/spi-geni-qcom.ko" | awk '{print $1}')"
touch_sha="$(shasum -a 256 "$standalone_release/mshw0485_touch.ko" | awk '{print $1}')"
patch_path="$(git -C "$repo_dir" ls-files 'patches/*.patch' 'patches/**/*.patch' |
  LC_ALL=C sort | sed -n '1p')"
[ -n "$patch_path" ]
patch_sha="$(git -C "$repo_dir" show "$support_commit:$patch_path" | shasum -a 256 | awk '{print $1}')"
kernel_build_manifest="$test_root/sp11-kernel-build-manifest.txt"
kernel_release_manifest="$test_root/sp11-kernel-release-manifest.txt"
apt_provenance="$test_root/sp11-kernel-apt-provenance.txt"
build_inputs="$test_root/sp11-kernel-build-inputs.txt"
module_manifest="$test_root/sp11-touchscreen-modules-manifest.txt"
image_build_manifest="$test_root/sp11-live-image-build-manifest.txt"
bound_notice="$test_root/bound/SOURCE-NOTICE.md"
mkdir -p "$test_root/bound"
printf '# Bound source fixture\n' > "$bound_notice"
image_fixture_sha="$(shasum -a 256 "$image" | awk '{print $1}')"
image_fixture_size="$(wc -c < "$image" | tr -d '[:space:]')"
image_sector_count=$((image_fixture_size / 512))
data_end=$((image_sector_count - 2049))
data_sectors=$((data_end - 1050624 + 1))
cat > "$image_build_manifest" <<EOF_IMAGE_BUILD
Schema: sp11-live-image-build-v1
Build completed: true
Input ISO URL: https://fixtures.example.com/ubuntu-x1e.iso
Expected ISO SHA256: $input_iso_sha
Input ISO SHA256: $input_iso_sha
Embedded ISO path: iso/ubuntu-x1e.iso
Embedded ISO SHA256: $embedded_iso_sha
DTB source: kernel-output:denali-oled-dtb
Embedded DTB path: dtb/sp11-denali.dtb
Embedded DTB SHA256: $embedded_dtb_sha
Desktop: gnome
GRUB mode: direct
Partition table: gpt
Logical sector size: 512
Partition count: 2
Partition 1 start sector: 2048
Partition 1 end sector: 1050623
Partition 1 sector count: 1048576
Partition 1 type GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
Partition 1 name: SP11EFI
Partition 1 flags: boot,esp
Partition 1 filesystem: fat32
Partition 1 filesystem label: SP11EFI
Partition 2 start sector: 1050624
Partition 2 end sector: $data_end
Partition 2 sector count: $data_sectors
Partition 2 type GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
Partition 2 name: SP11DATA
Partition 2 flags: none
Partition 2 filesystem: ext4
Partition 2 filesystem label: SP11DATA
ESP boot path: EFI/BOOT/BOOTAA64.EFI
ESP boot size: $esp_boot_size
ESP boot SHA256: $esp_boot_sha
ESP README path: README.txt
ESP README size: $esp_readme_size
ESP README SHA256: $esp_readme_sha
Builder image: ubuntu:26.04@sha256:$image_builder_digest
Builder platform: linux/arm64/v8
Support commit: $support_commit
Support manifest: .sp11-support-tree-v1
Support manifest SHA256: $support_manifest_sha
Output image file: $(basename "$image")
Output image size: $image_fixture_size
Output image SHA256: $image_fixture_sha
EOF_IMAGE_BUILD
actual_image_layout="$test_root/actual-image-layout"
sed -n '/^Partition table: /,/^ESP README SHA256: /p' \
  "$image_build_manifest" > "$actual_image_layout"

cat > "$kernel_build_manifest" <<EOF_BUILD_MANIFEST
Provenance schema: sp11-kernel-build-v2
Release build: true
Support start HEAD: $support_commit
Support start dirty: false
Support end HEAD: $support_commit
Support end dirty: false
Source mode: git
Source URL: https://github.com/jglathe/linux_ms_dev_kit.git
Source ref: jg/ubuntu-qcom-x1e-7.2-rc5-jg-0
Expected source commit: $source_commit
Source HEAD: $source_commit
Container image: ubuntu:26.04@sha256:$container_digest
Container digest: sha256:$container_digest
Container platform: linux/arm64/v8
Build target: binary-indep binary-qcom-x1e
Jobs: 1
Rules runner: fakeroot
Patch count: 1
Patch 1 path: $patch_path
Patch 1 SHA256: $patch_sha
Patch 1 disposition: applied
Patched diff format: git-diff-full-index-binary-v1
Patched diff Git version: git version 2.39.0
Patched diff SHA256: $diff_sha
Patched tree ID: $kernel_tree
Required output roles: kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate
Optional output roles: none
Output count: 7
Output 1 role: kernel-config
Output 1 required: true
Output 1 path: debian/build/build-qcom-x1e/.config
Output 1 size: 1
Output 1 SHA256: $config_sha
Output 2 role: module-symvers
Output 2 required: true
Output 2 path: debian/build/build-qcom-x1e/Module.symvers
Output 2 size: 1
Output 2 SHA256: $symvers_sha
Output 3 role: system-map
Output 3 required: true
Output 3 path: debian/build/build-qcom-x1e/System.map
Output 3 size: 1
Output 3 SHA256: $system_map_sha
Output 4 role: kernel-efi-stubble
Output 4 required: true
Output 4 path: debian/build/build-qcom-x1e/arch/arm64/boot/vmlinuz.efi.stubble
Output 4 size: 1
Output 4 SHA256: $stubble_sha
Output 5 role: denali-oled-dtb
Output 5 required: true
Output 5 path: debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dtb
Output 5 size: 1
Output 5 SHA256: $oled_dtb_sha
Output 6 role: denali-oled-el2-dtb
Output 6 required: true
Output 6 path: debian/build/build-qcom-x1e/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled-el2.dtb
Output 6 size: 1
Output 6 SHA256: $oled_el2_dtb_sha
Output 7 role: module-signing-certificate
Output 7 required: true
Output 7 path: debian/build/build-qcom-x1e/certs/signing_key.x509
Output 7 size: 1
Output 7 SHA256: $certificate_sha
Signing certificate SHA256: $certificate_sha
Signing certificate fingerprint: $signing_fingerprint
Signing certificate serial: A1
Required Deb roles: common-headers headers image modules
Optional Deb roles: modules-extra
Deb count: 4
Deb 1 role: common-headers
Deb 1 required: true
Deb 1 path: $common_headers_name
Deb 1 package: linux-qcom-x1e-headers-7.2.0-1-sp11v3
Deb 1 version: $package_version
Deb 1 architecture: all
Deb 1 size: 1
Deb 1 SHA256: $common_headers_sha
Deb 2 role: headers
Deb 2 required: true
Deb 2 path: $headers_name
Deb 2 package: linux-headers-$kernel_abi
Deb 2 version: $package_version
Deb 2 architecture: arm64
Deb 2 size: 1
Deb 2 SHA256: $headers_sha
Deb 3 role: image
Deb 3 required: true
Deb 3 path: $image_name
Deb 3 package: linux-image-$kernel_abi
Deb 3 version: $package_version
Deb 3 architecture: arm64
Deb 3 size: 1
Deb 3 SHA256: $image_package_sha
Deb 4 role: modules
Deb 4 required: true
Deb 4 path: $modules_name
Deb 4 package: linux-modules-$kernel_abi
Deb 4 version: $package_version
Deb 4 architecture: arm64
Deb 4 size: 1
Deb 4 SHA256: $modules_package_sha
Build completed: true
EOF_BUILD_MANIFEST

python3 "$repo_dir/tests/fixtures/write-sp11-attached-provenance-fixture.py" \
  --baseline "$repo_dir/config/kernel-baselines/7.2-rc5-jg-0.env" \
  --support-head "$support_commit" \
  --build-manifest "$kernel_build_manifest" \
  --apt-provenance "$apt_provenance" \
  --build-inputs "$build_inputs"
python_fixture_sha="$(printf 'fixture Deb python3\n' | shasum -a 256 | awk '{print $1}')"
grep -Fxq 'Downloaded Deb count: 5' "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 path: python3_3.14.3-0ubuntu2_arm64.deb' "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 package: python3' "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 version: 3.14.3-0ubuntu2' "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 architecture: arm64' "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 size: 20' "$apt_provenance"
grep -Fxq "Downloaded Deb 5 SHA256: $python_fixture_sha" "$apt_provenance"
grep -Fxq \
  'Downloaded Deb 5 archive filename: pool/main/f/python3/python3_3.14.3-0ubuntu2_arm64.deb' \
  "$apt_provenance"
grep -Fxq \
  'Downloaded Deb 5 URI: https://snapshot.ubuntu.com/ubuntu/20260807T000000Z/pool/main/f/python3/python3_3.14.3-0ubuntu2_arm64.deb' \
  "$apt_provenance"
grep -Fxq 'Downloaded Deb 5 signed record count: 1' "$apt_provenance"
grep -Fxq \
  'Downloaded Deb 5 signed record 1 location: resolute/main/binary-arm64/Packages.gz' \
  "$apt_provenance"
kernel_build_manifest_size="$(wc -c < "$kernel_build_manifest" | tr -d '[:space:]')"
kernel_build_manifest_sha="$(shasum -a 256 "$kernel_build_manifest" | awk '{print $1}')"
apt_provenance_size="$(wc -c < "$apt_provenance" | tr -d '[:space:]')"
apt_provenance_sha="$(shasum -a 256 "$apt_provenance" | awk '{print $1}')"
build_inputs_size="$(wc -c < "$build_inputs" | tr -d '[:space:]')"
build_inputs_sha="$(shasum -a 256 "$build_inputs" | awk '{print $1}')"

cat > "$module_manifest" <<EOF_MODULE_MANIFEST
Generated: 2026-08-07T00:00:00Z
Release: $kernel_release_name
Kernel ABI: $kernel_abi
Touchscreen source URL: https://fixtures.example.com/touchscreen.git
Touchscreen source commit: $touch_commit
Source archive contract: sp11-touchscreen-source-v1
Source object format: sha1
Source modules path: phase55/modules
Source modules tree ID: $touch_tree
Source license path: LICENSE
Source license mode: 100644
Source license blob ID: $touch_license
Kernel config SHA256: $config_sha
Kernel Module.symvers SHA256: $symvers_sha
Kernel headers input mode: extracted-debs-v1
Kernel common headers Deb: $common_headers_name
Kernel common headers Deb SHA256: $common_headers_sha
Kernel architecture headers Deb: $headers_name
Kernel architecture headers Deb SHA256: $headers_sha
Module compiler identity: cc fixture 1.0
Module linker identity: ld fixture 1.0
Module make identity: make fixture 1.0
Support repo commit: $support_commit
Support repo dirty: false
Required SPI parameter: sp11_windows_se_init
Module gpi.ko name: gpi
Module gpi.ko size: 1
Module gpi.ko SHA256: $gpi_sha
Module gpi.ko vermagic: $kernel_abi SMP
Module gpi.ko srcversion: A1
Module spi-geni-qcom.ko name: spi_geni_qcom
Module spi-geni-qcom.ko size: 1
Module spi-geni-qcom.ko SHA256: $spi_sha
Module spi-geni-qcom.ko vermagic: $kernel_abi SMP
Module spi-geni-qcom.ko srcversion: B2
Module mshw0485_touch.ko name: mshw0485_touch
Module mshw0485_touch.ko size: 1
Module mshw0485_touch.ko SHA256: $touch_sha
Module mshw0485_touch.ko vermagic: $kernel_abi SMP
Module mshw0485_touch.ko srcversion: C3
EOF_MODULE_MANIFEST

kernel_source_sha="$(shasum -a 256 "$bound_kernel_source" | awk '{print $1}')"
touch_source_sha="$(shasum -a 256 "$bound_touch_source" | awk '{print $1}')"
cat > "$kernel_release_manifest" <<EOF_RELEASE_MANIFEST
Generated: 2026-08-07T00:00:00Z
Release: $kernel_release_name
Kernel release schema: sp11-kernel-release-v1
Build provenance schema: sp11-kernel-build-v2
Release build: true
Build completed: true
Kernel build manifest asset: sp11-kernel-build-manifest.txt
Kernel build manifest size: $kernel_build_manifest_size
Kernel build manifest SHA256: $kernel_build_manifest_sha
APT provenance asset: sp11-kernel-apt-provenance.txt
APT provenance schema: sp11-kernel-apt-provenance-v1
APT provenance size: $apt_provenance_size
APT provenance SHA256: $apt_provenance_sha
APT snapshot ID: 20260807T000000Z
APT snapshot URI: https://snapshot.ubuntu.com/ubuntu/20260807T000000Z/
Build inputs asset: sp11-kernel-build-inputs.txt
Build inputs schema: sp11-kernel-build-inputs-v1
Build inputs size: $build_inputs_size
Build inputs SHA256: $build_inputs_sha
Build envelope creation propagation: incomplete
Kernel release propagation: complete
OCI index image: ubuntu:26.04@sha256:$container_digest
OCI index digest: sha256:$container_digest
OCI platform: linux/arm64/v8
OCI platform manifest: $oci_platform_manifest
Publication state: blocked
Support repo commit: $support_commit
Support repo dirty: false
Source mode: git
Source URL: https://github.com/jglathe/linux_ms_dev_kit.git
Source branch: jg/ubuntu-qcom-x1e-7.2-rc5-jg-0
Source HEAD: $source_commit
Docker image: ubuntu:26.04@sha256:$container_digest
Container digest: sha256:$container_digest
Container platform: linux/arm64/v8
Build target: binary-indep binary-qcom-x1e
Jobs: 1
Rules runner: fakeroot
Patched diff format: git-diff-full-index-binary-v1
Patched diff Git version: git version 2.39.0
Patched diff SHA256: $diff_sha
Patched tree ID: $kernel_tree
Required output roles: kernel-config module-symvers system-map kernel-efi-stubble denali-oled-dtb denali-oled-el2-dtb module-signing-certificate
Optional output roles: none
Required package roles: common-headers headers image modules
Optional package roles: modules-extra
Signing certificate SHA256: $certificate_sha
Signing certificate fingerprint: $signing_fingerprint
Signing certificate serial: A1
Package count: 4
Package 1 file: $common_headers_name
Package 1 SHA256: $common_headers_sha
Package 2 file: $headers_name
Package 2 SHA256: $headers_sha
Package 3 file: $image_name
Package 3 SHA256: $image_package_sha
Package 4 file: $modules_name
Package 4 SHA256: $modules_package_sha
Kernel source archive: $(basename "$bound_kernel_source")
Kernel source archive SHA256: $kernel_source_sha
Kernel source tree ID: $kernel_tree
Touchscreen source archive: $(basename "$bound_touch_source")
Touchscreen source archive SHA256: $touch_source_sha
Touchscreen source commit: $touch_commit
Touchscreen source modules tree ID: $touch_tree
Touchscreen source license blob ID: $touch_license
Touchscreen kernel config SHA256: $config_sha
Touchscreen kernel Module.symvers SHA256: $symvers_sha
Touchscreen kernel headers input mode: extracted-debs-v1
Touchscreen kernel common headers Deb: $common_headers_name
Touchscreen kernel common headers Deb SHA256: $common_headers_sha
Touchscreen kernel architecture headers Deb: $headers_name
Touchscreen kernel architecture headers Deb SHA256: $headers_sha
Touchscreen module gpi.ko SHA256: $gpi_sha
Touchscreen module spi-geni-qcom.ko SHA256: $spi_sha
Touchscreen module mshw0485_touch.ko SHA256: $touch_sha
EOF_RELEASE_MANIFEST

bound_actual_payload="$test_root/bound-actual-payload"
printf '%s  %s\n' \
  "$common_headers_sha" "$common_headers_name" \
  "$headers_sha" "$headers_name" \
  "$image_package_sha" "$image_name" \
  "$modules_package_sha" "$modules_name" \
  "$gpi_sha" gpi.ko \
  "$spi_sha" spi-geni-qcom.ko \
  "$touch_sha" mshw0485_touch.ko \
  "$(shasum -a 256 "$module_manifest" | awk '{print $1}')" sp11-touchscreen-modules-manifest.txt \
  > "$bound_actual_payload"

mock_bin="$test_root/mock-bin"
mkdir "$mock_bin"
cat > "$mock_bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
payload_output=""
validation_output=""
image_mount=""
previous=""
stdin_attached=false
for argument in "$@"; do
  [ "$argument" != "-i" ] || stdin_attached=true
  if [ "$previous" = "-v" ]; then
    case "$argument" in
      *:/payload-output) payload_output="${argument%:/payload-output}" ;;
      *:/validation-output) validation_output="${argument%:/validation-output}" ;;
      *:/image/source.img:ro) image_mount="${argument%:/image/source.img:ro}" ;;
    esac
  fi
  previous="$argument"
done
[ "$stdin_attached" = true ] || {
  echo 'fixture Docker invocation did not attach stdin with -i' >&2
  exit 1
}
docker_script="$(cat)"
restore_swapped_image() {
  if [ -n "${FIXTURE_SWAP_HOLD:-}" ] && [ -e "$FIXTURE_SWAP_HOLD" ]; then
    if [ -e "$FIXTURE_SWAP_SOURCE" ] && [ ! -e "$FIXTURE_SWAP_VALID" ]; then
      mv -- "$FIXTURE_SWAP_SOURCE" "$FIXTURE_SWAP_VALID"
    fi
    mv -- "$FIXTURE_SWAP_HOLD" "$FIXTURE_SWAP_SOURCE"
  fi
}
if [ -n "$payload_output" ] && [ "${FIXTURE_IMAGE_SWAP:-false}" = "true" ]; then
  [ -n "$image_mount" ] && [ -n "${FIXTURE_SWAP_SOURCE:-}" ] &&
    [ -n "${FIXTURE_SWAP_VALID:-}" ] && [ -n "${FIXTURE_SWAP_HOLD:-}" ] &&
    [ -n "${FIXTURE_SWAP_MARKER:-}" ] && [ -n "${FIXTURE_SWAP_EXPECTED_SHA:-}" ] || {
    echo 'fixture image-swap hook is incomplete' >&2
    exit 2
  }
  mv -- "$FIXTURE_SWAP_SOURCE" "$FIXTURE_SWAP_HOLD"
  mv -- "$FIXTURE_SWAP_VALID" "$FIXTURE_SWAP_SOURCE"
  trap restore_swapped_image EXIT HUP INT TERM
  mounted_image_sha="$(shasum -a 256 "$image_mount" | awk '{print $1}')"
  printf 'Mount path: %s\nMount SHA256: %s\n' \
    "$image_mount" "$mounted_image_sha" > "$FIXTURE_SWAP_MARKER"
  if [ "$mounted_image_sha" != "$FIXTURE_SWAP_EXPECTED_SHA" ]; then
    echo 'fixture semantic extractor did not receive the temporarily swapped image' >&2
    exit 86
  fi
fi
if [ -n "$payload_output" ] || [ -n "$validation_output" ]; then
  printf '%s\n' "$docker_script" | grep -F 'chmod 0644 "$binding_output"' >/dev/null || {
    echo 'fixture Docker invocation omitted the host-readable binding-output handoff' >&2
    exit 1
  }
fi
if [ -n "$payload_output" ]; then
  cp "$FIXTURE_ACTUAL_PAYLOAD" "$payload_output/actual-payload-sha256"
  cp "$FIXTURE_SUPPORT_MANIFEST" "$payload_output/embedded-support-manifest"
  cp "$FIXTURE_SUPPORT_IDENTITIES" "$payload_output/actual-support-identities"
  cp "$FIXTURE_IMAGE_LAYOUT" "$payload_output/actual-image-layout"
  printf '%s\n' "$FIXTURE_EMBEDDED_ISO_SHA" > "$payload_output/actual-embedded-iso-sha256"
  printf '%s\n' "$FIXTURE_EMBEDDED_DTB_SHA" > "$payload_output/actual-embedded-dtb-sha256"
  chmod 0600 "$payload_output"/*
fi
if [ -n "$validation_output" ]; then
  cp "$FIXTURE_IMAGE_LAYOUT" "$validation_output/actual-image-layout"
  chmod 0600 "$validation_output"/*
fi
echo 'fixture image validation'
EOF_DOCKER
real_git="$(command -v git)"
real_mv="$(command -v mv)"
real_rm="$(command -v rm)"
real_rmdir="$(command -v rmdir)"
cat > "$mock_bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FIXTURE_FAIL_SUPPORT_AFTER_INSTALL:-false}" = "true" ] &&
  [ -e "${FIXTURE_INSTALLED_MARKER:-}" ]; then
  case " $* " in
    *' status --porcelain --untracked-files=all '*) exit 2 ;;
  esac
fi
if [ "${FIXTURE_DIRTY_GIT:-false}" = "true" ]; then
  case " $* " in
    *' status --porcelain --untracked-files=all '*)
      printf ' M README.md\n'
      exit 0
      ;;
  esac
elif [ "${FIXTURE_CLEAN_GIT:-false}" = "true" ]; then
  case " $* " in
    *' status --porcelain --untracked-files=all '*) exit 0 ;;
    *' show-ref --verify --quiet refs/tags/'*)
      [ "${FIXTURE_TAG_MODE:-none}" = "local-wrong" ] && exit 0
      exit 1
      ;;
    *' rev-parse refs/tags/'*)
      if [ "${FIXTURE_TAG_MODE:-none}" = "local-wrong" ]; then
        printf '0000000000000000000000000000000000000000\n'
        exit 0
      fi
      ;;
    *' remote get-url origin '*)
      [ "${FIXTURE_TAG_MODE:-none}" = "remote-wrong" ] || exit 1
      printf 'https://fixtures.example.com/support.git\n'
      exit 0
      ;;
    *' ls-remote --exit-code --tags origin '*)
      if [ "${FIXTURE_TAG_MODE:-none}" = "remote-wrong" ]; then
        printf '0000000000000000000000000000000000000000\trefs/tags/fixture\n'
        exit 0
      fi
      exit 2
      ;;
  esac
fi
exec "$FIXTURE_REAL_GIT" "$@"
EOF_GIT
cat > "$mock_bin/mv" <<'EOF_MV'
#!/usr/bin/env bash
set -euo pipefail
rewrite_main_checksums() {
  local destination="$1" checksum_name
  local checksum_names=()
  while IFS= read -r checksum_name; do
    checksum_names+=("$checksum_name")
  done < <(awk '{print $2}' "$destination/SHA256SUMS")
  (
    cd "$destination"
    shasum -a 256 "${checksum_names[@]}" > .SHA256SUMS.mutated
    "$FIXTURE_REAL_MV" .SHA256SUMS.mutated SHA256SUMS
  )
}
if [ "${FIXTURE_FAIL_PREVIOUS_MV:-false}" = "true" ] && [ "$#" -eq 2 ] &&
  [ "$1" = "${FIXTURE_FAIL_PREVIOUS_DEST:-}" ]; then
  case "$2" in
    "${FIXTURE_RELEASE_ROOT:-}/.${FIXTURE_FAIL_PREVIOUS_RELEASE:-}.previous."*/original)
      printf 'previous move blocked\n' > "$FIXTURE_FAIL_PREVIOUS_MARKER"
      exit 1
      ;;
  esac
fi
if [ "${FIXTURE_FAIL_CANDIDATE_QUARANTINE:-false}" = "true" ] &&
  [ "$#" -eq 2 ] && [ "$1" = "${FIXTURE_QUARANTINE_FINAL:-}" ]; then
  case "$2" in
    "${FIXTURE_RELEASE_ROOT:-}/.${FIXTURE_QUARANTINE_RELEASE:-}.failed."*/candidate)
      printf 'candidate quarantine blocked\n' > "$FIXTURE_QUARANTINE_FAILURE_MARKER"
      exit 1
      ;;
  esac
fi
if [ "${FIXTURE_MUTATE_INSTALLED_OUTPUT:-false}" = "true" ] && [ "$#" -eq 2 ] &&
  [ "$2" = "${FIXTURE_MUTATE_DEST:-}" ] && [ ! -e "${FIXTURE_MUTATE_MARKER:-}" ]; then
  case "$1" in
    "${FIXTURE_RELEASE_ROOT:-}/."*.staging.*)
      "$FIXTURE_REAL_MV" "$@"
      case "${FIXTURE_MUTATE_KIND:-attachment}" in
        attachment)
          chmod u+w "$2/sp11-kernel-apt-provenance.txt"
          printf 'Late mutation: rejected\n' >> "$2/sp11-kernel-apt-provenance.txt"
          ;;
        outline)
          printf 'Forged outline row\n' >> "$2/sp11-live-image-outline.txt"
          rewrite_main_checksums "$2"
          ;;
        outer)
          awk '
            /^Image source: / { print "Image source: build/forged.img"; next }
            /^## Image$/ { print "Injected non-schema row" }
            { print }
          ' "$2/sp11-live-image-release-manifest.txt" \
            > "$2/.sp11-live-image-release-manifest.mutated"
          "$FIXTURE_REAL_MV" "$2/.sp11-live-image-release-manifest.mutated" \
            "$2/sp11-live-image-release-manifest.txt"
          rewrite_main_checksums "$2"
          ;;
        notes)
          printf 'Forged publication instruction\n' >> "$2/RELEASE-NOTES.md"
          ;;
        checksums)
          awk '{ rows[NR] = $0 } END { for (row = NR; row >= 1; row--) print rows[row] }' \
            "$2/SHA256SUMS" > "$2/.SHA256SUMS.reordered"
          "$FIXTURE_REAL_MV" "$2/.SHA256SUMS.reordered" "$2/SHA256SUMS"
          ;;
        source-checksums)
          awk '{ rows[NR] = $0 } END { for (row = NR; row >= 1; row--) print rows[row] }' \
            "$2/SOURCE-SHA256SUMS" > "$2/.SOURCE-SHA256SUMS.reordered"
          "$FIXTURE_REAL_MV" "$2/.SOURCE-SHA256SUMS.reordered" \
            "$2/SOURCE-SHA256SUMS"
          ;;
        occupant-swap)
          [ -n "${FIXTURE_OCCUPANT_CANDIDATE_HOLD:-}" ] || exit 2
          "$FIXTURE_REAL_MV" "$2" "$FIXTURE_OCCUPANT_CANDIDATE_HOLD"
          mkdir "$2"
          printf 'unexpected occupant must survive\n' > "$2/unexpected-occupant"
          ;;
        prior-drift)
          previous_matches=()
          shopt -s nullglob
          previous_matches=(
            "${FIXTURE_RELEASE_ROOT}/.$(basename "$2").previous."*/original
          )
          shopt -u nullglob
          [ "${#previous_matches[@]}" -eq 1 ] || exit 2
          printf 'concurrent prior mutation\n' >> "${previous_matches[0]}/prior-output"
          printf 'concurrent prior addition\n' > "${previous_matches[0]}/concurrent-prior-addition"
          chmod u+w "$2/sp11-kernel-apt-provenance.txt"
          printf 'Late mutation: rejected\n' >> "$2/sp11-kernel-apt-provenance.txt"
          printf 'concurrent candidate addition\n' > "$2/concurrent-candidate-addition"
          ;;
        prior-touch)
          previous_matches=()
          shopt -s nullglob
          previous_matches=(
            "${FIXTURE_RELEASE_ROOT}/.$(basename "$2").previous."*/original
          )
          shopt -u nullglob
          [ "${#previous_matches[@]}" -eq 1 ] || exit 2
          touch -t 203001010101 "${previous_matches[0]}/prior-output"
          chmod u+w "$2/sp11-kernel-apt-provenance.txt"
          printf 'Late mutation: rejected\n' >> "$2/sp11-kernel-apt-provenance.txt"
          ;;
        retirement-boundary)
          :
          ;;
        *)
          echo 'fixture installed-output mutation kind is invalid' >&2
          exit 2
          ;;
      esac
      printf '%s\n' "${FIXTURE_MUTATE_KIND:-attachment}" > "$FIXTURE_MUTATE_MARKER"
      exit 0
      ;;
  esac
fi
exec "$FIXTURE_REAL_MV" "$@"
EOF_MV
cat > "$mock_bin/rm" <<'EOF_RM'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FIXTURE_FAIL_PREVIOUS_RETIREMENT:-false}" = "true" ] && [ "$#" -ge 1 ]; then
  target="${!#}"
  case "$target" in
    "${FIXTURE_RELEASE_ROOT:-}/.${FIXTURE_RETIREMENT_RELEASE_NAME:-}.previous."*)
      if [ ! -e "${FIXTURE_RETIREMENT_MARKER:-}" ]; then
        printf 'retirement blocked\n' > "$FIXTURE_RETIREMENT_MARKER"
        exit 1
      fi
      ;;
  esac
fi
exec "$FIXTURE_REAL_RM" "$@"
EOF_RM
cat > "$mock_bin/rmdir" <<'EOF_RMDIR'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FIXTURE_MUTATE_FAILED_BEFORE_RETIREMENT:-false}" = "true" ] &&
  [ "$#" -eq 1 ]; then
  case "$1" in
    "${FIXTURE_RELEASE_ROOT:-}/.${FIXTURE_RETIREMENT_BOUNDARY_RELEASE:-}.previous."*)
      if [ ! -e "${FIXTURE_RETIREMENT_BOUNDARY_MARKER:-}" ]; then
        shopt -s nullglob
        failed_candidates=(
          "${FIXTURE_RELEASE_ROOT}/.${FIXTURE_RETIREMENT_BOUNDARY_RELEASE}.failed."*/candidate
        )
        shopt -u nullglob
        [ "${#failed_candidates[@]}" -eq 1 ] || exit 2
        printf 'post-restore candidate addition\n' \
          > "${failed_candidates[0]}/post-restore-candidate-addition"
        printf 'failed candidate changed before retirement\n' \
          > "$FIXTURE_RETIREMENT_BOUNDARY_MARKER"
      fi
      ;;
  esac
fi
exec "$FIXTURE_REAL_RMDIR" "$@"
EOF_RMDIR
cat > "$mock_bin/dpkg-deb" <<'EOF_DPKG_DEB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--fsys-tarfile" ]; then
  exit 0
fi
[ "${1:-}" = "-f" ] || exit 2
base="$(basename "$2")"
field="${3:-}"
package="${base%%_*}"
case "$field" in
  Package) printf '%s\n' "$package" ;;
  Version) printf '%s\n' "$FIXTURE_PACKAGE_VERSION" ;;
  Architecture)
    case "$base" in linux-qcom-x1e-headers-*) printf 'all\n' ;; *) printf 'arm64\n' ;; esac
    ;;
  Depends)
    case "$base" in
      linux-headers-*) printf 'linux-qcom-x1e-headers-%s\n' "${FIXTURE_KERNEL_ABI%-qcom-x1e}" ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF_DPKG_DEB
cat > "$mock_bin/modinfo" <<'EOF_MODINFO'
#!/usr/bin/env bash
set -euo pipefail
field="${2:-}"
base="$(basename "${3:-${2:-}}")"
if [ "${1:-}" = "-p" ]; then
  printf 'sp11_windows_se_init:fixture\n'
  exit 0
fi
case "$field:$base" in
  name:gpi.ko) printf 'gpi\n' ;;
  name:spi-geni-qcom.ko) printf 'spi_geni_qcom\n' ;;
  name:mshw0485_touch.ko) printf 'mshw0485_touch\n' ;;
  vermagic:*.ko) printf '%s SMP\n' "$FIXTURE_KERNEL_ABI" ;;
  srcversion:gpi.ko) printf 'A1\n' ;;
  srcversion:spi-geni-qcom.ko) printf 'B2\n' ;;
  srcversion:mshw0485_touch.ko) printf 'C3\n' ;;
  alias:mshw0485_touch.ko) printf 'of:N*T*Cmicrosoft,mshw0485\n' ;;
  *) exit 2 ;;
esac
EOF_MODINFO
cat > "$mock_bin/tar" <<'EOF_TAR'
#!/usr/bin/env bash
set -euo pipefail
dtb="./usr/lib/firmware/$FIXTURE_KERNEL_ABI/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb"
case " $* " in
  *' -tf - '*) printf '%s\n' "$dtb" ;;
  *' -x -C '*)
    destination=""
    previous=""
    for argument in "$@"; do
      if [ "$previous" = "-C" ]; then destination="$argument"; fi
      previous="$argument"
    done
    mkdir -p "$destination/$(dirname "${dtb#./}")"
    printf 'fixture dtb\n' > "$destination/${dtb#./}"
    ;;
  *) exit 2 ;;
esac
EOF_TAR
cat > "$mock_bin/fdtget" <<'EOF_FDTGET'
#!/usr/bin/env bash
set -euo pipefail
node="${2:-}"
property="${3:-}"
case "$node:$property" in
  /:compatible) printf 'microsoft,denali-oled\n' ;;
  */spi@a88000:status) printf 'okay\n' ;;
  */spi@a88000:compatible) printf 'qcom,geni-spi\n' ;;
  */spi@a88000:qcom,biosref-qspi|*/spi@a88000:qcom,enable-gsi-dma) ;;
  */touchscreen@0:compatible) printf 'microsoft,mshw0485\n' ;;
  *) exit 2 ;;
esac
EOF_FDTGET
chmod +x "$mock_bin/docker" "$mock_bin/git" "$mock_bin/mv" "$mock_bin/rm" \
  "$mock_bin/rmdir"
chmod +x "$mock_bin/dpkg-deb" "$mock_bin/modinfo" "$mock_bin/tar" "$mock_bin/fdtget"
export FIXTURE_REAL_GIT="$real_git"
export FIXTURE_REAL_MV="$real_mv"
export FIXTURE_REAL_RM="$real_rm"
export FIXTURE_REAL_RMDIR="$real_rmdir"

cp "$kernel_build_manifest" "$standalone_release/sp11-kernel-build-manifest.txt"
  cp "$kernel_release_manifest" "$standalone_release/sp11-kernel-release-manifest.txt"
  cp "$apt_provenance" "$standalone_release/sp11-kernel-apt-provenance.txt"
  cp "$build_inputs" "$standalone_release/sp11-kernel-build-inputs.txt"
  cp "$module_manifest" "$standalone_release/sp11-touchscreen-modules-manifest.txt"
  cp "$bound_kernel_source" "$standalone_release/$(basename "$bound_kernel_source")"
  cp "$bound_touch_source" "$standalone_release/$(basename "$bound_touch_source")"
  printf '%s\n' "$common_headers_name" "$headers_name" "$image_name" "$modules_name" \
    > "$standalone_release/sp11-kernel-debs.txt"
  write_standalone_checksums() {
    local checksum_files=()
    while IFS= read -r checksum_file; do checksum_files+=("$checksum_file"); done < <(
      find "$standalone_release" -mindepth 1 -maxdepth 1 -type f \
        ! -name SHA256SUMS -exec basename {} \; | LC_ALL=C sort
    )
    (cd "$standalone_release" && shasum -a 256 "${checksum_files[@]}" > SHA256SUMS)
  }
  write_standalone_checksums
validator_env=(
    PATH="$mock_bin:$PATH"
    FIXTURE_KERNEL_ABI="$kernel_abi"
    FIXTURE_PACKAGE_VERSION="$package_version"
  )
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --dir "$standalone_release" > "$test_root/standalone-missing-authority.log" 2>&1; then
    echo 'Standalone validator accepted an omitted authority mode.' >&2
    exit 1
  fi
  grep -F 'choose exactly one authority mode: --local-prepared-candidate or --downloaded-release' \
    "$test_root/standalone-missing-authority.log" >/dev/null

  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --local-prepared-candidate --downloaded-release --dir "$standalone_release" \
      > "$test_root/standalone-conflicting-authority.log" 2>&1; then
    echo 'Standalone validator accepted conflicting authority modes.' >&2
    exit 1
  fi
  grep -F 'choose exactly one authority mode: --local-prepared-candidate or --downloaded-release' \
    "$test_root/standalone-conflicting-authority.log" >/dev/null

  if ! env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --downloaded-release --dir "$standalone_release" > "$test_root/standalone-valid.log" 2>&1; then
    cat "$test_root/standalone-valid.log" >&2
    echo 'Standalone validator rejected a complete flat schema-v2 touchscreen release.' >&2
    exit 1
  fi
  grep -Fx 'Validation authority: downloaded-content-only; no local commit or publication authority.' \
    "$test_root/standalone-valid.log" >/dev/null

  printf 'checksummed but not manifest-bound\n' > "$standalone_release/unexpected.txt"
  write_standalone_checksums
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --downloaded-release --dir "$standalone_release" > "$test_root/standalone-extra-asset.log" 2>&1; then
    echo 'Standalone validator accepted an unexpected checksummed schema-v2 asset.' >&2
    exit 1
  fi
  grep -F 'schema-v2 release contains an unexpected asset: unexpected.txt' \
    "$test_root/standalone-extra-asset.log" >/dev/null
  rm "$standalone_release/unexpected.txt"
  write_standalone_checksums

  cp "$standalone_release/sp11-kernel-release-manifest.txt" \
    "$test_root/standalone-release-manifest.original"
  awk '/^Touchscreen source archive SHA256: / {
         print "Touchscreen source archive SHA256: " sprintf("%064d", 0); next
       } { print }' "$test_root/standalone-release-manifest.original" \
    > "$standalone_release/sp11-kernel-release-manifest.txt"
  write_standalone_checksums
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --downloaded-release --dir "$standalone_release" > "$test_root/standalone-source-tamper.log" 2>&1; then
    echo 'Standalone validator accepted a recomputed-checksum source binding tamper.' >&2
    exit 1
  fi
  cp "$test_root/standalone-release-manifest.original" \
    "$standalone_release/sp11-kernel-release-manifest.txt"
  cp "$standalone_release/gpi.ko" "$test_root/gpi.ko.original"
  printf 'different gpi payload\n' > "$standalone_release/gpi.ko"
  write_standalone_checksums
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --downloaded-release --dir "$standalone_release" > "$test_root/standalone-payload-tamper.log" 2>&1; then
    echo 'Standalone validator accepted a recomputed-checksum payload tamper.' >&2
    exit 1
  fi
  cp "$test_root/gpi.ko.original" "$standalone_release/gpi.ko"
else
  printf 'Skipping standalone touchscreen release round trip: Bash 4+ is exercised in Linux CI.\n'
fi

write_standalone_checksums
chmod 0500 "$standalone_release"
bound_kernel_source="$standalone_release/$(basename "$bound_kernel_source")"
bound_touch_source="$standalone_release/$(basename "$bound_touch_source")"
kernel_build_manifest="$standalone_release/sp11-kernel-build-manifest.txt"
kernel_release_manifest="$standalone_release/sp11-kernel-release-manifest.txt"
apt_provenance="$standalone_release/sp11-kernel-apt-provenance.txt"
build_inputs="$standalone_release/sp11-kernel-build-inputs.txt"
module_manifest="$standalone_release/sp11-touchscreen-modules-manifest.txt"

common_publish_args=(
  --image "${image#"$repo_dir"/}"
  --part-size-bytes 1024
  --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}"
  --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}"
  --source-notice "${bound_notice#"$repo_dir"/}"
  --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}"
  --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}"
  --apt-provenance "${apt_provenance#"$repo_dir"/}"
  --build-inputs "${build_inputs#"$repo_dir"/}"
  --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}"
  --image-build-manifest "${image_build_manifest#"$repo_dir"/}"
)
set +e
legacy_binding_output="$($helper \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-legacy-binding" \
  --allow-dirty \
  --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
  --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
  --source-notice "${bound_notice#"$repo_dir"/}" \
  --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
  --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
  --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
  --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
legacy_binding_status=$?
set -e
[ "$legacy_binding_status" -eq 2 ]
printf '%s\n' "$legacy_binding_output" |
  grep -F 'Supply --kernel-build-manifest, --kernel-release-manifest, --apt-provenance, --build-inputs' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-legacy-binding" ]

for tag_mode in local-wrong remote-wrong; do
  tag_suffix="${tag_mode%-wrong}-tag"
  set +e
  tag_output="$(env "${validator_env[@]}" FIXTURE_REAL_GIT="$real_git" \
    FIXTURE_CLEAN_GIT=true FIXTURE_TAG_MODE="$tag_mode" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$release_prefix-$tag_suffix" 2>&1)"
  tag_status=$?
  set -e
  [ "$tag_status" -eq 1 ]
  printf '%s\n' "$tag_output" |
    grep -F "Refusing release: ${tag_mode%-wrong} tag" >/dev/null
  [ ! -e "$repo_dir/build/release/$release_prefix-$tag_suffix" ]
done
set +e
missing_origin_output="$(env "${validator_env[@]}" FIXTURE_CLEAN_GIT=true \
  FIXTURE_TAG_MODE=missing-origin \
  "$helper" "${common_publish_args[@]}" \
    --release-name "$release_prefix-missing-origin" 2>&1)"
missing_origin_status=$?
set -e
[ "$missing_origin_status" -eq 1 ]
printf '%s\n' "$missing_origin_output" |
  grep -F 'support repository has no origin remote' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-missing-origin" ]

private_notice_dir="$test_root/private-notice"
mkdir "$private_notice_dir"
private_path_prefix="/""Users/example"
printf '%s\n' '# Source fixture' "Private path: $private_path_prefix/release-input" \
  > "$private_notice_dir/SOURCE-NOTICE.md"
set +e
fixture_binding_env=("${validator_env[@]}")
fixture_binding_env+=(
  "FIXTURE_DIRTY_GIT=true"
  "FIXTURE_ACTUAL_PAYLOAD=$bound_actual_payload"
  "FIXTURE_SUPPORT_MANIFEST=$support_manifest"
  "FIXTURE_SUPPORT_IDENTITIES=$support_identities"
  "FIXTURE_IMAGE_LAYOUT=$actual_image_layout"
  "FIXTURE_EMBEDDED_ISO_SHA=$embedded_iso_sha"
  "FIXTURE_EMBEDDED_DTB_SHA=$embedded_dtb_sha"
)

image_swap_dir="$test_root/image-swap"
mkdir "$image_swap_dir"
swap_valid_image="$image_swap_dir/valid-image.img"
printf 'different semantic image fixture\n' > "$swap_valid_image"
truncate -s "$image_fixture_size" "$swap_valid_image"
swap_valid_sha="$(shasum -a 256 "$swap_valid_image" | awk '{print $1}')"
[ "$swap_valid_sha" != "$image_fixture_sha" ]
swap_image_manifest="$image_swap_dir/sp11-live-image-build-manifest.txt"
awk -v digest="$image_fixture_sha" '
     /^Output image SHA256: / { print "Output image SHA256: " digest; next }
     { print }' "$image_build_manifest" > "$swap_image_manifest"
swap_marker="$image_swap_dir/docker-image-mount"
swap_hold="$image_swap_dir/original-image-held"
set +e
image_swap_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_IMAGE_SWAP=true \
    "FIXTURE_SWAP_SOURCE=$image" \
    "FIXTURE_SWAP_VALID=$swap_valid_image" \
    "FIXTURE_SWAP_HOLD=$swap_hold" \
    "FIXTURE_SWAP_MARKER=$swap_marker" \
    "FIXTURE_SWAP_EXPECTED_SHA=$swap_valid_sha" \
    "$helper" \
      --image "${image#"$repo_dir"/}" \
      --release-name "$release_prefix-image-swap" \
      --allow-dirty \
      --part-size-bytes 1024 \
      --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
      --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
      --source-notice "${bound_notice#"$repo_dir"/}" \
      --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
      --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
      --apt-provenance "${apt_provenance#"$repo_dir"/}" \
      --build-inputs "${build_inputs#"$repo_dir"/}" \
      --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
      --image-build-manifest "${swap_image_manifest#"$repo_dir"/}" 2>&1)"
image_swap_status=$?
set -e
[ "$image_swap_status" -eq 1 ]
printf '%s\n' "$image_swap_output" |
  grep -F 'Could not extract actual image payload identities.' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-image-swap" ]
[ ! -e "$swap_hold" ]
[ "$(shasum -a 256 "$image" | awk '{print $1}')" = "$image_fixture_sha" ]
[ "$(shasum -a 256 "$swap_valid_image" | awk '{print $1}')" = "$swap_valid_sha" ]
grep -Fxq "Mount SHA256: $image_fixture_sha" "$swap_marker"
if grep -Fxq "Mount path: $image" "$swap_marker"; then
  echo 'Semantic image extraction used the mutable public image path.' >&2
  exit 1
fi
grep -E "^Mount path: $repo_dir/build/release/\\.image-raw-snapshot\\.[^/]+/$(basename "$image")$" \
  "$swap_marker" >/dev/null

expect_install_mutation_rollback() {
  local label="$1" kind="$2" expected="$3"
  local release_name="$release_prefix-$label"
  local rollback_dir="$repo_dir/build/release/$release_name"
  local rollback_marker="$image_swap_dir/post-install-mutation-$kind"
  local rollback_output rollback_status failed_dir
  local failed_dirs=()

  mkdir -p "$rollback_dir"
  printf 'prior output sentinel\n' > "$rollback_dir/prior-output"
  set +e
  rollback_output="$(env "${fixture_binding_env[@]}" \
      FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
      "FIXTURE_MUTATE_KIND=$kind" \
      "FIXTURE_MUTATE_DEST=$rollback_dir" \
      "FIXTURE_MUTATE_MARKER=$rollback_marker" \
      "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
      "$helper" "${common_publish_args[@]}" \
        --release-name "$release_name" --allow-dirty 2>&1)"
  rollback_status=$?
  set -e
  [ "$rollback_status" -eq 1 ]
  printf '%s\n' "$rollback_output" | grep -F "$expected" >/dev/null
  printf '%s\n' "$rollback_output" |
    grep -F 'Post-install image release verification failed; restored the prior output.' >/dev/null
  grep -Fxq "$kind" "$rollback_marker"
  grep -Fxq 'prior output sentinel' "$rollback_dir/prior-output"
  [ "$(find "$rollback_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" -eq 1 ]
  if find "$repo_dir/build/release" -maxdepth 1 \
      -name ".$release_name.previous.*" -print | grep -q .; then
    echo 'Post-install rollback left a previous-output recovery directory after restoration.' >&2
    exit 1
  fi
  shopt -s nullglob
  failed_dirs=("$repo_dir/build/release/.$release_name.failed."*)
  shopt -u nullglob
  [ "${#failed_dirs[@]}" -eq 1 ]
  failed_dir="${failed_dirs[0]}"
  [ -d "$failed_dir/candidate" ] && [ ! -L "$failed_dir/candidate" ]
  printf '%s\n' "$rollback_output" |
    grep -F "Preserved failed image candidate for manual recovery: $failed_dir" >/dev/null
  "$real_rm" -rf -- "$failed_dir"
}

expect_install_mutation_rollback \
  rollback attachment 'Prepared image output does not match its final SHA256SUMS.'
expect_install_mutation_rollback \
  outline-rollback outline 'Prepared image outline bytes changed after generation.'
expect_install_mutation_rollback \
  outer-rollback outer 'Prepared live-image outer manifest bytes changed after generation.'
expect_install_mutation_rollback \
  notes-rollback notes 'Prepared image release-note bytes changed after generation.'
expect_install_mutation_rollback \
  checksums-rollback checksums 'Prepared image SHA256SUMS bytes changed after generation.'
expect_install_mutation_rollback \
  source-checksums-rollback source-checksums \
  'Prepared image SOURCE-SHA256SUMS bytes changed after generation.'

directory_mode() {
  local mode
  if mode="$(stat -c '%a' -- "$1" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -f '%Lp' "$1"
  fi
}

occupant_release_name="$release_prefix-occupant-swap"
occupant_dir="$repo_dir/build/release/$occupant_release_name"
occupant_hold="$image_swap_dir/occupant-held-candidate"
occupant_marker="$image_swap_dir/post-install-mutation-occupant-swap"
mkdir -p "$occupant_dir"
printf 'prior output sentinel\n' > "$occupant_dir/prior-output"
set +e
occupant_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
    FIXTURE_MUTATE_KIND=occupant-swap \
    "FIXTURE_MUTATE_DEST=$occupant_dir" \
    "FIXTURE_MUTATE_MARKER=$occupant_marker" \
    "FIXTURE_OCCUPANT_CANDIDATE_HOLD=$occupant_hold" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$occupant_release_name" --allow-dirty 2>&1)"
occupant_status=$?
set -e
[ "$occupant_status" -eq 1 ]
grep -Fxq 'occupant-swap' "$occupant_marker"
grep -Fxq 'unexpected occupant must survive' "$occupant_dir/unexpected-occupant"
[ -d "$occupant_hold" ] && [ -f "$occupant_hold/SHA256SUMS" ]
printf '%s\n' "$occupant_output" |
  grep -F 'preserving unexpected image output occupant during rollback' >/dev/null
shopt -s nullglob
occupant_previous_dirs=(
  "$repo_dir/build/release/.$occupant_release_name.previous."*
)
shopt -u nullglob
[ "${#occupant_previous_dirs[@]}" -eq 1 ]
occupant_previous_dir="${occupant_previous_dirs[0]}"
[ "$(directory_mode "$occupant_previous_dir")" = 700 ]
grep -Fxq 'prior output sentinel' "$occupant_previous_dir/original/prior-output"
printf '%s\n' "$occupant_output" |
  grep -F "Preserved previous image output recovery data: $occupant_previous_dir" >/dev/null
"$real_rm" -rf -- "$occupant_dir" "$occupant_hold" "$occupant_previous_dir"

prior_drift_release_name="$release_prefix-prior-drift"
prior_drift_dir="$repo_dir/build/release/$prior_drift_release_name"
prior_drift_marker="$image_swap_dir/post-install-mutation-prior-drift"
mkdir -p "$prior_drift_dir"
printf 'prior output sentinel\n' > "$prior_drift_dir/prior-output"
set +e
prior_drift_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
    FIXTURE_MUTATE_KIND=prior-drift \
    "FIXTURE_MUTATE_DEST=$prior_drift_dir" \
    "FIXTURE_MUTATE_MARKER=$prior_drift_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$prior_drift_release_name" --allow-dirty 2>&1)"
prior_drift_status=$?
set -e
[ "$prior_drift_status" -eq 1 ]
grep -Fxq 'prior-drift' "$prior_drift_marker"
[ ! -e "$prior_drift_dir" ]
shopt -s nullglob
prior_drift_previous_dirs=(
  "$repo_dir/build/release/.$prior_drift_release_name.previous."*
)
prior_drift_failed_dirs=(
  "$repo_dir/build/release/.$prior_drift_release_name.failed."*
)
shopt -u nullglob
[ "${#prior_drift_previous_dirs[@]}" -eq 1 ]
[ "${#prior_drift_failed_dirs[@]}" -eq 1 ]
prior_drift_previous_dir="${prior_drift_previous_dirs[0]}"
prior_drift_failed_dir="${prior_drift_failed_dirs[0]}"
[ "$(directory_mode "$prior_drift_previous_dir")" = 700 ]
[ "$(directory_mode "$prior_drift_failed_dir")" = 700 ]
grep -Fxq 'prior output sentinel' <(sed -n '1p' \
  "$prior_drift_previous_dir/original/prior-output")
grep -Fxq 'concurrent prior mutation' <(sed -n '2p' \
  "$prior_drift_previous_dir/original/prior-output")
grep -Fxq 'concurrent prior addition' \
  "$prior_drift_previous_dir/original/concurrent-prior-addition"
[ -f "$prior_drift_failed_dir/candidate/sp11-kernel-apt-provenance.txt" ]
grep -Fxq 'concurrent candidate addition' \
  "$prior_drift_failed_dir/candidate/concurrent-candidate-addition"
printf '%s\n' "$prior_drift_output" |
  grep -F "Preserved failed image candidate for manual recovery: $prior_drift_failed_dir" >/dev/null
printf '%s\n' "$prior_drift_output" |
  grep -F "Preserved previous image output recovery data: $prior_drift_previous_dir" >/dev/null
"$real_rm" -rf -- "$prior_drift_previous_dir" "$prior_drift_failed_dir"

prior_touch_release_name="$release_prefix-prior-touch"
prior_touch_dir="$repo_dir/build/release/$prior_touch_release_name"
prior_touch_marker="$image_swap_dir/post-install-mutation-prior-touch"
mkdir -p "$prior_touch_dir"
printf 'prior output sentinel\n' > "$prior_touch_dir/prior-output"
set +e
prior_touch_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
    FIXTURE_MUTATE_KIND=prior-touch \
    "FIXTURE_MUTATE_DEST=$prior_touch_dir" \
    "FIXTURE_MUTATE_MARKER=$prior_touch_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$prior_touch_release_name" --allow-dirty 2>&1)"
prior_touch_status=$?
set -e
[ "$prior_touch_status" -eq 1 ]
grep -Fxq 'prior-touch' "$prior_touch_marker"
[ ! -e "$prior_touch_dir" ]
shopt -s nullglob
prior_touch_previous_dirs=(
  "$repo_dir/build/release/.$prior_touch_release_name.previous."*
)
prior_touch_failed_dirs=(
  "$repo_dir/build/release/.$prior_touch_release_name.failed."*
)
shopt -u nullglob
[ "${#prior_touch_previous_dirs[@]}" -eq 1 ]
[ "${#prior_touch_failed_dirs[@]}" -eq 1 ]
prior_touch_previous_dir="${prior_touch_previous_dirs[0]}"
prior_touch_failed_dir="${prior_touch_failed_dirs[0]}"
[ "$(directory_mode "$prior_touch_previous_dir")" = 700 ]
[ "$(directory_mode "$prior_touch_failed_dir")" = 700 ]
grep -Fxq 'prior output sentinel' "$prior_touch_previous_dir/original/prior-output"
[ -f "$prior_touch_failed_dir/candidate/sp11-kernel-apt-provenance.txt" ]
printf '%s\n' "$prior_touch_output" |
  grep -F "Preserved failed image candidate for manual recovery: $prior_touch_failed_dir" >/dev/null
printf '%s\n' "$prior_touch_output" |
  grep -F "Preserved previous image output recovery data: $prior_touch_previous_dir" >/dev/null
"$real_rm" -rf -- "$prior_touch_previous_dir" "$prior_touch_failed_dir"

previous_mv_release_name="$release_prefix-previous-mv-failure"
previous_mv_dir="$repo_dir/build/release/$previous_mv_release_name"
previous_mv_marker="$image_swap_dir/previous-mv-failure"
mkdir -p "$previous_mv_dir"
printf 'prior output sentinel\n' > "$previous_mv_dir/prior-output"
set +e
previous_mv_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_FAIL_PREVIOUS_MV=true \
    "FIXTURE_FAIL_PREVIOUS_DEST=$previous_mv_dir" \
    "FIXTURE_FAIL_PREVIOUS_RELEASE=$previous_mv_release_name" \
    "FIXTURE_FAIL_PREVIOUS_MARKER=$previous_mv_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$previous_mv_release_name" --allow-dirty 2>&1)"
previous_mv_status=$?
set -e
[ "$previous_mv_status" -eq 1 ]
grep -Fxq 'previous move blocked' "$previous_mv_marker"
grep -Fxq 'prior output sentinel' "$previous_mv_dir/prior-output"
[ "$(find "$previous_mv_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" -eq 1 ]
printf '%s\n' "$previous_mv_output" |
  grep -F 'Could not retain the previous image release directory privately.' >/dev/null
if find "$repo_dir/build/release" -maxdepth 1 \
    \( -name ".$previous_mv_release_name.previous.*" \
       -o -name ".$previous_mv_release_name.failed.*" \) -print | grep -q .; then
  echo 'Failed previous-output move left an exact empty recovery container.' >&2
  exit 1
fi

quarantine_release_name="$release_prefix-quarantine-mv-failure"
quarantine_dir="$repo_dir/build/release/$quarantine_release_name"
quarantine_install_marker="$image_swap_dir/post-install-mutation-quarantine"
quarantine_failure_marker="$image_swap_dir/candidate-quarantine-failure"
mkdir -p "$quarantine_dir"
printf 'prior output sentinel\n' > "$quarantine_dir/prior-output"
set +e
quarantine_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
    FIXTURE_MUTATE_KIND=attachment \
    "FIXTURE_MUTATE_DEST=$quarantine_dir" \
    "FIXTURE_MUTATE_MARKER=$quarantine_install_marker" \
    FIXTURE_FAIL_CANDIDATE_QUARANTINE=true \
    "FIXTURE_QUARANTINE_FINAL=$quarantine_dir" \
    "FIXTURE_QUARANTINE_RELEASE=$quarantine_release_name" \
    "FIXTURE_QUARANTINE_FAILURE_MARKER=$quarantine_failure_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$quarantine_release_name" --allow-dirty 2>&1)"
quarantine_status=$?
set -e
[ "$quarantine_status" -eq 1 ]
grep -Fxq 'attachment' "$quarantine_install_marker"
grep -Fxq 'candidate quarantine blocked' "$quarantine_failure_marker"
[ -f "$quarantine_dir/SHA256SUMS" ]
[ ! -e "$quarantine_dir/prior-output" ]
printf '%s\n' "$quarantine_output" |
  grep -F 'could not quarantine the failed image candidate' >/dev/null
shopt -s nullglob
quarantine_previous_dirs=(
  "$repo_dir/build/release/.$quarantine_release_name.previous."*
)
quarantine_failed_dirs=(
  "$repo_dir/build/release/.$quarantine_release_name.failed."*
)
shopt -u nullglob
[ "${#quarantine_previous_dirs[@]}" -eq 1 ]
[ "${#quarantine_failed_dirs[@]}" -eq 0 ]
quarantine_previous_dir="${quarantine_previous_dirs[0]}"
grep -Fxq 'prior output sentinel' "$quarantine_previous_dir/original/prior-output"
printf '%s\n' "$quarantine_output" |
  grep -F "Preserved previous image output recovery data: $quarantine_previous_dir" >/dev/null
"$real_rm" -rf -- "$quarantine_dir" "$quarantine_previous_dir"

retirement_boundary_release_name="$release_prefix-retirement-boundary"
retirement_boundary_dir="$repo_dir/build/release/$retirement_boundary_release_name"
retirement_boundary_install_marker="$image_swap_dir/post-install-mutation-retirement-boundary"
retirement_boundary_marker="$image_swap_dir/failed-candidate-retirement-mutation"
mkdir -p "$retirement_boundary_dir"
printf 'prior output sentinel\n' > "$retirement_boundary_dir/prior-output"
set +e
retirement_boundary_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_MUTATE_INSTALLED_OUTPUT=true \
    FIXTURE_MUTATE_KIND=retirement-boundary \
    "FIXTURE_MUTATE_DEST=$retirement_boundary_dir" \
    "FIXTURE_MUTATE_MARKER=$retirement_boundary_install_marker" \
    FIXTURE_FAIL_SUPPORT_AFTER_INSTALL=true \
    "FIXTURE_INSTALLED_MARKER=$retirement_boundary_install_marker" \
    FIXTURE_MUTATE_FAILED_BEFORE_RETIREMENT=true \
    "FIXTURE_RETIREMENT_BOUNDARY_RELEASE=$retirement_boundary_release_name" \
    "FIXTURE_RETIREMENT_BOUNDARY_MARKER=$retirement_boundary_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$retirement_boundary_release_name" --allow-dirty 2>&1)"
retirement_boundary_status=$?
set -e
[ "$retirement_boundary_status" -eq 1 ]
grep -Fxq 'retirement-boundary' "$retirement_boundary_install_marker"
grep -Fxq 'failed candidate changed before retirement' "$retirement_boundary_marker"
grep -Fxq 'prior output sentinel' "$retirement_boundary_dir/prior-output"
[ "$(find "$retirement_boundary_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" -eq 1 ]
shopt -s nullglob
retirement_boundary_previous_dirs=(
  "$repo_dir/build/release/.$retirement_boundary_release_name.previous."*
)
retirement_boundary_failed_dirs=(
  "$repo_dir/build/release/.$retirement_boundary_release_name.failed."*
)
shopt -u nullglob
[ "${#retirement_boundary_previous_dirs[@]}" -eq 0 ]
[ "${#retirement_boundary_failed_dirs[@]}" -eq 1 ]
retirement_boundary_failed_dir="${retirement_boundary_failed_dirs[0]}"
grep -Fxq 'post-restore candidate addition' \
  "$retirement_boundary_failed_dir/candidate/post-restore-candidate-addition"
printf '%s\n' "$retirement_boundary_output" |
  grep -F "Preserved failed image candidate for manual recovery: $retirement_boundary_failed_dir" >/dev/null
"$real_rm" -rf -- "$retirement_boundary_failed_dir"

retirement_release_name="$release_prefix-retirement-failure"
retirement_dir="$repo_dir/build/release/$retirement_release_name"
retirement_marker="$image_swap_dir/previous-retirement-failure"
mkdir -p "$retirement_dir"
printf 'prior output sentinel\n' > "$retirement_dir/prior-output"
retirement_output="$(env "${fixture_binding_env[@]}" \
    FIXTURE_FAIL_PREVIOUS_RETIREMENT=true \
    "FIXTURE_RETIREMENT_RELEASE_NAME=$retirement_release_name" \
    "FIXTURE_RETIREMENT_MARKER=$retirement_marker" \
    "FIXTURE_RELEASE_ROOT=$repo_dir/build/release" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$retirement_release_name" --allow-dirty 2>&1)"
grep -Fxq 'retirement blocked' "$retirement_marker"
[ -f "$retirement_dir/SHA256SUMS" ]
[ ! -e "$retirement_dir/prior-output" ]
printf '%s\n' "$retirement_output" |
  grep -F 'verified image output is committed, but previous-output retirement failed' >/dev/null
shopt -s nullglob
retirement_previous_dirs=(
  "$repo_dir/build/release/.$retirement_release_name.previous."*
)
shopt -u nullglob
[ "${#retirement_previous_dirs[@]}" -eq 1 ]
retirement_previous_dir="${retirement_previous_dirs[0]}"
[ "$(directory_mode "$retirement_previous_dir")" = 700 ]
grep -Fxq 'prior output sentinel' "$retirement_previous_dir/original/prior-output"
"$real_rm" -rf -- "$retirement_previous_dir"

expect_provenance_failure() {
  local label="$1" expected="$2" candidate_root="$3" output status
  set +e
  output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-$label" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${candidate_root#"$repo_dir"/}/$(basename "$bound_kernel_source")" \
    --touchscreen-source-asset "${candidate_root#"$repo_dir"/}/$(basename "$bound_touch_source")" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${candidate_root#"$repo_dir"/}/sp11-kernel-build-manifest.txt" \
    --kernel-release-manifest "${candidate_root#"$repo_dir"/}/sp11-kernel-release-manifest.txt" \
    --apt-provenance "${candidate_root#"$repo_dir"/}/sp11-kernel-apt-provenance.txt" \
    --build-inputs "${candidate_root#"$repo_dir"/}/sp11-kernel-build-inputs.txt" \
    --touchscreen-module-manifest "${candidate_root#"$repo_dir"/}/sp11-touchscreen-modules-manifest.txt" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 1 ]; then
    printf '%s\n' "$output" >&2
    echo "Kernel candidate $label returned unexpected status $status." >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf '%s\n' "$output" >&2
    echo "Kernel candidate $label omitted its expected refusal: $expected" >&2
    exit 1
  fi
  [ ! -e "$repo_dir/build/release/$release_prefix-$label" ] || {
    echo "Kernel candidate $label left an unexpected release output." >&2
    exit 1
  }
}

clone_kernel_candidate() {
  local label="$1" candidate_root
  candidate_root="$test_root/kernel-candidate-$label"
  cp -R "$standalone_release" "$candidate_root"
  chmod 0700 "$candidate_root"
  printf '%s\n' "$candidate_root"
}

write_candidate_checksums() {
  local candidate_root="$1" checksum_files=() checksum_file
  while IFS= read -r checksum_file; do
    checksum_files+=("$checksum_file")
  done < <(
    find "$candidate_root" -mindepth 1 -maxdepth 1 -type f \
      ! -name SHA256SUMS -exec basename {} \; | LC_ALL=C sort
  )
  (cd "$candidate_root" && shasum -a 256 "${checksum_files[@]}" > SHA256SUMS)
}

uncommitted_candidate_dir="$(clone_kernel_candidate uncommitted-root)"
expect_provenance_failure uncommitted-root \
  'Kernel candidate root must be an exact host-owned mode-0500 directory.' \
  "$uncommitted_candidate_dir"

mixed_candidate_dir="$(clone_kernel_candidate mixed-root)"
chmod 0500 "$mixed_candidate_dir"
set +e
mixed_candidate_output="$(env "${fixture_binding_env[@]}" "$helper" \
  --image "${image#"$repo_dir"/}" \
  --release-name "$release_prefix-mixed-root" \
  --allow-dirty \
  --part-size-bytes 1024 \
  --kernel-source-asset "${mixed_candidate_dir#"$repo_dir"/}/$(basename "$bound_kernel_source")" \
  --touchscreen-source-asset "${mixed_candidate_dir#"$repo_dir"/}/$(basename "$bound_touch_source")" \
  --source-notice "${bound_notice#"$repo_dir"/}" \
  --kernel-build-manifest "${mixed_candidate_dir#"$repo_dir"/}/sp11-kernel-build-manifest.txt" \
  --kernel-release-manifest "${mixed_candidate_dir#"$repo_dir"/}/sp11-kernel-release-manifest.txt" \
  --apt-provenance "${apt_provenance#"$repo_dir"/}" \
  --build-inputs "${mixed_candidate_dir#"$repo_dir"/}/sp11-kernel-build-inputs.txt" \
  --touchscreen-module-manifest "${mixed_candidate_dir#"$repo_dir"/}/sp11-touchscreen-modules-manifest.txt" \
  --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
mixed_candidate_status=$?
set -e
[ "$mixed_candidate_status" -eq 1 ]
printf '%s\n' "$mixed_candidate_output" |
  grep -F 'Kernel candidate inputs must share one committed release root.' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-mixed-root" ]

apt_tamper_dir="$(clone_kernel_candidate apt-tamper)"
printf 'Unexpected field: rejected\n' >> "$apt_tamper_dir/sp11-kernel-apt-provenance.txt"
write_candidate_checksums "$apt_tamper_dir"
chmod 0500 "$apt_tamper_dir"
expect_provenance_failure apt-tamper \
  'attached immutable build inputs failed flat validation' \
  "$apt_tamper_dir"

inputs_tamper_dir="$(clone_kernel_candidate inputs-tamper)"
printf 'Unexpected field: rejected\n' >> "$inputs_tamper_dir/sp11-kernel-build-inputs.txt"
write_candidate_checksums "$inputs_tamper_dir"
chmod 0500 "$inputs_tamper_dir"
expect_provenance_failure inputs-tamper \
  'attached immutable build inputs failed flat validation' \
  "$inputs_tamper_dir"

apt_mismatch_dir="$(clone_kernel_candidate apt-mismatch)"
awk 'BEGIN { changed = 0 }
     /^APT list target 1 SHA256: / && changed == 0 {
       print "APT list target 1 SHA256: 0000000000000000000000000000000000000000000000000000000000000000"
       changed = 1
       next
     }
     { print }
     END { if (changed == 0) exit 1 }' \
  "$apt_mismatch_dir/sp11-kernel-apt-provenance.txt" \
  > "$apt_mismatch_dir/sp11-kernel-apt-provenance.changed"
mv "$apt_mismatch_dir/sp11-kernel-apt-provenance.changed" \
  "$apt_mismatch_dir/sp11-kernel-apt-provenance.txt"
mismatch_apt_sha="$(shasum -a 256 "$apt_mismatch_dir/sp11-kernel-apt-provenance.txt" | awk '{print $1}')"
awk -v digest="$mismatch_apt_sha" '
     /^Input 5 SHA256: / { print "Input 5 SHA256: " digest; next }
     { print }' "$apt_mismatch_dir/sp11-kernel-build-inputs.txt" \
  > "$apt_mismatch_dir/sp11-kernel-build-inputs.changed"
mv "$apt_mismatch_dir/sp11-kernel-build-inputs.changed" \
  "$apt_mismatch_dir/sp11-kernel-build-inputs.txt"
write_candidate_checksums "$apt_mismatch_dir"
chmod 0500 "$apt_mismatch_dir"
expect_provenance_failure apt-mismatch \
  'kernel release field does not match build: APT provenance SHA256' \
  "$apt_mismatch_dir"

release_order_dir="$(clone_kernel_candidate release-order)"
awk 'NR == 4 { held = $0; next }
     NR == 5 { print; print held; next }
     { print }' "$release_order_dir/sp11-kernel-release-manifest.txt" \
  > "$release_order_dir/sp11-kernel-release-manifest.changed"
mv "$release_order_dir/sp11-kernel-release-manifest.changed" \
  "$release_order_dir/sp11-kernel-release-manifest.txt"
write_candidate_checksums "$release_order_dir"
chmod 0500 "$release_order_dir"
expect_provenance_failure release-order \
  'field order does not match its schema' "$release_order_dir"

set +e
private_notice_output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-private-notice" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${private_notice_dir#"$repo_dir"/}/SOURCE-NOTICE.md" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --apt-provenance "${apt_provenance#"$repo_dir"/}" \
    --build-inputs "${build_inputs#"$repo_dir"/}" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
private_notice_status=$?
set -e
[ "$private_notice_status" -eq 1 ]
printf '%s\n' "$private_notice_output" |
  grep -F 'public content contains a private-path' >/dev/null

private_manifest_dir="$(clone_kernel_candidate private-manifest)"
awk -v private_path="$private_path_prefix/release-manifest" '
     /^Module compiler identity: / {
       print "Module compiler identity: cc " private_path " 1.0"
       changed++
       next
     }
     { print }
     END { if (changed != 1) exit 1 }' \
  "$private_manifest_dir/sp11-touchscreen-modules-manifest.txt" \
  > "$private_manifest_dir/sp11-touchscreen-modules-manifest.changed"
mv "$private_manifest_dir/sp11-touchscreen-modules-manifest.changed" \
  "$private_manifest_dir/sp11-touchscreen-modules-manifest.txt"
write_candidate_checksums "$private_manifest_dir"
chmod 0500 "$private_manifest_dir"
expect_provenance_failure private-manifest \
  'public content contains a private-path' "$private_manifest_dir"

non_schema_dir="$(clone_kernel_candidate non-schema-release)"
printf '%s\n' '## Packages' '- altered-package.deb' \
  >> "$non_schema_dir/sp11-kernel-release-manifest.txt"
write_candidate_checksums "$non_schema_dir"
chmod 0500 "$non_schema_dir"
expect_provenance_failure non-schema \
  'contains a non-schema line' "$non_schema_dir"

invalid_build_dir="$(clone_kernel_candidate invalid-build)"
sed '/^Output 7 role:/d' "$invalid_build_dir/sp11-kernel-build-manifest.txt" \
  > "$invalid_build_dir/sp11-kernel-build-manifest.changed"
mv "$invalid_build_dir/sp11-kernel-build-manifest.changed" \
  "$invalid_build_dir/sp11-kernel-build-manifest.txt"
write_candidate_checksums "$invalid_build_dir"
chmod 0500 "$invalid_build_dir"
expect_provenance_failure missing-role \
  'missing required top-level field: Output 7 role' "$invalid_build_dir"

expect_image_manifest_failure() {
  local label="$1" candidate="$2" expected="$3" output status
  set +e
  output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-$label" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --apt-provenance "${apt_provenance#"$repo_dir"/}" \
    --build-inputs "${build_inputs#"$repo_dir"/}" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${candidate#"$repo_dir"/}" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 1 ]; then
    printf '%s\n' "$output" >&2
    echo "Image manifest $label returned unexpected status $status." >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf '%s\n' "$output" >&2
    echo "Image manifest $label omitted its expected refusal: $expected" >&2
    exit 1
  fi
  [ ! -e "$repo_dir/build/release/$release_prefix-$label" ] || {
    echo "Image manifest $label left an unexpected release output." >&2
    exit 1
  }
}

bad_image_manifests="$test_root/bad-image-manifests"
mkdir -p \
  "$bad_image_manifests/gnome-iso" \
  "$bad_image_manifests/dtb-source" \
  "$bad_image_manifests/dtb-hash" \
  "$bad_image_manifests/esp-boot-hash" \
  "$bad_image_manifests/iso-url-ip" \
  "$bad_image_manifests/iso-url-short-ip" \
  "$bad_image_manifests/iso-url-root" \
  "$bad_image_manifests/iso-url-scheme" \
  "$bad_image_manifests/iso-url-port" \
  "$bad_image_manifests/iso-url-char" \
  "$bad_image_manifests/iso-url-long" \
  "$bad_image_manifests/iso-url-localhost"
sed "s/^Embedded ISO SHA256: .*/Embedded ISO SHA256: $hash_d/" \
  "$image_build_manifest" > "$bad_image_manifests/gnome-iso/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure gnome-iso \
  "$bad_image_manifests/gnome-iso/sp11-live-image-build-manifest.txt" \
  'GNOME embedded ISO is not the exact pinned input ISO'

sed 's/^DTB source: .*/DTB source: iso-member:dtb\/fixture.dtb/' \
  "$image_build_manifest" > "$bad_image_manifests/dtb-source/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure dtb-source \
  "$bad_image_manifests/dtb-source/sp11-live-image-build-manifest.txt" \
  'publishable image DTB must come from the bound denali-oled-dtb kernel output'

sed "s/^Embedded DTB SHA256: .*/Embedded DTB SHA256: $hash_d/" \
  "$image_build_manifest" > "$bad_image_manifests/dtb-hash/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure dtb-hash \
  "$bad_image_manifests/dtb-hash/sp11-live-image-build-manifest.txt" \
  'embedded DTB does not match the bound denali-oled-dtb kernel output'

sed "s/^ESP boot SHA256: .*/ESP boot SHA256: $hash_d/" \
  "$image_build_manifest" > "$bad_image_manifests/esp-boot-hash/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure esp-boot-hash \
  "$bad_image_manifests/esp-boot-hash/sp11-live-image-build-manifest.txt" \
  'raw image does not match image-build manifest: ESP boot SHA256'

sed 's#^Input ISO URL: .*#Input ISO URL: https://8.8.8.8/ubuntu-x1e.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-ip/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-ip \
  "$bad_image_manifests/iso-url-ip/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: https://127.1/ubuntu-x1e.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-short-ip/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-short-ip \
  "$bad_image_manifests/iso-url-short-ip/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: https://fixtures.example.com/#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-root/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-root \
  "$bad_image_manifests/iso-url-root/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: HTTPS://fixtures.example.com/ubuntu-x1e.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-scheme/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-scheme \
  "$bad_image_manifests/iso-url-scheme/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: https://fixtures.example.com:443/ubuntu-x1e.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-port/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-port \
  "$bad_image_manifests/iso-url-port/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: https://fixtures.example.com/path|name.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-char/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-char \
  "$bad_image_manifests/iso-url-char/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

overlong_iso_url="https://fixtures.example.com/$(printf '%2050s' '' | tr ' ' a)"
sed "s#^Input ISO URL: .*#Input ISO URL: $overlong_iso_url#" \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-long/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-long \
  "$bad_image_manifests/iso-url-long/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

sed 's#^Input ISO URL: .*#Input ISO URL: https://localhost.example.com/ubuntu-x1e.iso#' \
  "$image_build_manifest" > "$bad_image_manifests/iso-url-localhost/sp11-live-image-build-manifest.txt"
expect_image_manifest_failure iso-url-localhost \
  "$bad_image_manifests/iso-url-localhost/sp11-live-image-build-manifest.txt" \
  'input ISO URL is not public HTTPS'

# Isolation is a validator-wide startup authority, including the full image
# mode that launches both Git and the attached build-input helper.  Enter
# through an inherited SIGCHLD=SIG_IGN parent and a hostile sitecustomize path:
# the real validator must restore exact child-wait ownership, pass -I to its
# nested helper, and complete without importing attacker-controlled Python.
release_manifest_validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
release_manifest_validator_args=(
  --repo-dir "$repo_dir"
  --support-commit "$support_commit"
  --release-name "$release_prefix-validator-authority"
  --kernel-build-manifest "$kernel_build_manifest"
  --kernel-release-manifest "$kernel_release_manifest"
  --apt-provenance "$apt_provenance"
  --build-inputs "$build_inputs"
  --touchscreen-module-manifest "$module_manifest"
  --kernel-source "$bound_kernel_source"
  --touchscreen-source "$bound_touch_source"
  --no-expected-payload-output
)
if /usr/bin/python3 "$release_manifest_validator" \
    "${release_manifest_validator_args[@]}" \
    > "$test_root/manifest-validator-nonisolated.log" 2>&1; then
  echo 'Full image manifest validator accepted nonisolated Python startup.' >&2
  exit 1
fi
grep -F 'manifest validation requires isolated Python startup' \
  "$test_root/manifest-validator-nonisolated.log" >/dev/null

hostile_python_root="$test_root/manifest-validator-hostile-python"
hostile_python_marker="$test_root/manifest-validator-hostile-python-imported"
mkdir "$hostile_python_root"
cat > "$hostile_python_root/sitecustomize.py" <<'EOF_HOSTILE_PYTHON'
import os
from pathlib import Path

Path(os.environ["SP11_HOSTILE_MANIFEST_PYTHON_MARKER"]).write_text("imported")
EOF_HOSTILE_PYTHON
if ! PYTHONPATH="$hostile_python_root" \
    PYTHONUSERBASE="$hostile_python_root" \
    SP11_HOSTILE_MANIFEST_PYTHON_MARKER="$hostile_python_marker" \
    /usr/bin/python3 -I -c '
import os
import signal
import sys

signal.signal(signal.SIGCHLD, signal.SIG_IGN)
os.execve(sys.argv[1], sys.argv[1:], os.environ)
' /usr/bin/python3 -I "$release_manifest_validator" \
      "${release_manifest_validator_args[@]}" \
      > "$test_root/manifest-validator-wait-authority.log" 2>&1; then
  cat "$test_root/manifest-validator-wait-authority.log" >&2
  echo 'Full manifest validator failed under inherited SIGCHLD ignore.' >&2
  exit 1
fi
grep -F 'Validated complete schema-v2 image release manifest bindings.' \
  "$test_root/manifest-validator-wait-authority.log" >/dev/null
[ ! -e "$hostile_python_marker" ] || {
  echo 'Manifest validator or its attached helper imported hostile Python.' >&2
  exit 1
}

manifest_nonzero_git_bin="$test_root/manifest-validator-nonzero-git-bin"
manifest_nonzero_git_state="$test_root/manifest-validator-nonzero-git-state"
mkdir "$manifest_nonzero_git_bin" "$manifest_nonzero_git_state"
cat > "$manifest_nonzero_git_bin/git" <<'EOF_NONZERO_GIT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$$" > "$SP11_MANIFEST_NONZERO_GIT_STATE/producer-pid"
case " $* " in
  *" rev-parse --verify $SP11_MANIFEST_NONZERO_GIT_COMMIT^{commit} "*)
    printf '%s\n' "$SP11_MANIFEST_NONZERO_GIT_COMMIT"
    exit 47
    ;;
esac
printf 'unexpected manifest-validator Git vector\n' >&2
exit 98
EOF_NONZERO_GIT
chmod +x "$manifest_nonzero_git_bin/git"
if PATH="$manifest_nonzero_git_bin:/usr/bin:/bin" \
    SP11_MANIFEST_NONZERO_GIT_STATE="$manifest_nonzero_git_state" \
    SP11_MANIFEST_NONZERO_GIT_COMMIT="$support_commit" \
    /usr/bin/python3 -I -c '
import os
import signal
import sys

signal.signal(signal.SIGCHLD, signal.SIG_IGN)
os.execve(sys.argv[1], sys.argv[1:], os.environ)
' /usr/bin/python3 -I "$release_manifest_validator" \
      "${release_manifest_validator_args[@]}" \
      > "$test_root/manifest-validator-nonzero-git.log" 2>&1; then
  echo 'Manifest validator accepted plausible stdout from nonzero Git.' >&2
  exit 1
fi
grep -F 'could not verify committed support provenance' \
  "$test_root/manifest-validator-nonzero-git.log" >/dev/null
[ -f "$manifest_nonzero_git_state/producer-pid" ] || {
  echo 'Nonzero manifest-validator Git did not record its process identity.' >&2
  exit 1
}
manifest_nonzero_git_pid="$(cat "$manifest_nonzero_git_state/producer-pid")"
[[ "$manifest_nonzero_git_pid" =~ ^[0-9]+$ ]] || {
  echo 'Nonzero manifest-validator Git recorded an invalid process identity.' >&2
  exit 1
}
if kill -0 "$manifest_nonzero_git_pid" 2>/dev/null; then
  echo 'Nonzero manifest-validator Git child was not exactly reaped.' >&2
  exit 1
fi
if grep -Fq 'Validated complete schema-v2 image release manifest bindings.' \
    "$test_root/manifest-validator-nonzero-git.log"; then
  echo 'Nonzero manifest-validator Git failure printed terminal success.' >&2
  exit 1
fi

# If in-process state changes the disposition after startup, each subprocess
# boundary must refuse before calling Popen. Exercise both finite child sites
# with a forbidden subprocess stub so generic validation failure cannot pass.
/usr/bin/python3 -I - "$release_manifest_validator" <<'PY_REDRIFT'
import importlib.util
import signal
import sys
from pathlib import Path

validator_path = Path(sys.argv[1])
specification = importlib.util.spec_from_file_location(
    "sp11_manifest_validator_sigchld_redrift", validator_path
)
assert specification is not None and specification.loader is not None
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)
calls = []

def forbidden_run(*arguments, **keywords):
    calls.append((arguments, keywords))
    raise AssertionError("subprocess started after SIGCHLD authority drift")

module.subprocess.run = forbidden_run

module.establish_child_wait_authority()
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
try:
    module.run_git(Path("/fixture/repo"), ["status"])
except module.ValidationError as error:
    assert "child wait authority changed" in str(error)
else:
    raise AssertionError("Git spawn accepted SIGCHLD authority drift")
assert calls == []

module.establish_child_wait_authority()
module.regular_input = lambda *_arguments, **_keywords: None
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
try:
    module.validate_attached_build_inputs(
        Path("/fixture/repo"),
        "0" * 40,
        Path("/fixture/build-manifest"),
        Path("/fixture/apt-provenance"),
        Path("/fixture/build-inputs"),
    )
except module.ValidationError as error:
    assert "child wait authority changed" in str(error)
else:
    raise AssertionError("attached-helper spawn accepted SIGCHLD authority drift")
assert calls == []
module.establish_child_wait_authority()
PY_REDRIFT

url_contract_labels=(scheme global-ip short-ip root port unsafe-char overlong localhost-prefix)
url_contract_values=(
  HTTPS://fixtures.example.com/source.git
  https://8.8.8.8/source.git
  https://127.1/source.git
  https://fixtures.example.com/
  https://fixtures.example.com:443/source.git
  'https://fixtures.example.com/source|name.git'
  "$overlong_iso_url"
  https://localhost.example.com/source.git
)
[ "${#url_contract_labels[@]}" -eq "${#url_contract_values[@]}" ]
for url_contract_index in "${!url_contract_labels[@]}"; do
  url_contract_label="${url_contract_labels[$url_contract_index]}"
  url_contract_value="${url_contract_values[$url_contract_index]}"
  url_contract_dir="$bad_image_manifests/cross-url-$url_contract_label"
  mkdir "$url_contract_dir"
  sed "s#^Source URL: .*#Source URL: $url_contract_value#" \
    "$kernel_build_manifest" > "$url_contract_dir/sp11-kernel-build-manifest.txt"
  if /usr/bin/python3 -I \
      "$repo_dir/scripts/validate-sp11-image-release-manifests.py" \
      --repo-dir "$repo_dir" \
      --support-commit "$support_commit" \
      --build-only \
      --kernel-build-manifest "$url_contract_dir/sp11-kernel-build-manifest.txt" \
      > "$url_contract_dir/kernel.log" 2>&1; then
    echo "schema-v2 validator accepted an unsafe kernel source URL: $url_contract_label" >&2
    exit 1
  fi
  grep -F 'build source URL is not credential-free public HTTPS' \
    "$url_contract_dir/kernel.log" >/dev/null

  sed "s#^Touchscreen source URL: .*#Touchscreen source URL: $url_contract_value#" \
    "$module_manifest" > "$url_contract_dir/sp11-touchscreen-modules-manifest.txt"
  if /usr/bin/python3 -I \
      "$repo_dir/scripts/validate-sp11-image-release-manifests.py" \
      --repo-dir "$repo_dir" \
      --support-commit "$support_commit" \
      --release-name "$release_prefix-cross-$url_contract_label" \
      --kernel-build-manifest "$kernel_build_manifest" \
      --kernel-release-manifest "$kernel_release_manifest" \
      --apt-provenance "$apt_provenance" \
      --build-inputs "$build_inputs" \
      --touchscreen-module-manifest \
        "$url_contract_dir/sp11-touchscreen-modules-manifest.txt" \
      --kernel-source "$bound_kernel_source" \
      --touchscreen-source "$bound_touch_source" \
      --expected-payload-out "$url_contract_dir/expected-payload" \
      > "$url_contract_dir/module.log" 2>&1; then
    echo "schema-v2 validator accepted an unsafe module source URL: $url_contract_label" >&2
    exit 1
  fi
  grep -F 'module source URL is not credential-free public HTTPS' \
    "$url_contract_dir/module.log" >/dev/null
done

tampered_support_identities="$test_root/tampered-support-identities"
awk 'BEGIN { changed = 0 }
     $1 == "f" && changed == 0 {
       $4 = "0000000000000000000000000000000000000000000000000000000000000000"
       changed = 1
     }
     { print }
     END { if (changed == 0) exit 1 }' \
  "$support_identities" > "$tampered_support_identities"
set +e
support_tamper_output="$(env "${fixture_binding_env[@]}" \
    "FIXTURE_SUPPORT_IDENTITIES=$tampered_support_identities" \
    "$helper" "${common_publish_args[@]}" \
      --release-name "$release_prefix-support-tamper" --allow-dirty 2>&1)"
support_tamper_status=$?
set -e
[ "$support_tamper_status" -eq 1 ]
printf '%s\n' "$support_tamper_output" |
  grep -F 'embedded support identity differs' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-support-tamper" ]

bound_output="$(env "${fixture_binding_env[@]}" FIXTURE_DIRTY_GIT=true "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-bound" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --apt-provenance "${apt_provenance#"$repo_dir"/}" \
    --build-inputs "${build_inputs#"$repo_dir"/}" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
printf '%s\n' "$bound_output" | grep -F 'Local draft only:' >/dev/null
bound_dir="$repo_dir/build/release/$release_prefix-bound"
for attached in \
  sp11-kernel-build-manifest.txt \
  sp11-kernel-release-manifest.txt \
  sp11-kernel-apt-provenance.txt \
  sp11-kernel-build-inputs.txt \
  sp11-touchscreen-modules-manifest.txt \
  sp11-live-image-build-manifest.txt; do
  [ -s "$bound_dir/$attached" ]
  grep -F "  $attached" "$bound_dir/SHA256SUMS" >/dev/null
  grep -F "  $attached" "$bound_dir/SOURCE-SHA256SUMS" >/dev/null
done
outer_manifest="$bound_dir/sp11-live-image-release-manifest.txt"
grep -Fxq 'Release manifest schema: sp11-live-image-release-v1' "$outer_manifest"
grep -Fxq 'Kernel release schema: sp11-kernel-release-v1' "$outer_manifest"
grep -Fxq 'Build envelope creation propagation: incomplete' "$outer_manifest"
grep -Fxq 'Kernel release propagation: complete' "$outer_manifest"
grep -Fxq 'Kernel provenance propagation: complete' "$outer_manifest"
grep -Fxq 'Publication state: blocked' "$outer_manifest"
grep -F 'propagation attestation is complete' "$bound_dir/RELEASE-NOTES.md" >/dev/null
printf '%s\n' "$bound_output" | grep -F 'NO-PUBLISH:' >/dev/null
if printf '%s\n' "$bound_output" | grep -F 'gh release create' >/dev/null; then
  echo 'Fully bound image preparation printed a publication command.' >&2
  exit 1
fi
(
  cd "$bound_dir"
  shasum -a 256 -c SHA256SUMS >/dev/null
  shasum -a 256 -c SOURCE-SHA256SUMS >/dev/null
)
bound_raw_sha="$(
  cat "$bound_dir/$image_fixture_base.zst.part-"* |
    zstd -dc | shasum -a 256 | awk '{print $1}'
)"
[ "$bound_raw_sha" = "$image_fixture_sha" ]

echo 'Live-image corresponding-source release gate passed.'
