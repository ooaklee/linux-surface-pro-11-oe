#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/scripts/prepare-sp11-image-release-assets.sh"
identity_helper="$repo_dir/scripts/validate-sp11-payload-identity-list.sh"
test_root="$repo_dir/build/test-image-release-source-gate"
release_prefix="test-image-release-source-gate"
kernel_release_name="$release_prefix-kernel-bound"

cleanup() {
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
    "$repo_dir/build/release/$release_prefix-non-schema" \
    "$repo_dir/build/release/$release_prefix-local-tag" \
    "$repo_dir/build/release/$release_prefix-remote-tag" \
    "$repo_dir/build/release/$release_prefix-missing-origin"
}
trap cleanup EXIT
cleanup
mkdir -p "$test_root"

image="$repo_dir/build/$release_prefix-fixture.img"
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

grep -F -- '--target %q' "$helper" >/dev/null

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
source_commit="$(printf '1%.0s' {1..40})"
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
container_digest="$(printf 'a%.0s' {1..64})"
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
Source URL: https://fixtures.example.com/kernel.git
Source ref: fixture
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
Build provenance schema: sp11-kernel-build-v2
Release build: true
Build completed: true
Support repo commit: $support_commit
Support repo dirty: false
Source mode: git
Source URL: https://fixtures.example.com/kernel.git
Source branch: fixture
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
Package count: 4
Package 1 file: $common_headers_name
Package 1 SHA256: $common_headers_sha
Package 2 file: $headers_name
Package 2 SHA256: $headers_sha
Package 3 file: $image_name
Package 3 SHA256: $image_package_sha
Package 4 file: $modules_name
Package 4 SHA256: $modules_package_sha
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
previous=""
stdin_attached=false
for argument in "$@"; do
  [ "$argument" != "-i" ] || stdin_attached=true
  if [ "$previous" = "-v" ]; then
    case "$argument" in
      *:/payload-output) payload_output="${argument%:/payload-output}" ;;
      *:/validation-output) validation_output="${argument%:/validation-output}" ;;
    esac
  fi
  previous="$argument"
done
[ "$stdin_attached" = true ] || {
  echo 'fixture Docker invocation did not attach stdin with -i' >&2
  exit 1
}
docker_script="$(cat)"
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
cat > "$mock_bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FIXTURE_CLEAN_GIT:-false}" = "true" ]; then
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
chmod +x "$mock_bin/docker" "$mock_bin/git"
chmod +x "$mock_bin/dpkg-deb" "$mock_bin/modinfo" "$mock_bin/tar" "$mock_bin/fdtget"
export FIXTURE_REAL_GIT="$real_git"

if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  cp "$kernel_build_manifest" "$standalone_release/sp11-kernel-build-manifest.txt"
  cp "$kernel_release_manifest" "$standalone_release/sp11-kernel-release-manifest.txt"
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
  if ! env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --dir "$standalone_release" > "$test_root/standalone-valid.log" 2>&1; then
    cat "$test_root/standalone-valid.log" >&2
    echo 'Standalone validator rejected a complete flat schema-v2 touchscreen release.' >&2
    exit 1
  fi

  printf 'checksummed but not manifest-bound\n' > "$standalone_release/unexpected.txt"
  write_standalone_checksums
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --dir "$standalone_release" > "$test_root/standalone-extra-asset.log" 2>&1; then
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
      --dir "$standalone_release" > "$test_root/standalone-source-tamper.log" 2>&1; then
    echo 'Standalone validator accepted a recomputed-checksum source binding tamper.' >&2
    exit 1
  fi
  cp "$test_root/standalone-release-manifest.original" \
    "$standalone_release/sp11-kernel-release-manifest.txt"
  cp "$standalone_release/gpi.ko" "$test_root/gpi.ko.original"
  printf 'different gpi payload\n' > "$standalone_release/gpi.ko"
  write_standalone_checksums
  if env "${validator_env[@]}" "$repo_dir/scripts/validate-sp11-touchscreen-release.sh" \
      --dir "$standalone_release" > "$test_root/standalone-payload-tamper.log" 2>&1; then
    echo 'Standalone validator accepted a recomputed-checksum payload tamper.' >&2
    exit 1
  fi
  cp "$test_root/gpi.ko.original" "$standalone_release/gpi.ko"
else
  printf 'Skipping standalone touchscreen release round trip: Bash 4+ is exercised in Linux CI.\n'
fi

common_publish_args=(
  --image "${image#"$repo_dir"/}"
  --part-size-bytes 1024
  --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}"
  --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}"
  --source-notice "${bound_notice#"$repo_dir"/}"
  --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}"
  --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}"
  --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}"
  --image-build-manifest "${image_build_manifest#"$repo_dir"/}"
)
for tag_mode in local-wrong remote-wrong; do
  tag_suffix="${tag_mode%-wrong}-tag"
  set +e
  tag_output="$(PATH="$mock_bin:$PATH" FIXTURE_REAL_GIT="$real_git" \
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
missing_origin_output="$(PATH="$mock_bin:$PATH" FIXTURE_CLEAN_GIT=true \
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
fixture_binding_env=(
  "PATH=$mock_bin:$PATH"
  "FIXTURE_ACTUAL_PAYLOAD=$bound_actual_payload"
  "FIXTURE_SUPPORT_MANIFEST=$support_manifest"
  "FIXTURE_SUPPORT_IDENTITIES=$support_identities"
  "FIXTURE_IMAGE_LAYOUT=$actual_image_layout"
  "FIXTURE_EMBEDDED_ISO_SHA=$embedded_iso_sha"
  "FIXTURE_EMBEDDED_DTB_SHA=$embedded_dtb_sha"
)
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
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
private_notice_status=$?
set -e
[ "$private_notice_status" -eq 1 ]
printf '%s\n' "$private_notice_output" |
  grep -F 'public content contains a private-path' >/dev/null

