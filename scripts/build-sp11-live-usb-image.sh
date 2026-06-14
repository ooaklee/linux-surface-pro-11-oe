#!/usr/bin/env bash
set -euo pipefail

ISO=""
DTB="auto"
OUT="build/sp11-ubuntu-live.img"
PAYLOAD_DIR="payload"
WORK_DIR="build/work"
IMAGE_EXTRA_MB=1536
VALIDATE="false"
VALIDATE_IMAGE=""
GRUB_MODE="menu"

usage() {
  cat <<EOF
Usage: $0 --iso ISO [options]
       $0 --validate-image IMAGE

Options:
  --iso PATH_OR_URL      Ubuntu ARM64+X1E concept ISO.
  --dtb PATH_OR_AUTO     Surface Pro 11 Denali DTB, default auto.
  --out PATH             Output raw disk image, default $OUT.
  --payload DIR          Optional payload directory, default payload.
  --work-dir DIR         Temporary build directory, default $WORK_DIR.
  --extra-mb MB          Free space on data partition, default $IMAGE_EXTRA_MB.
  --grub-mode MODE       GRUB config mode: menu or direct, default $GRUB_MODE.
  --validate             Validate the finished image after building.
  --validate-image PATH  Validate an existing image and exit.

The builder uses Docker with an ARM64 Ubuntu container so macOS can create a
bootable ARM64 GRUB image without loop-mounting Linux filesystems locally.
When --dtb auto is used, the builder tries to extract an X1E Surface Pro 11
Denali DTB from the ISO's files or casper squashfs layers.
EOF
}

validate_image() {
  local image="$1"
  local expect_kernel_debs image_dir image_base

  if [ ! -f "$image" ]; then
    echo "Image not found: $image" >&2
    exit 1
  fi

  expect_kernel_debs="${SP11_EXPECT_KERNEL_DEBS:-false}"
  image_dir="$(cd "$(dirname "$image")" && pwd)"
  image_base="$(basename "$image")"

  docker run --rm -i --platform linux/arm64 \
    -e "SP11_EXPECT_KERNEL_DEBS=$expect_kernel_debs" \
    -v "$image_dir:/image:ro" \
    ubuntu:24.04 \
    bash -s -- "$image_base" <<'EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  binutils \
  coreutils \
  file \
  gdisk \
  mtools \
  parted \
  sleuthkit \
  >/dev/null

image="/image/$1"
expect_kernel_debs="${SP11_EXPECT_KERNEL_DEBS:-false}"
layout="$(mktemp)"
dtb_copy="$(mktemp)"
boot_copy="$(mktemp)"

echo "== Image =="
ls -lh "$image"
du -h "$image"
sha256sum "$image"
file "$image"

echo
echo "== GPT =="
sgdisk -p "$image"
sgdisk -v "$image"
parted -sm "$image" unit s print | tee "$layout"

esp_start="$(awk -F: '$1 == "1" { gsub(/s$/, "", $2); print $2 }' "$layout")"
data_start="$(awk -F: '$1 == "2" { gsub(/s$/, "", $2); print $2 }' "$layout")"

if [ -z "$esp_start" ] || [ -z "$data_start" ]; then
  echo "Could not determine ESP/data partition offsets." >&2
  exit 1
fi

echo
echo "== ESP =="
mdir -i "$image@@$((esp_start * 512))" ::/
mdir -i "$image@@$((esp_start * 512))" ::/EFI/BOOT
mcopy -i "$image@@$((esp_start * 512))" ::/EFI/BOOT/BOOTAA64.EFI "$boot_copy"
strings "$boot_copy" |
  grep -E "sp11_grub_mode|USB-safe|casper iso-scan|ISO-native|insmod fdt|sp11-denali" |
  sed -n "1,120p"

echo
echo "== Data Partition =="
fls -o "$data_start" "$image"
dtb_inode="$(
  fls -o "$data_start" "$image" |
    awk '$3 == "dtb" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$dtb_inode" ]; then
  echo "Missing /dtb directory on SP11DATA." >&2
  exit 1
fi

fls -o "$data_start" "$image" "$dtb_inode"
dtb_file_inode="$(
  fls -o "$data_start" "$image" "$dtb_inode" |
    awk '$3 == "sp11-denali.dtb" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$dtb_file_inode" ]; then
  echo "Missing /dtb/sp11-denali.dtb on SP11DATA." >&2
  exit 1
fi

icat -o "$data_start" "$image" "$dtb_file_inode" > "$dtb_copy"
ls -lh "$dtb_copy"
sha256sum "$dtb_copy"
file "$dtb_copy"

payload_inode="$(
  fls -o "$data_start" "$image" |
    awk '$3 == "payload" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$payload_inode" ]; then
  if [ "$expect_kernel_debs" = "true" ]; then
    echo "Missing /payload on SP11DATA; expected kernel deb payload." >&2
    exit 1
  fi
elif [ -n "$payload_inode" ]; then
  echo
  echo "== Payload =="
  fls -o "$data_start" "$image" "$payload_inode"
  kernel_debs_inode="$(
    fls -o "$data_start" "$image" "$payload_inode" |
      awk '$3 == "kernel-debs" { sub(/:/, "", $2); print $2; exit }'
  )"
  if [ -z "$kernel_debs_inode" ]; then
    if [ "$expect_kernel_debs" = "true" ]; then
      echo "Missing /payload/kernel-debs on SP11DATA; expected kernel deb payload." >&2
      exit 1
    fi
  elif [ -n "$kernel_debs_inode" ]; then
    kernel_debs_listing="$(mktemp)"
    fls -o "$data_start" "$image" "$kernel_debs_inode" | tee "$kernel_debs_listing"
    if ! awk '$3 ~ /\.deb$/ { found = 1 } END { exit found ? 0 : 1 }' "$kernel_debs_listing"; then
      echo "Missing .deb files under /payload/kernel-debs on SP11DATA." >&2
      exit 1
    fi
  fi
