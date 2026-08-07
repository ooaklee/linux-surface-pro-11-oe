#!/usr/bin/env bash
set -euo pipefail
umask 077

IMAGE=""
OUTPUT_DIR=""

usage() {
  echo "Usage: $0 --image RAW_IMAGE --output-dir DIR" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || { usage; exit 2; }; IMAGE="$2"; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for tool in awk chmod find fls fsstat grep icat istat parted sed sgdisk sha256sum sort tr wc; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -s "$IMAGE" ] && [ -f "$IMAGE" ] && [ ! -L "$IMAGE" ] ||
  die "raw image must be a non-empty regular, non-symlinked file"
[ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ] ||
  die "output directory must be a regular, non-symlinked directory"
if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "output directory must be empty"
fi

layout="$(mktemp)"
gpt_verify="$(mktemp)"
partition_one_info="$(mktemp)"
partition_two_info="$(mktemp)"
esp_fs_info="$(mktemp)"
data_fs_info="$(mktemp)"
esp_listing="$(mktemp)"
esp_orphans="$(mktemp)"
esp_file_temp="$(mktemp)"
root_listing="$(mktemp)"
payload_listing="$(mktemp)"
debs_listing="$(mktemp)"
support_listing="$(mktemp)"
support_seen_inodes="$(mktemp)"
support_temp="$(mktemp)"
structural_listing="$(mktemp)"
child_listing=""

cleanup() {
  rm -f -- \
    "$layout" "$gpt_verify" "$partition_one_info" "$partition_two_info" \
    "$esp_fs_info" "$data_fs_info" "$esp_listing" "$esp_orphans" \
    "$esp_file_temp" "$root_listing" "$payload_listing" "$debs_listing" \
    "$support_listing" "$support_seen_inodes" "$support_temp" "$structural_listing"
  [ -z "$child_listing" ] || rm -f -- "$child_listing"
}
trap cleanup EXIT HUP INT TERM

export LC_ALL=C
parted -sm "$IMAGE" unit s print > "$layout"
[ "$(sed -n '1p' "$layout")" = "BYT;" ] || die "image partition table is not machine-readable"
[ "$(wc -l < "$layout" | tr -d '[:space:]')" = "4" ] ||
  die "image must contain exactly one disk record and two GPT partitions"

image_size="$(wc -c < "$IMAGE" | tr -d '[:space:]')"
case "$image_size" in ""|*[!0-9]*) die "raw image has an invalid size" ;; esac
[ "$((image_size % 512))" -eq 0 ] || die "raw image size is not a whole number of sectors"
image_sectors=$((image_size / 512))
[ "$((image_sectors % 2048))" -eq 0 ] || die "raw image size is not a whole number of MiB"
disk_sectors="$(awk -F: 'NR == 2 { value = $2; sub(/s$/, "", value); print value }' "$layout")"
logical_sector="$(awk -F: 'NR == 2 { print $4 }' "$layout")"
physical_sector="$(awk -F: 'NR == 2 { print $5 }' "$layout")"
partition_table="$(awk -F: 'NR == 2 { print $6 }' "$layout")"
[ "$disk_sectors" = "$image_sectors" ] || die "GPT disk size does not match the raw image"
[ "$logical_sector" = "512" ] && [ "$physical_sector" = "512" ] ||
  die "image must use 512-byte logical and physical sectors"
[ "$partition_table" = "gpt" ] || die "image partition table must be GPT"

partition_count="$(awk -F: '$1 ~ /^[0-9]+$/ { count++ } END { print count + 0 }' "$layout")"
[ "$partition_count" = "2" ] || die "image must contain exactly two GPT partitions"

partition_value() {
  local number="$1" field="$2" value
  value="$(awk -F: -v number="$number" -v field="$field" \
    '$1 == number { print $field }' "$layout")"
  case "$field" in 2|3|4) value="${value%s}" ;; esac
  case "$field" in 7) value="${value%;}"; value="$(printf '%s' "$value" | tr -d '[:space:]')" ;; esac
  printf '%s\n' "$value"
}

