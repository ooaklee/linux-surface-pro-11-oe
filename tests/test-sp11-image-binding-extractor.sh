#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
extractor="$repo_dir/scripts/extract-sp11-image-bindings.sh"
support_helper="$repo_dir/scripts/sp11-support-tree-manifest.py"
temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-image-bindings.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected image-binding fixture: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

for tool in dd git grep mktemp python3 shasum stat truncate; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing fixture tool: $tool" >&2
    exit 1
  }
done
for linux_tool in fls fsstat icat istat mformat mke2fs parted sgdisk stat; do
  if ! command -v "$linux_tool" >/dev/null 2>&1; then
    echo "Skipping raw ext4 image-binding fixtures: $linux_tool is exercised in Linux CI."
    exit 0
  fi
done

temporary_root="$(mktemp -d "$temporary_parent/sp11-image-bindings.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
fixture_repo="$temporary_root/repo"
data_root="$temporary_root/data-root"
esp_root="$temporary_root/esp-root"
mkdir -p \
  "$fixture_repo/docs" "$fixture_repo/patches" "$fixture_repo/scripts" "$fixture_repo/tools" \
  "$data_root/iso" "$data_root/dtb" "$data_root/payload/kernel-debs" "$data_root/support" \
  "$esp_root/EFI/BOOT"
printf 'fixture readme\n' > "$fixture_repo/README.md"
printf 'fixture guide\n' > "$fixture_repo/docs/guide.md"
printf 'fixture patch\n' > "$fixture_repo/patches/fix.patch"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture_repo/scripts/install.sh"
printf 'fixture tool\n' > "$fixture_repo/tools/helper.txt"
chmod 755 "$fixture_repo/scripts/install.sh"
git -C "$fixture_repo" init --quiet --initial-branch=fixture
git -C "$fixture_repo" config user.name 'SP11 raw image fixture'
git -C "$fixture_repo" config user.email 'sp11-image@example.invalid'
git -C "$fixture_repo" add .
git -C "$fixture_repo" commit --quiet -m 'Create raw image support fixture'
support_commit="$(git -C "$fixture_repo" rev-parse 'HEAD^{commit}')"
(
  umask 022
  git -C "$fixture_repo" archive --format=tar "$support_commit" -- \
    README.md docs patches scripts tools | tar -x -C "$data_root/support"
)
python3 "$support_helper" \
  --repo-dir "$fixture_repo" \
  --commit "$support_commit" \
  --output "$data_root/support/.sp11-support-tree-v1" >/dev/null
python3 "$support_helper" \
  --repo-dir "$fixture_repo" \
  --commit "$support_commit" \
  --normalize-directory "$data_root/support" >/dev/null
printf 'fixture iso\n' > "$data_root/iso/ubuntu-x1e.iso"
printf 'fixture dtb\n' > "$data_root/dtb/sp11-denali.dtb"
printf 'fixture package\n' > "$data_root/payload/kernel-debs/linux-image-fixture.deb"
printf 'fixture EFI boot application\n' > "$esp_root/EFI/BOOT/BOOTAA64.EFI"
printf 'This USB boots Ubuntu for Surface Pro 11. See /support and /payload on SP11DATA.\n' \
  > "$esp_root/README.txt"

