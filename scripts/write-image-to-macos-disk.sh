#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 IMAGE /dev/diskN" >&2
  exit 2
fi

image="$1"
disk="$2"

if [ ! -f "$image" ]; then
  echo "Image not found: $image" >&2
  exit 1
fi

if [[ "$disk" != /dev/disk* ]]; then
  echo "Target must look like /dev/diskN on macOS." >&2
  exit 1
fi

info="$(diskutil info "$disk")"
echo "$info"

echo "$info" | grep -q "Device Location: *External" || {
  echo "Refusing: target is not external." >&2
  exit 1
}
echo "$info" | grep -q "Removable Media: *Removable" || {
  echo "Refusing: target is not removable." >&2
  exit 1
}
echo "$info" | grep -q "Protocol: *USB" || {
  echo "Refusing: target is not USB." >&2
  exit 1
}

raw="/dev/r${disk#/dev/}"
echo
echo "About to erase and write $image to $disk ($raw)."
echo "Press Ctrl-C within 10 seconds to cancel."
sleep 10

diskutil unmountDisk force "$disk"
sudo dd if="$image" of="$raw" bs=4m status=progress
sync
diskutil eject "$disk"

echo "Wrote and ejected $disk"