esp_start="$(partition_value 1 2)"
esp_end="$(partition_value 1 3)"
esp_sectors="$(partition_value 1 4)"
esp_filesystem="$(partition_value 1 5)"
esp_name="$(partition_value 1 6)"
esp_flags="$(partition_value 1 7)"
data_start="$(partition_value 2 2)"
data_end="$(partition_value 2 3)"
data_sectors="$(partition_value 2 4)"
data_filesystem="$(partition_value 2 5)"
data_name="$(partition_value 2 6)"
data_flags="$(partition_value 2 7)"
[ -n "$data_flags" ] || data_flags="none"

[ "$esp_start" = "2048" ] && [ "$esp_end" = "1050623" ] &&
  [ "$esp_sectors" = "1048576" ] || die "SP11EFI partition geometry is not exact"
[ "$data_start" = "1050624" ] || die "SP11DATA partition start is not exact"
expected_data_end=$((image_sectors - 2049))
expected_data_sectors=$((expected_data_end - 1050624 + 1))
[ "$data_end" = "$expected_data_end" ] && [ "$data_sectors" = "$expected_data_sectors" ] ||
  die "SP11DATA partition does not end at the exact aligned sector"
[ "$esp_name" = "SP11EFI" ] && [ "$data_name" = "SP11DATA" ] ||
  die "GPT partition names are not exact"
[ "$esp_flags" = "boot,esp" ] && [ "$data_flags" = "none" ] ||
  die "GPT partition flags are not exact"

sgdisk -v "$IMAGE" > "$gpt_verify" 2>&1 || {
  cat "$gpt_verify" >&2
  die "GPT primary or backup metadata is invalid"
}
clean_gpt_result_count="$(grep -Ec '^No problems found\.' "$gpt_verify" || true)"
[ "$clean_gpt_result_count" = "1" ] || {
  cat "$gpt_verify" >&2
  die "GPT verification did not report one unequivocally clean result"
}
if grep -Ev '^No problems found\.' "$gpt_verify" |
    grep -Eiq 'warning|caution|mismatch|invalid|corrupt|error|problem'; then
  cat "$gpt_verify" >&2
  die "GPT verification reported a primary or backup metadata diagnostic"
fi
sgdisk -i 1 "$IMAGE" > "$partition_one_info"
sgdisk -i 2 "$IMAGE" > "$partition_two_info"
partition_info_value() {
  local source="$1" label="$2"
  awk -F: -v label="$label" '$1 == label {
    value = $2; sub(/^[[:space:]]*/, "", value); sub(/[[:space:]].*$/, "", value); print value
  }' "$source"
}
partition_info_name() {
  awk -F"'" '$1 ~ /^Partition name:/ { print $2 }' "$1"
}
esp_type_guid="$(partition_info_value "$partition_one_info" "Partition GUID code")"
data_type_guid="$(partition_info_value "$partition_two_info" "Partition GUID code")"
[ "$esp_type_guid" = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ] &&
  [ "$data_type_guid" = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ] ||
  die "GPT partition type GUIDs are not exact"
[ "$(partition_info_name "$partition_one_info")" = "SP11EFI" ] &&
  [ "$(partition_info_name "$partition_two_info")" = "SP11DATA" ] ||
  die "sgdisk partition names disagree with the expected GPT names"
[ "$(partition_info_value "$partition_one_info" "First sector")" = "$esp_start" ] &&
  [ "$(partition_info_value "$partition_one_info" "Last sector")" = "$esp_end" ] &&
  [ "$(partition_info_value "$partition_one_info" "Partition size")" = "$esp_sectors" ] &&
  [ "$(partition_info_value "$partition_two_info" "First sector")" = "$data_start" ] &&
  [ "$(partition_info_value "$partition_two_info" "Last sector")" = "$data_end" ] &&
  [ "$(partition_info_value "$partition_two_info" "Partition size")" = "$data_sectors" ] ||
  die "sgdisk partition geometry disagrees with parted"
[ "$(partition_info_value "$partition_one_info" "Attribute flags")" = "0000000000000000" ] &&
  [ "$(partition_info_value "$partition_two_info" "Attribute flags")" = "0000000000000000" ] ||
  die "GPT partition attributes are not zero"

fsstat -o "$esp_start" "$IMAGE" > "$esp_fs_info"
fsstat -o "$data_start" "$IMAGE" > "$data_fs_info"
fs_value() {
  local source="$1" label="$2"
  awk -F: -v label="$label" '$1 == label {
    value = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
  }' "$source"
}
[ "$(fs_value "$esp_fs_info" "File System Type")" = "FAT32" ] ||
  die "SP11EFI filesystem is not FAT32"