fi

echo
echo "== Support Helpers =="
support_listing="$(mktemp)"
fls -r -p -o "$data_start" "$image" > "$support_listing"
install_helper_inode="$(
  awk '$0 ~ /support\/scripts\/install-sp11-support\.sh$/ { sub(/:/, "", $2); print $2; exit }' "$support_listing"
)"
if [ -z "$install_helper_inode" ]; then
  echo "Missing /support/scripts/install-sp11-support.sh on SP11DATA." >&2
  exit 1
fi

install_helper_copy="$(mktemp)"
icat -o "$data_start" "$image" "$install_helper_inode" > "$install_helper_copy"
if ! grep -F -q 'rfkill_candidates=()' "$install_helper_copy"; then
  echo "Support helper is missing rfkill-capable DTB candidate tracking." >&2
  exit 1
fi
if ! grep -F -q "grep -a -q 'disable-rfkill' \"\$path\"" "$install_helper_copy"; then
  echo "Support helper is missing disable-rfkill DTB inspection." >&2
  exit 1
fi
if ! grep -F -q '${rfkill_candidates[@]}' "$install_helper_copy"; then
  echo "Support helper is missing rfkill-capable DTB preference selection." >&2
  exit 1
fi
if ! grep -F -q 'Using Surface Pro 11 DTB:' "$install_helper_copy"; then
  echo "Support helper is missing the DTB selection log marker." >&2
  exit 1
fi
grep -F -n 'Using Surface Pro 11 DTB:' "$install_helper_copy"
grep -F -n 'rfkill_candidates=()' "$install_helper_copy"
grep -F -n "grep -a -q 'disable-rfkill' \"\$path\"" "$install_helper_copy"
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso)
      ISO="$2"
      shift 2
      ;;
    --dtb)
      DTB="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    --payload)
      PAYLOAD_DIR="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --extra-mb)
      IMAGE_EXTRA_MB="$2"
      shift 2
      ;;
    --grub-mode)
      GRUB_MODE="$2"
      shift 2
      ;;
    --validate)
      VALIDATE="true"
      shift
      ;;
    --validate-image)
      VALIDATE_IMAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required for the image builder and validator." >&2
  exit 1
fi

if [ -n "$VALIDATE_IMAGE" ]; then
  validate_image "$VALIDATE_IMAGE"
  exit 0
fi

if [ -z "$ISO" ]; then
  usage >&2
  exit 2
fi

case "$GRUB_MODE" in
  menu|direct)
    ;;
  *)
    echo "Invalid --grub-mode: $GRUB_MODE (expected menu or direct)" >&2
    exit 2
    ;;
esac

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_dir/$WORK_DIR" "$(dirname "$repo_dir/$OUT")"
work_abs="$(cd "$repo_dir/$WORK_DIR" && pwd)"

iso_name="ubuntu-x1e.iso"
dtb_name="sp11-denali.dtb"