build_raw_image() {
  local label="$1" image data_image esp_image
  local layout="$temporary_root/$label.layout" esp_start start
  local image_size_bytes=$((640 * 1024 * 1024))
  local aligned_data_end
  local esp_label=SP11EFI data_label=SP11DATA esp_type=EF00 data_type=8300
  local esp_name=SP11EFI data_name=SP11DATA
  image="$temporary_root/$label.img"
  data_image="$temporary_root/$label.ext4"
  esp_image="$temporary_root/$label.esp"
  if [ "$label" = "non-mib-size" ]; then
    image_size_bytes=$((image_size_bytes + 512))
  fi
  aligned_data_end=$((image_size_bytes / 512 - 2049))
  truncate -s "$image_size_bytes" "$image"
  if [ "$label" = "non-gpt" ]; then
    parted -s "$image" mklabel msdos
    parted -s "$image" mkpart primary fat32 1MiB 513MiB
    parted -s "$image" mkpart primary ext4 513MiB 100%
    printf '%s\n' "$image"
    return 0
  fi
  case "$label" in
    wrong-esp-type) esp_type=8300 ;;
    wrong-data-type) data_type=8302 ;;
    wrong-gpt-name) esp_name=BROKEN ;;
    wrong-data-name) data_name=BROKEN ;;
    wrong-esp-label) esp_label=BROKEN ;;
    wrong-data-label) data_label=BROKEN ;;
  esac
  if [ "$label" = "wrong-geometry" ]; then
    sgdisk -o \
      -n 1:4096:+512M -t "1:$esp_type" -c "1:$esp_name" \
      -n 2:0:"$aligned_data_end" -t "2:$data_type" -c "2:$data_name" \
      "$image" >/dev/null
  elif [ "$label" = "extra-partition" ]; then
    sgdisk -o \
      -n 1:2048:+512M -t "1:$esp_type" -c "1:$esp_name" \
      -n 2:0:+64M -t "2:$data_type" -c "2:$data_name" \
      -n 3:0:0 -t 3:8300 -c 3:EXTRA \
      "$image" >/dev/null
  else
    sgdisk -o \
      -n 1:2048:+512M -t "1:$esp_type" -c "1:$esp_name" \
      -n 2:0:"$aligned_data_end" -t "2:$data_type" -c "2:$data_name" \
      "$image" >/dev/null
  fi
  if [ "$label" = "wrong-gpt-flags" ]; then
    sgdisk -A 1:set:2 "$image" >/dev/null
  fi
  parted -sm "$image" unit s print > "$layout"
  esp_start="$(awk -F: '$1 == "1" { gsub(/s$/, "", $2); print $2 }' "$layout")"
  start="$(awk -F: '$1 == "2" { gsub(/s$/, "", $2); print $2 }' "$layout")"
  truncate -s 512M "$esp_image"
  mformat -i "$esp_image" -F -v "$esp_label" ::
  mmd -i "$esp_image" ::/EFI ::/EFI/BOOT
  if [ -f "$esp_root/EFI/BOOT/BOOTAA64.EFI" ]; then
    mcopy -i "$esp_image" "$esp_root/EFI/BOOT/BOOTAA64.EFI" ::/EFI/BOOT/
  fi
  if [ -f "$esp_root/README.txt" ]; then
    mcopy -i "$esp_image" "$esp_root/README.txt" ::/
  fi
  if [ -f "$esp_root/EXTRA.txt" ]; then
    mcopy -i "$esp_image" "$esp_root/EXTRA.txt" ::/
  fi
  truncate -s 64M "$data_image"
  mke2fs -q -F -t ext4 -L "$data_label" -d "$data_root" "$data_image"
  dd if="$esp_image" of="$image" bs=512 seek="$esp_start" \
    conv=notrunc,sparse status=none
  dd if="$data_image" of="$image" bs=512 seek="$start" \
    conv=notrunc,sparse status=none
  if [ "$label" = "corrupt-backup-gpt" ]; then
    dd if=/dev/zero of="$image" bs=1 seek=$((640 * 1024 * 1024 - 512)) \
      count=8 conv=notrunc status=none
  fi
  if [ "$label" = "non-mib-size" ]; then
    [ "$(awk -F: '$1 == "2" { value = $3; sub(/s$/, "", value); print value }' "$layout")" = \
      "$((image_size_bytes / 512 - 2049))" ] || {
        echo 'non-MiB fixture does not satisfy the otherwise exact partition geometry' >&2
        exit 1
      }
    # Use one-sector verifier alignment here so this precondition checks only
    # primary/backup GPT integrity; the extractor's MiB gate owns alignment.
    sgdisk -a 1 -v "$image" > "$temporary_root/non-mib-size-gpt-verify.log" 2>&1
    [ "$(grep -Ec '^No problems found\.' \
      "$temporary_root/non-mib-size-gpt-verify.log" || true)" -eq 1 ] || {
        echo 'non-MiB fixture does not have a clean relocated backup GPT' >&2
        exit 1
      }
    if grep -Ev '^No problems found\.' "$temporary_root/non-mib-size-gpt-verify.log" |
        grep -Eiq 'warning|caution|mismatch|invalid|corrupt|error|problem'; then
      echo 'non-MiB fixture GPT verification reported a diagnostic' >&2
      exit 1
    fi
  fi
  printf '%s\n' "$image"
}

extract_image() {
  local image="$1" label="$2" output
  output="$temporary_root/output-$label"
  rm -rf -- "$output"
  mkdir "$output"
  bash "$extractor" --image "$image" --output-dir "$output"
}

valid_image="$(build_raw_image valid)"
extract_image "$valid_image" valid > "$temporary_root/valid.log"
python3 "$support_helper" \
  --repo-dir "$fixture_repo" \
  --commit "$support_commit" \
  --verify-manifest "$temporary_root/output-valid/embedded-support-manifest" \
  --actual-identities "$temporary_root/output-valid/actual-support-identities" >/dev/null
[ "$(cat "$temporary_root/output-valid/actual-embedded-iso-sha256")" = \
  "$(shasum -a 256 "$data_root/iso/ubuntu-x1e.iso" | awk '{print $1}')" ]