[ "$(fs_value "$esp_fs_info" "Volume Label (Boot Sector)")" = "SP11EFI" ] &&
  [ "$(fs_value "$esp_fs_info" "Volume Label (Root Directory)")" = "SP11EFI" ] ||
  die "SP11EFI filesystem label is not exact"
[ "$(fs_value "$data_fs_info" "File System Type")" = "Ext4" ] ||
  die "SP11DATA filesystem is not ext4"
[ "$(fs_value "$data_fs_info" "Volume Name")" = "SP11DATA" ] ||
  die "SP11DATA filesystem label is not exact"
[ "$esp_filesystem" = "fat32" ] && [ "$data_filesystem" = "ext4" ] ||
  die "parted filesystem identities are not exact"

fls -r -p -o "$esp_start" "$IMAGE" > "$esp_listing"
esp_label_count=0
esp_efi_count=0
esp_boot_dir_count=0
esp_boot_file_count=0
esp_readme_count=0
esp_mbr_count=0
esp_fat1_count=0
esp_fat2_count=0
esp_orphan_count=0
esp_boot_inode=""
esp_readme_inode=""
while IFS="$(printf '\t')" read -r entry_metadata entry_name; do
  [ -n "$entry_metadata" ] && [ -n "$entry_name" ] || die "ESP contains an ambiguous entry"
  set -- $entry_metadata
  [ "$#" -eq 2 ] || die "ESP entry metadata is ambiguous"
  entry_type="$1"
  entry_inode="${2%:}"
  case "$entry_inode" in ""|*[!0-9]*) die "ESP entry has an unsafe inode" ;; esac
  case "$entry_name" in
    *"(Volume Label Entry)")
      normalized_label="${entry_name% (Volume Label Entry)}"
      normalized_label="$(printf '%s' "$normalized_label" | sed 's/[[:space:]]*$//')"
      [ "$entry_type" = "r/r" ] && [ "$normalized_label" = "SP11EFI" ] ||
        die "ESP volume-label entry is not exact"
      esp_label_count=$((esp_label_count + 1))
      ;;
    EFI)
      [ "$entry_type" = "d/d" ] || die "ESP /EFI is not a directory"
      esp_efi_count=$((esp_efi_count + 1))
      ;;
    EFI/BOOT)
      [ "$entry_type" = "d/d" ] || die "ESP /EFI/BOOT is not a directory"
      esp_boot_dir_count=$((esp_boot_dir_count + 1))
      ;;
    EFI/BOOT/BOOTAA64.EFI)
      [ "$entry_type" = "r/r" ] || die "ESP BOOTAA64.EFI is not a regular file"
      esp_boot_inode="$entry_inode"
      esp_boot_file_count=$((esp_boot_file_count + 1))
      ;;
    README.txt)
      [ "$entry_type" = "r/r" ] || die "ESP README.txt is not a regular file"
      esp_readme_inode="$entry_inode"
      esp_readme_count=$((esp_readme_count + 1))
      ;;
    '$MBR') [ "$entry_type" = "v/v" ] || die "ESP \$MBR entry has the wrong type"; esp_mbr_count=$((esp_mbr_count + 1)) ;;
    '$FAT1') [ "$entry_type" = "v/v" ] || die "ESP \$FAT1 entry has the wrong type"; esp_fat1_count=$((esp_fat1_count + 1)) ;;
    '$FAT2') [ "$entry_type" = "v/v" ] || die "ESP \$FAT2 entry has the wrong type"; esp_fat2_count=$((esp_fat2_count + 1)) ;;
    '$OrphanFiles')
      [ "$entry_type" = "V/V" ] || die "ESP \$OrphanFiles entry has the wrong type"
      esp_orphan_count=$((esp_orphan_count + 1))
      : > "$esp_orphans"
      fls -o "$esp_start" "$IMAGE" "$entry_inode" > "$esp_orphans"
      [ ! -s "$esp_orphans" ] || die "ESP \$OrphanFiles is not empty"
      ;;
    *) die "ESP contains an unexpected entry: $entry_name" ;;
  esac