private_manifest_dir="$test_root/private-manifest"
mkdir "$private_manifest_dir"
cp "$module_manifest" "$private_manifest_dir/sp11-touchscreen-modules-manifest.txt"
printf '%s\n' "Private path: $private_path_prefix/release-manifest" \
  >> "$private_manifest_dir/sp11-touchscreen-modules-manifest.txt"
set +e
private_manifest_output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-private-manifest" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --touchscreen-module-manifest \
      "${private_manifest_dir#"$repo_dir"/}/sp11-touchscreen-modules-manifest.txt" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
private_manifest_status=$?
set -e
[ "$private_manifest_status" -eq 1 ]
printf '%s\n' "$private_manifest_output" |
  grep -F 'public content contains a private-path' >/dev/null

non_schema_dir="$test_root/non-schema-release"
mkdir "$non_schema_dir"
cp "$kernel_release_manifest" "$non_schema_dir/sp11-kernel-release-manifest.txt"
printf '%s\n' '## Packages' '- altered-package.deb' \
  >> "$non_schema_dir/sp11-kernel-release-manifest.txt"
set +e
non_schema_output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-non-schema" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest \
      "${non_schema_dir#"$repo_dir"/}/sp11-kernel-release-manifest.txt" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
non_schema_status=$?
set -e
[ "$non_schema_status" -eq 1 ]
printf '%s\n' "$non_schema_output" |
  grep -F 'contains a non-schema line' >/dev/null

invalid_build_dir="$test_root/invalid-build"
mkdir "$invalid_build_dir"
sed '/^Output 7 role:/d' "$kernel_build_manifest" \
  > "$invalid_build_dir/sp11-kernel-build-manifest.txt"
set +e
missing_role_output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-missing-role" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${invalid_build_dir#"$repo_dir"/}/sp11-kernel-build-manifest.txt" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
missing_role_status=$?
set -e
[ "$missing_role_status" -eq 1 ]
printf '%s\n' "$missing_role_output" |
  grep -F 'missing required top-level field: Output 7 role' >/dev/null
[ ! -e "$repo_dir/build/release/$release_prefix-missing-role" ]

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
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${candidate#"$repo_dir"/}" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -F "$expected" >/dev/null
  [ ! -e "$repo_dir/build/release/$release_prefix-$label" ]
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
  if python3 "$repo_dir/scripts/validate-sp11-image-release-manifests.py" \
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
  if python3 "$repo_dir/scripts/validate-sp11-image-release-manifests.py" \
      --repo-dir "$repo_dir" \
      --support-commit "$support_commit" \
      --release-name "$release_prefix-cross-$url_contract_label" \
      --kernel-build-manifest "$kernel_build_manifest" \
      --kernel-release-manifest "$kernel_release_manifest" \
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

bound_output="$(env "${fixture_binding_env[@]}" "$helper" \
    --image "${image#"$repo_dir"/}" \
    --release-name "$release_prefix-bound" \
    --allow-dirty \
    --part-size-bytes 1024 \
    --kernel-source-asset "${bound_kernel_source#"$repo_dir"/}" \
    --touchscreen-source-asset "${bound_touch_source#"$repo_dir"/}" \
    --source-notice "${bound_notice#"$repo_dir"/}" \
    --kernel-build-manifest "${kernel_build_manifest#"$repo_dir"/}" \
    --kernel-release-manifest "${kernel_release_manifest#"$repo_dir"/}" \
    --touchscreen-module-manifest "${module_manifest#"$repo_dir"/}" \
    --image-build-manifest "${image_build_manifest#"$repo_dir"/}" 2>&1)"
printf '%s\n' "$bound_output" | grep -F 'Local draft only:' >/dev/null
bound_dir="$repo_dir/build/release/$release_prefix-bound"
for attached in \
  sp11-kernel-build-manifest.txt \
  sp11-kernel-release-manifest.txt \
  sp11-touchscreen-modules-manifest.txt \
  sp11-live-image-build-manifest.txt; do
  [ -s "$bound_dir/$attached" ]
  grep -F "  $attached" "$bound_dir/SHA256SUMS" >/dev/null
  grep -F "  $attached" "$bound_dir/SOURCE-SHA256SUMS" >/dev/null
done
(
  cd "$bound_dir"
  shasum -a 256 -c SHA256SUMS >/dev/null
  shasum -a 256 -c SOURCE-SHA256SUMS >/dev/null
)

echo 'Live-image corresponding-source release gate passed.'