if [[ "$ISO" =~ ^https?:// ]]; then
  echo "Downloading ISO..."
  curl -L "$ISO" -o "$work_abs/$iso_name"
else
  cp "$ISO" "$work_abs/$iso_name"
fi

rm -f "$work_abs/$dtb_name"
if [ "$DTB" != "auto" ]; then
  cp "$DTB" "$work_abs/$dtb_name"
fi

rm -rf "$work_abs/payload"
if [ -d "$repo_dir/$PAYLOAD_DIR" ]; then
  mkdir -p "$work_abs/payload"
  (cd "$repo_dir/$PAYLOAD_DIR" && tar cf - .) | (cd "$work_abs/payload" && tar xf -)
fi

rm -rf "$work_abs/support"
mkdir -p "$work_abs/support"
cp "$repo_dir/README.md" "$work_abs/support/"
cp -R "$repo_dir/docs" "$work_abs/support/"
cp -R "$repo_dir/patches" "$work_abs/support/"
cp -R "$repo_dir/scripts" "$work_abs/support/"
cp -R "$repo_dir/tools" "$work_abs/support/"

write_grub_common() {
  cat <<'EOF'
insmod part_gpt
insmod fat
insmod ext2
insmod fdt
insmod loopback
insmod iso9660
insmod search
insmod search_fs_file
insmod search_label
insmod linux

set iso_path=/iso/ubuntu-x1e.iso
set dtb_path=/dtb/sp11-denali.dtb
set sp11_args="clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0"
set usb_safe_args="modprobe.blacklist=qcom_q6v5_pas"
EOF
}

write_grub_usb_safe_casper_boot() {
  cat <<'EOF'
search --label SP11DATA --set=data
set root=($data)
loopback loop ${iso_path}
linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} ${usb_safe_args} --- quiet splash console=tty0
devicetree ${dtb_path}
initrd (loop)/casper/initrd
EOF
}

if [ "$GRUB_MODE" = "direct" ]; then
{
  echo "# sp11_grub_mode=direct"
  echo
  write_grub_common
  echo
  echo 'echo "Surface Pro 11 direct boot: USB-safe casper iso-scan"'
  echo 'echo "Searching for SP11DATA..."'
  write_grub_usb_safe_casper_boot
  echo "boot"
} > "$work_abs/grub.cfg"
else
{
cat <<'EOF'
# sp11_grub_mode=menu
set timeout=10
set default=0

EOF
write_grub_common
cat <<'EOF'

menuentry "Ubuntu for Surface Pro 11 (USB-safe, casper iso-scan)" {
EOF
write_grub_usb_safe_casper_boot
cat <<'EOF'
}

menuentry "Ubuntu for Surface Pro 11 (USB-safe text/debug, casper iso-scan)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} ${usb_safe_args} debug systemd.unit=multi-user.target plymouth.enable=0 --- console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 (USB-safe, ISO-native fallback)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz ${sp11_args} ${usb_safe_args} --- quiet splash console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 (normal aDSP allowed, casper iso-scan)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} --- quiet splash console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}
EOF
} > "$work_abs/grub.cfg"
fi

cat > "$work_abs/build-inside.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  coreutils \
  dosfstools \
  e2fsprogs \
  gdisk \
  grub-efi-arm64-bin \
  libarchive-tools \
  mtools \
  parted \
  squashfs-tools \
  xz-utils

cd /work
dtb_name="sp11-denali.dtb"

rm -rf esp data out
mkdir -p esp/EFI/BOOT data/iso data/dtb data/payload data/support out

cp ubuntu-x1e.iso data/iso/ubuntu-x1e.iso

iso_members="$(mktemp)"
bsdtar -tf ubuntu-x1e.iso > "$iso_members"

for required in casper/vmlinuz casper/initrd; do
  if ! grep -qx "$required" "$iso_members"; then
    echo "ISO missing expected path: $required" >&2
    exit 1
  fi
done

dtb_candidates=(
  "x1e80100-microsoft-denali-oled.dtb"
  "x1e80100-microsoft-denali.dtb"
  "x1e80100-microsoft-denali-oled-el2.dtb"
)

extract_dtb_from_iso_member() {
  local name member
  for name in "${dtb_candidates[@]}"; do
    member="$(
      awk -F/ -v name="$name" '$NF == name { print; exit }' "$iso_members"
    )"
    if [ -n "$member" ]; then
      bsdtar -xOf ubuntu-x1e.iso "$member" > "data/dtb/$dtb_name"
      echo "Extracted Denali DTB from ISO member: $member"
      return 0
    fi
  done
  return 1
}