done < "$esp_listing"
for count in \
  "$esp_label_count" "$esp_efi_count" "$esp_boot_dir_count" "$esp_boot_file_count" \
  "$esp_readme_count" "$esp_mbr_count" "$esp_fat1_count" "$esp_fat2_count" \
  "$esp_orphan_count"; do
  [ "$count" -eq 1 ] || die "ESP does not contain its exact structural and file allowlist"
done
[ "$esp_boot_inode" != "$esp_readme_inode" ] || die "ESP files reuse an inode"

extract_esp_file_identity() {
  local inode="$1" path="$2" size_output="$3" hash_output="$4" require_nonempty="$5"
  local metadata metadata_size actual_size actual_hash
  metadata="$(istat -o "$esp_start" "$IMAGE" "$inode")"
  printf '%s\n' "$metadata" | grep -Fxq Allocated || die "ESP file is not allocated: $path"
  printf '%s\n' "$metadata" | grep -Eq '^File Attributes:.*File' ||
    die "ESP entry is not a regular file: $path"
  metadata_size="$(printf '%s\n' "$metadata" | awk -F: '$1 == "Size" {
    value = $2; gsub(/[[:space:]]/, "", value); print value; exit
  }')"
  case "$metadata_size" in ""|*[!0-9]*) die "ESP file has an invalid size: $path" ;; esac
  icat -o "$esp_start" "$IMAGE" "$inode" > "$esp_file_temp"
  actual_size="$(wc -c < "$esp_file_temp" | tr -d '[:space:]')"
  [ "$actual_size" = "$metadata_size" ] || die "ESP file size metadata is inconsistent: $path"
  if [ "$require_nonempty" = "true" ]; then
    [ "$actual_size" -gt 0 ] || die "ESP file is empty: $path"
  fi
  actual_hash="$(sha256sum "$esp_file_temp" | awk '{print $1}')"
  printf '%s\n' "$actual_size" > "$OUTPUT_DIR/$size_output"
  printf '%s\n' "$actual_hash" > "$OUTPUT_DIR/$hash_output"
}

extract_esp_file_identity "$esp_boot_inode" EFI/BOOT/BOOTAA64.EFI \
  actual-esp-boot-size actual-esp-boot-sha256 true
extract_esp_file_identity "$esp_readme_inode" README.txt \
  actual-esp-readme-size actual-esp-readme-sha256 true
actual_readme_size="$(sed -n '1p' "$OUTPUT_DIR/actual-esp-readme-size")"
actual_readme_sha="$(sed -n '1p' "$OUTPUT_DIR/actual-esp-readme-sha256")"
[ "$actual_readme_size" = "81" ] &&
  [ "$actual_readme_sha" = "6163777e9eeca7cfb031dab492007471ed514ae99baea73c7da7de9ab51d0443" ] ||
  die "ESP README.txt bytes are not exact"

cat > "$OUTPUT_DIR/actual-image-layout" <<EOF_LAYOUT
Partition table: gpt
Logical sector size: 512
Partition count: 2
Partition 1 start sector: $esp_start
Partition 1 end sector: $esp_end
Partition 1 sector count: $esp_sectors
Partition 1 type GUID: $esp_type_guid
Partition 1 name: $esp_name
Partition 1 flags: $esp_flags
Partition 1 filesystem: fat32
Partition 1 filesystem label: SP11EFI
Partition 2 start sector: $data_start
Partition 2 end sector: $data_end
Partition 2 sector count: $data_sectors
Partition 2 type GUID: $data_type_guid
Partition 2 name: $data_name
Partition 2 flags: $data_flags
Partition 2 filesystem: ext4
Partition 2 filesystem label: SP11DATA
ESP boot path: EFI/BOOT/BOOTAA64.EFI
ESP boot size: $(sed -n '1p' "$OUTPUT_DIR/actual-esp-boot-size")
ESP boot SHA256: $(sed -n '1p' "$OUTPUT_DIR/actual-esp-boot-sha256")
ESP README path: README.txt
ESP README size: $actual_readme_size
ESP README SHA256: $actual_readme_sha
EOF_LAYOUT

fls -o "$data_start" "$IMAGE" > "$root_listing"

