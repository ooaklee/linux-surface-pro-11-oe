#!/usr/bin/env bash
set -euo pipefail

TARGET="/target"

usage() {
  cat <<EOF
Usage: sudo $0 [--target DIR]

Prepares an installed Ubuntu target for first Surface Pro 11 NVMe boot.

Run this from the live USB after the installer finishes, before rebooting:

  cd /media/<user>/SP11DATA/support
  sudo ./scripts/prepare-sp11-installed-system.sh --target /target

Options:
  --target DIR   Installed Ubuntu root, default /target.
  -h, --help     Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|--root)
      TARGET="$2"
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

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_usb_dtb() {
  local candidate usb_dev usb_mount

  for candidate in \
    "$repo_dir/../dtb/sp11-denali.dtb" \
    "$repo_dir/dtb/sp11-denali.dtb"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  usb_dev="$(blkid -L SP11DATA 2>/dev/null || true)"
  if [ -n "$usb_dev" ]; then
    usb_mount="$(findmnt -rn -S "$usb_dev" -o TARGET 2>/dev/null | head -n 1 || true)"
    if [ -n "$usb_mount" ] && [ -f "$usb_mount/dtb/sp11-denali.dtb" ]; then
      printf '%s\n' "$usb_mount/dtb/sp11-denali.dtb"
      return 0
    fi
  fi

  return 1
}

if [ ! -d "$TARGET/etc" ]; then
  echo "Installed Ubuntu root not found at $TARGET." >&2
  echo "Mount the installed Ubuntu root there, or pass --target DIR." >&2
  exit 1
fi

if [ ! -x "$repo_dir/scripts/install-sp11-support.sh" ]; then
  echo "Missing support installer: $repo_dir/scripts/install-sp11-support.sh" >&2
  exit 1
fi

echo "Installing Surface Pro 11 helpers into $TARGET..."
"$repo_dir/scripts/install-sp11-support.sh" --installed-system --root "$TARGET"

if usb_dtb="$(find_usb_dtb)"; then
  echo "Copying Surface Pro 11 DTB into installed /boot..."
  install -d -m 0755 "$TARGET/boot"
  install -m 0644 "$usb_dtb" "$TARGET/boot/sp11-denali.dtb"
else
  echo "Warning: USB DTB not found; installed GRUB DTB injection will rely on target kernel DTBs." >&2
fi

mkdir -p "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run"

mounted=()
cleanup() {
  local i fs
  for ((i=${#mounted[@]} - 1; i >= 0; i--)); do
    fs="${mounted[i]}"
    umount "$TARGET/$fs" || true
  done
}
trap cleanup EXIT

for fs in dev proc sys run; do
  if ! mountpoint -q "$TARGET/$fs"; then
    mount --bind "/$fs" "$TARGET/$fs"
    mounted+=("$fs")
  fi
done

echo "Generating installed GRUB config..."
chroot "$TARGET" update-grub

echo "Injecting Surface Pro 11 DTB into installed GRUB config..."
chroot "$TARGET" /usr/local/sbin/sp11-grub-inject-dtb

echo "Refreshing installed initramfs..."
chroot "$TARGET" update-initramfs -u -k all

echo
echo "Installed system prepared for first Surface Pro 11 NVMe boot."
echo "You can now reboot and test booting without the live USB."