extract_dtb_from_squashfs_layers() {
  local layer name found inner_path tmp_layer tmp_root
  tmp_layer="$(mktemp)"
  tmp_root="$(mktemp -d)"

  for layer in $(grep -E '^casper/.*\.squashfs$' "$iso_members"); do
    echo "Searching DTB in $layer..."
    bsdtar -xOf ubuntu-x1e.iso "$layer" > "$tmp_layer"

    for name in "${dtb_candidates[@]}"; do
      found="$(
        unsquashfs -ll "$tmp_layer" 2>/dev/null |
          awk -F/ -v name="$name" '$NF == name { print $0; exit }' |
          awk '{ print $NF }'
      )"
      if [ -n "$found" ]; then
        inner_path="${found#squashfs-root/}"
        rm -rf "$tmp_root"
        mkdir -p "$tmp_root"
        unsquashfs -q -d "$tmp_root" "$tmp_layer" "$inner_path" >/dev/null
        cp "$tmp_root/$inner_path" "data/dtb/$dtb_name"
        echo "Extracted Denali DTB from $layer: $inner_path"
        rm -f "$tmp_layer"
        rm -rf "$tmp_root"
        return 0
      fi
    done
  done

  rm -f "$tmp_layer"
  rm -rf "$tmp_root"
  return 1
}

if [ -f "$dtb_name" ]; then
  cp "$dtb_name" "data/dtb/$dtb_name"
elif ! extract_dtb_from_iso_member && ! extract_dtb_from_squashfs_layers; then
  echo "STATUS: DTB not found in ISO files or casper squashfs layers." >&2
  echo "Searched for: ${dtb_candidates[*]}" >&2
  echo "Re-run with --dtb /path/to/surface-pro-11-denali.dtb." >&2
  exit 1
fi

if [ -d payload ]; then
  cp -a payload/. data/payload/
fi
cp -a support/. data/support/

grub-mkstandalone \
  -O arm64-efi \
  -o esp/EFI/BOOT/BOOTAA64.EFI \
  --modules="part_gpt fat ext2 fdt loopback iso9660 search search_fs_file search_label linux normal configfile all_video gfxterm" \
  "boot/grub/grub.cfg=grub.cfg"

printf 'This USB boots Ubuntu for Surface Pro 11. See /support and /payload on SP11DATA.\n' > esp/README.txt

esp_mib=512
iso_mib=$(( ($(stat -c '%s' ubuntu-x1e.iso) + 1048575) / 1048576 ))
payload_mib=0
if [ -d payload ]; then
  payload_kib=$(du -sk payload | awk '{print $1}')
  payload_mib=$(( (payload_kib + 1023) / 1024 ))
fi
support_kib=$(du -sk support | awk '{print $1}')
support_mib=$(( (support_kib + 1023) / 1024 ))
extra_mib="${IMAGE_EXTRA_MB:-1536}"
data_mib=$(( iso_mib + payload_mib + support_mib + extra_mib ))
total_mib=$(( esp_mib + data_mib + 64 ))

truncate -s "${esp_mib}M" esp.img
mformat -i esp.img -F -v SP11EFI ::
mmd -i esp.img ::/EFI ::/EFI/BOOT
mcopy -i esp.img esp/EFI/BOOT/BOOTAA64.EFI ::/EFI/BOOT/
mcopy -i esp.img esp/README.txt ::/

truncate -s "${data_mib}M" data.ext4
mke2fs -q -t ext4 -L SP11DATA -d data data.ext4

out_img="out/sp11-ubuntu-live.img"
truncate -s "${total_mib}M" "$out_img"
sgdisk -o \
  -n 1:2048:+${esp_mib}M -t 1:EF00 -c 1:SP11EFI \
  -n 2:0:0 -t 2:8300 -c 2:SP11DATA \
  "$out_img"

parted -sm "$out_img" unit s print > layout.txt
esp_start=$(awk -F: '$1 == "1" { gsub(/s$/, "", $2); print $2 }' layout.txt)
data_start=$(awk -F: '$1 == "2" { gsub(/s$/, "", $2); print $2 }' layout.txt)

dd if=esp.img of="$out_img" bs=4M seek="$((esp_start * 512))" oflag=seek_bytes conv=notrunc status=none
dd if=data.ext4 of="$out_img" bs=64M seek="$((data_start * 512))" oflag=seek_bytes conv=notrunc status=none

sgdisk -v "$out_img"
ls -lh "$out_img"
EOF
chmod +x "$work_abs/build-inside.sh"

docker run --rm --platform linux/arm64 \
  -e IMAGE_EXTRA_MB="$IMAGE_EXTRA_MB" \
  -v "$work_abs:/work" \
  ubuntu:24.04 \
  /work/build-inside.sh

mv -f "$work_abs/out/sp11-ubuntu-live.img" "$repo_dir/$OUT"
echo "Wrote $repo_dir/$OUT"

if [ "$VALIDATE" = "true" ]; then
  if [ -z "${SP11_EXPECT_KERNEL_DEBS:-}" ] &&
    [ -d "$repo_dir/$PAYLOAD_DIR/kernel-debs" ] &&
    find "$repo_dir/$PAYLOAD_DIR/kernel-debs" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
    export SP11_EXPECT_KERNEL_DEBS="true"
  fi
  validate_image "$repo_dir/$OUT"
fi