iso_root_count=0
dtb_root_count=0
payload_root_count=0
support_root_count=0
lost_found_count=0
orphan_files_count=0
require_root_directory_mode() {
  local inode="$1" name="$2" metadata mode
  metadata="$(istat -o "$data_start" "$IMAGE" "$inode")"
  mode="$(printf '%s\n' "$metadata" |
    awk -F: 'tolower($1) ~ /^[[:space:]]*mode$/ {
      value = $2; sub(/^[[:space:]]*/, "", value); print value; exit
    }')"
  { [ "$mode" = "drwxr-xr-x" ] || [ "$mode" = "rwxr-xr-x" ]; } ||
    die "image /$name directory has the wrong mode: $mode"
}
while read -r entry_type entry_inode entry_name extra; do
  [ -n "$entry_type" ] && [ -n "$entry_inode" ] && [ -n "$entry_name" ] &&
    [ -z "${extra:-}" ] || die "image data root contains an ambiguous entry"
  inode="${entry_inode%:}"
  case "$inode" in ""|*[!0-9]*) die "image data root entry has an unsafe inode" ;; esac
  case "$entry_name" in
    iso)
      [ "$entry_type" = "d/d" ] || die "image /iso entry is not a directory"
      require_root_directory_mode "$inode" iso
      iso_root_count=$((iso_root_count + 1))
      ;;
    dtb)
      [ "$entry_type" = "d/d" ] || die "image /dtb entry is not a directory"
      require_root_directory_mode "$inode" dtb
      dtb_root_count=$((dtb_root_count + 1))
      ;;
    payload)
      [ "$entry_type" = "d/d" ] || die "image /payload entry is not a directory"
      require_root_directory_mode "$inode" payload
      payload_root_count=$((payload_root_count + 1))
      ;;
    support)
      [ "$entry_type" = "d/d" ] || die "image /support entry is not a directory"
      require_root_directory_mode "$inode" support
      support_root_count=$((support_root_count + 1))
      ;;
    lost+found)
      [ "$entry_type" = "d/d" ] || die "image /lost+found entry is not a directory"
      lost_found_count=$((lost_found_count + 1))
      : > "$structural_listing"
      fls -o "$data_start" "$IMAGE" "$inode" > "$structural_listing"
      [ ! -s "$structural_listing" ] || die "image /lost+found is not empty"
      ;;
    '$OrphanFiles')
      [ "$entry_type" = "V/V" ] || die "image /\$OrphanFiles has an unexpected type"
      orphan_files_count=$((orphan_files_count + 1))
      : > "$structural_listing"
      fls -o "$data_start" "$IMAGE" "$inode" > "$structural_listing"
      [ ! -s "$structural_listing" ] || die "image /\$OrphanFiles is not empty"
      ;;
    *) die "image data root contains an unexpected entry: $entry_name" ;;
  esac
done < "$root_listing"
[ "$iso_root_count" -eq 1 ] && [ "$dtb_root_count" -eq 1 ] &&
  [ "$payload_root_count" -eq 1 ] && [ "$support_root_count" -eq 1 ] ||
  die "image data root must contain exactly one iso, dtb, payload, and support directory"
[ "$lost_found_count" -le 1 ] && [ "$orphan_files_count" -le 1 ] ||
  die "image data root repeats a structural filesystem entry"

require_regular_file_metadata() {
  local inode="$1" name="$2" metadata mode link_count
  metadata="$(istat -o "$data_start" "$IMAGE" "$inode")"
  mode="$(printf '%s\n' "$metadata" |
    awk -F: 'tolower($1) ~ /^[[:space:]]*mode$/ {
      value = $2; sub(/^[[:space:]]*/, "", value); print value; exit
    }')"
  link_count="$(printf '%s\n' "$metadata" |
    awk -F: 'tolower($1) ~ /^[[:space:]]*num of links$/ {
      value = $2; sub(/^[[:space:]]*/, "", value); print value; exit
    }')"
  { [ "$mode" = "rrw-r--r--" ] || [ "$mode" = "rw-r--r--" ]; } ||
    die "image file has the wrong mode: $name ($mode)"
  [ "$link_count" = "1" ] || die "image file has an unsafe hard-link count: $name"
}