[ "$(cat "$temporary_root/output-valid/actual-embedded-dtb-sha256")" = \
  "$(shasum -a 256 "$data_root/dtb/sp11-denali.dtb" | awk '{print $1}')" ]
[ "$(cat "$temporary_root/output-valid/actual-esp-boot-size")" = \
  "$(wc -c < "$esp_root/EFI/BOOT/BOOTAA64.EFI" | tr -d '[:space:]')" ]
[ "$(cat "$temporary_root/output-valid/actual-esp-boot-sha256")" = \
  "$(shasum -a 256 "$esp_root/EFI/BOOT/BOOTAA64.EFI" | awk '{print $1}')" ]
[ "$(cat "$temporary_root/output-valid/actual-esp-readme-sha256")" = \
  "6163777e9eeca7cfb031dab492007471ed514ae99baea73c7da7de9ab51d0443" ]
grep -Fx 'Partition count: 2' "$temporary_root/output-valid/actual-image-layout" >/dev/null
grep -Fx 'Partition 1 flags: boot,esp' "$temporary_root/output-valid/actual-image-layout" >/dev/null
grep -Fx 'Partition 2 flags: none' "$temporary_root/output-valid/actual-image-layout" >/dev/null
for binding_output in "$temporary_root/output-valid"/*; do
  [ -f "$binding_output" ] && [ ! -L "$binding_output" ]
  [ "$(stat -c '%a' "$binding_output")" = "644" ] || {
    echo "binding output is not host-readable: $(basename "$binding_output")" >&2
    exit 1
  }
done
cp "$temporary_root/output-valid/actual-image-layout" "$temporary_root/expected-image-layout"

expect_extract_failure() {
  local label="$1" expected="$2" image
  image="$(build_raw_image "$label")"
  if extract_image "$image" "$label" > "$temporary_root/$label.log" 2>&1; then
    echo "raw image extractor accepted $label" >&2
    exit 1
  fi
  grep -Fqi "$expected" "$temporary_root/$label.log"
}

expect_extract_failure non-gpt 'partition table must be GPT'
expect_extract_failure corrupt-backup-gpt 'GPT verification'
expect_extract_failure non-mib-size 'whole number of MiB'
expect_extract_failure extra-partition 'exactly one disk record and two GPT partitions'
expect_extract_failure wrong-geometry 'SP11EFI partition geometry is not exact'
expect_extract_failure wrong-esp-type 'GPT partition'
expect_extract_failure wrong-data-type 'GPT partition'
expect_extract_failure wrong-gpt-name 'partition names are not exact'
expect_extract_failure wrong-data-name 'partition names are not exact'
expect_extract_failure wrong-gpt-flags 'GPT partition'
expect_extract_failure wrong-esp-label 'SP11EFI filesystem label is not exact'
expect_extract_failure wrong-data-label 'SP11DATA filesystem label is not exact'

cp "$esp_root/EFI/BOOT/BOOTAA64.EFI" "$temporary_root/BOOTAA64.EFI.original"
printf 'substituted EFI application\n' > "$esp_root/EFI/BOOT/BOOTAA64.EFI"
substituted_boot_image="$(build_raw_image substituted-boot)"
extract_image "$substituted_boot_image" substituted-boot >/dev/null
if cmp -s "$temporary_root/expected-image-layout" \
    "$temporary_root/output-substituted-boot/actual-image-layout"; then
  echo 'raw image extractor did not expose substituted EFI boot bytes' >&2
  exit 1
fi
grep -Fx 'ESP boot path: EFI/BOOT/BOOTAA64.EFI' \
  "$temporary_root/output-substituted-boot/actual-image-layout" >/dev/null
cp "$temporary_root/BOOTAA64.EFI.original" "$esp_root/EFI/BOOT/BOOTAA64.EFI"

mv "$esp_root/EFI/BOOT/BOOTAA64.EFI" "$temporary_root/BOOTAA64.EFI.missing"
expect_extract_failure missing-boot 'exact structural and file allowlist'
mv "$temporary_root/BOOTAA64.EFI.missing" "$esp_root/EFI/BOOT/BOOTAA64.EFI"

: > "$esp_root/EFI/BOOT/BOOTAA64.EFI"
expect_extract_failure empty-boot 'ESP file is empty'
cp "$temporary_root/BOOTAA64.EFI.original" "$esp_root/EFI/BOOT/BOOTAA64.EFI"

mv "$esp_root/README.txt" "$temporary_root/README.txt.missing"
expect_extract_failure missing-readme 'exact structural and file allowlist'
mv "$temporary_root/README.txt.missing" "$esp_root/README.txt"

cp "$esp_root/README.txt" "$temporary_root/README.txt.original"
printf 'substituted README bytes\n' > "$esp_root/README.txt"
expect_extract_failure substituted-readme 'README.txt bytes are not exact'
cp "$temporary_root/README.txt.original" "$esp_root/README.txt"

printf 'unexpected ESP bytes\n' > "$esp_root/EXTRA.txt"
expect_extract_failure extra-esp-file 'ESP contains an unexpected entry'
rm "$esp_root/EXTRA.txt"

cp "$data_root/support/docs/guide.md" "$temporary_root/guide.original"
printf 'tampered guide bytes\n' > "$data_root/support/docs/guide.md"
tampered_image="$(build_raw_image byte-tamper)"
extract_image "$tampered_image" byte-tamper >/dev/null
if python3 "$support_helper" \
    --repo-dir "$fixture_repo" \
    --commit "$support_commit" \
    --verify-manifest "$temporary_root/output-byte-tamper/embedded-support-manifest" \
    --actual-identities "$temporary_root/output-byte-tamper/actual-support-identities" \
    > "$temporary_root/byte-tamper.log" 2>&1; then
  echo 'committed-support comparator accepted raw-image byte tampering' >&2
  exit 1
fi
grep -Fq 'embedded support identity differs' "$temporary_root/byte-tamper.log"
cp "$temporary_root/guide.original" "$data_root/support/docs/guide.md"

chmod 600 "$data_root/support/docs/guide.md"
expect_extract_failure mode-flip 'wrong mode'
chmod 644 "$data_root/support/docs/guide.md"

chmod 600 "$data_root/iso/ubuntu-x1e.iso"
expect_extract_failure iso-mode 'wrong mode'
chmod 644 "$data_root/iso/ubuntu-x1e.iso"

chmod 600 "$data_root/payload/kernel-debs/linux-image-fixture.deb"
expect_extract_failure payload-mode 'wrong mode'
chmod 644 "$data_root/payload/kernel-debs/linux-image-fixture.deb"

printf 'unexpected support bytes\n' > "$data_root/support/docs/unexpected.md"
extra_image="$(build_raw_image extra-support)"
extract_image "$extra_image" extra-support >/dev/null
if python3 "$support_helper" \
    --repo-dir "$fixture_repo" \
    --commit "$support_commit" \
    --verify-manifest "$temporary_root/output-extra-support/embedded-support-manifest" \
    --actual-identities "$temporary_root/output-extra-support/actual-support-identities" \
    > "$temporary_root/extra-support.log" 2>&1; then
  echo 'committed-support comparator accepted an extra raw-image support file' >&2
  exit 1
fi
grep -Fq 'embedded support tree contains an unexpected path' "$temporary_root/extra-support.log"
rm "$data_root/support/docs/unexpected.md"

mv "$data_root/support/docs/guide.md" "$temporary_root/guide.missing"
missing_image="$(build_raw_image missing-support)"
extract_image "$missing_image" missing-support >/dev/null
if python3 "$support_helper" \
    --repo-dir "$fixture_repo" \
    --commit "$support_commit" \
    --verify-manifest "$temporary_root/output-missing-support/embedded-support-manifest" \
    --actual-identities "$temporary_root/output-missing-support/actual-support-identities" \
    > "$temporary_root/missing-support.log" 2>&1; then
  echo 'committed-support comparator accepted a missing raw-image support file' >&2
  exit 1
fi
grep -Fq 'embedded support tree is missing' "$temporary_root/missing-support.log"
mv "$temporary_root/guide.missing" "$data_root/support/docs/guide.md"

ln -s guide.md "$data_root/support/docs/link.md"
expect_extract_failure support-symlink 'symlink or special'
rm "$data_root/support/docs/link.md"

ln "$data_root/support/docs/guide.md" "$data_root/support/docs/hardlink.md"
expect_extract_failure support-hardlink 'hard-link'
rm "$data_root/support/docs/hardlink.md"

printf 'private payload\n' > "$data_root/payload/unexpected.txt"
expect_extract_failure payload-sibling 'only the kernel-debs directory'
rm "$data_root/payload/unexpected.txt"

printf 'private root bytes\n' > "$data_root/secret.txt"
expect_extract_failure root-file 'data root contains an unexpected entry'
rm "$data_root/secret.txt"

mkdir "$data_root/private-directory"
expect_extract_failure root-directory 'data root contains an unexpected entry'
rmdir "$data_root/private-directory"

chmod 755 "$data_root/support/.sp11-support-tree-v1"
expect_extract_failure manifest-mode 'mode 0644'
chmod 644 "$data_root/support/.sp11-support-tree-v1"

echo 'Raw SP11 image binding extractor fixtures passed.'