payload_inode="$(awk '$1 == "d/d" && $3 == "payload" { sub(/:/, "", $2); print $2 }' "$root_listing")"
[ "$(printf '%s\n' "$payload_inode" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
  die "image must contain exactly one /payload directory"
fls -o "$data_start" "$IMAGE" "$payload_inode" > "$payload_listing"
debs_inode="$(awk '$1 == "d/d" && $3 == "kernel-debs" { sub(/:/, "", $2); print $2 }' "$payload_listing")"
[ "$(printf '%s\n' "$debs_inode" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
  die "image must contain exactly one /payload/kernel-debs directory"
if awk '$1 != "d/d" || $3 != "kernel-debs" || NF != 3 { found = 1 }
        END { exit found ? 0 : 1 }' "$payload_listing"; then
  die "image /payload must contain only the kernel-debs directory"
fi
fls -o "$data_start" "$IMAGE" "$debs_inode" > "$debs_listing"
if awk '$1 != "r/r" || NF != 3 { found = 1 } END { exit found ? 0 : 1 }' "$debs_listing"; then
  die "image kernel-debs payload contains an unexpected non-regular or ambiguous entry"
fi
actual_payload="$OUTPUT_DIR/actual-payload-sha256"
: > "$actual_payload"
while read -r entry_type entry_inode entry_name extra; do
  [ "$entry_type" = "r/r" ] && [ -n "$entry_inode" ] && [ -n "$entry_name" ] &&
    [ -z "${extra:-}" ] || die "image kernel-debs listing contains an ambiguous entry"
  case "$entry_name" in
    ""|*[!A-Za-z0-9._+-]*) die "image kernel-debs listing has an unsafe filename" ;;
  esac
  inode="${entry_inode%:}"
  case "$inode" in ""|*[!0-9]*) die "image payload entry has an unsafe inode" ;; esac
  require_regular_file_metadata "$inode" "/payload/kernel-debs/$entry_name"
  actual_sha="$(icat -o "$data_start" "$IMAGE" "$inode" | sha256sum | awk '{print $1}')"
  printf '%s  %s\n' "$actual_sha" "$entry_name" >> "$actual_payload"
done < "$debs_listing"
[ -s "$actual_payload" ] || die "image kernel-debs payload contains no regular files"

extract_exact_regular_child_hash() {
  local directory_name="$1" file_name="$2" output_name="$3"
  local directory_inode file_inode actual_hash
  directory_inode="$(awk -v name="$directory_name" \
    '$1 == "d/d" && $3 == name { sub(/:/, "", $2); print $2 }' "$root_listing")"
  [ "$(printf '%s\n' "$directory_inode" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
    die "image must contain exactly one /$directory_name directory"
  child_listing="$(mktemp)"
  fls -o "$data_start" "$IMAGE" "$directory_inode" > "$child_listing"
  file_inode="$(awk -v name="$file_name" \
    '$1 == "r/r" && $3 == name { sub(/:/, "", $2); print $2 }' "$child_listing")"
  [ "$(printf '%s\n' "$file_inode" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
    die "image must contain exactly one /$directory_name/$file_name file"
  if awk -v name="$file_name" '$1 != "r/r" || $3 != name || NF != 3 { found = 1 }
          END { exit found ? 0 : 1 }' "$child_listing"; then
    die "image /$directory_name contains an unexpected entry"
  fi
  require_regular_file_metadata "$file_inode" "/$directory_name/$file_name"
  actual_hash="$(icat -o "$data_start" "$IMAGE" "$file_inode" | sha256sum | awk '{print $1}')"
  printf '%s\n' "$actual_hash" > "$OUTPUT_DIR/$output_name"
  rm -f -- "$child_listing"
  child_listing=""
}

extract_exact_regular_child_hash iso ubuntu-x1e.iso actual-embedded-iso-sha256
extract_exact_regular_child_hash dtb sp11-denali.dtb actual-embedded-dtb-sha256

support_inode="$(awk '$1 == "d/d" && $3 == "support" { sub(/:/, "", $2); print $2 }' "$root_listing")"
[ "$(printf '%s\n' "$support_inode" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] ||
  die "image must contain exactly one /support directory"
fls -r -p -o "$data_start" "$IMAGE" "$support_inode" > "$support_listing"
[ -s "$support_listing" ] || die "image /support is empty"
actual_support="$OUTPUT_DIR/actual-support-identities"
embedded_support="$OUTPUT_DIR/embedded-support-manifest"
: > "$actual_support"
manifest_count=0
while read -r entry_type entry_inode entry_name extra; do
  [ -n "$entry_type" ] && [ -n "$entry_inode" ] && [ -n "$entry_name" ] &&
    [ -z "${extra:-}" ] || die "image support listing contains an ambiguous entry"
  case "$entry_type" in
    r/r|d/d) ;;
    *) die "image support tree contains a symlink or special entry: $entry_name" ;;
  esac
  case "$entry_name" in
    ""|/*|*//*|*"/../"*|../*|*/..|*"/./"*|./*|*/.|*[!A-Za-z0-9._+/-]*)
      die "image support tree contains an unsafe path"
      ;;
  esac
  inode="${entry_inode%:}"
  case "$inode" in ""|*[!0-9]*) die "image support entry has an unsafe inode" ;; esac
  if grep -Fxq "$inode" "$support_seen_inodes"; then
    die "image support tree reuses an inode (hard link): $entry_name"
  fi
  printf '%s\n' "$inode" >> "$support_seen_inodes"
  istat_output="$(istat -o "$data_start" "$IMAGE" "$inode")"
  mode="$(printf '%s\n' "$istat_output" |
    awk -F: 'tolower($1) ~ /^[[:space:]]*mode$/ {
      value = $2; sub(/^[[:space:]]*/, "", value); print value; exit
    }')"
  link_count="$(printf '%s\n' "$istat_output" |
    awk -F: 'tolower($1) ~ /^[[:space:]]*num of links$/ {
      value = $2; sub(/^[[:space:]]*/, "", value); print value; exit
    }')"
  if [ "$entry_type" = "d/d" ]; then
    { [ "$mode" = "drwxr-xr-x" ] || [ "$mode" = "rwxr-xr-x" ]; } ||
      die "image support directory has the wrong mode: $entry_name"
    printf 'd 040755 0 - %s\n' "$entry_name" >> "$actual_support"
    continue
  fi
  [ "$link_count" = "1" ] || die "image support file has an unsafe hard-link count: $entry_name"
  case "$mode" in
    rrw-r--r--|rw-r--r--) git_mode=100644 ;;
    rrwxr-xr-x|rwxr-xr-x) git_mode=100755 ;;
    *) die "image support file has the wrong mode: $entry_name ($mode)" ;;
  esac
  if [ "$entry_name" = ".sp11-support-tree-v1" ]; then
    [ "$git_mode" = "100644" ] || die "embedded support manifest must have mode 0644"
    manifest_count=$((manifest_count + 1))
    [ "$manifest_count" -eq 1 ] || die "image support tree repeats its generated manifest"
    icat -o "$data_start" "$IMAGE" "$inode" > "$embedded_support"
    continue
  fi
  icat -o "$data_start" "$IMAGE" "$inode" > "$support_temp"
  file_size="$(wc -c < "$support_temp" | tr -d '[:space:]')"
  file_sha="$(sha256sum "$support_temp" | awk '{print $1}')"
  printf 'f %s %s %s %s\n' "$git_mode" "$file_size" "$file_sha" "$entry_name" \
    >> "$actual_support"
done < "$support_listing"
[ "$manifest_count" -eq 1 ] && [ -s "$embedded_support" ] ||
  die "image support tree is missing its generated manifest"
LC_ALL=C sort "$actual_support" -o "$actual_support"

binding_output_count=0
for binding_output_name in \
  actual-payload-sha256 \
  embedded-support-manifest \
  actual-support-identities \
  actual-image-layout \
  actual-embedded-iso-sha256 \
  actual-embedded-dtb-sha256 \
  actual-esp-boot-size \
  actual-esp-boot-sha256 \
  actual-esp-readme-size \
  actual-esp-readme-sha256; do
  binding_output="$OUTPUT_DIR/$binding_output_name"
  [ -f "$binding_output" ] && [ ! -L "$binding_output" ] ||
    die "binding output is not a regular file: $binding_output_name"
  chmod 0644 "$binding_output"
  binding_output_count=$((binding_output_count + 1))
done
[ "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" = \
  "$binding_output_count" ] || die "binding output directory contains an unexpected entry"

echo "Extracted exact GPT, ESP, payload, ISO, DTB, and support identities."
