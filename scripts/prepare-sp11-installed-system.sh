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

die() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

canonical_directory() {
  local path="$1"

  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  (cd "$path" && pwd -P)
}

directory_identity() {
  local path="$1" identity=""

  if identity="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null)"; then
    :
  elif identity="$(stat -f '%d:%i' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  case "$identity" in
    ""|*[!0-9:]*) return 1 ;;
  esac
  printf '%s\n' "$identity"
}

target_path() {
  printf '%s/%s\n' "$TARGET" "$1"
}

validate_target_directory() {
  local relative="$1" path resolved

  path="$(target_path "$relative")"
  if [ -L "$path" ]; then
    die "installed target /$relative must not be a symlink: $path"
  fi
  if [ ! -e "$path" ]; then
    die "installed target is missing the required /$relative directory: $path"
  fi
  if [ ! -d "$path" ]; then
    die "installed target /$relative must be a real directory: $path"
  fi
  resolved="$(canonical_directory "$path")" ||
    die "could not resolve installed target /$relative safely: $path"
  if [ "$resolved" != "$path" ]; then
    die "installed target /$relative resolves outside its exact path: $path"
  fi
}

mount_matches_host_directory() {
  local filesystem="$1" destination="$2" source_identity destination_identity

  source_identity="$(directory_identity "/$filesystem")" || return 1
  destination_identity="$(directory_identity "$destination")" || return 1
  [ "$source_identity" = "$destination_identity" ]
}

validate_virtual_mount() {
  local filesystem="$1" destination

  destination="$(target_path "$filesystem")"
  validate_target_directory "$filesystem"
  if mountpoint -q -- "$destination" &&
     ! mount_matches_host_directory "$filesystem" "$destination"; then
    die "installed target /$filesystem is mounted from an unexpected source: $destination"
  fi
}

validate_target_contract() {
  local current_target relative

  current_target="$(canonical_directory "$TARGET")" ||
    die "installed Ubuntu root is no longer a real directory: $TARGET"
  [ "$current_target" = "$TARGET" ] ||
    die "installed Ubuntu root changed physical path: $TARGET"
  mountpoint -q -- "$TARGET" ||
    die "installed Ubuntu root must itself be a mounted filesystem: $TARGET"

  validate_target_directory etc
  for relative in dev proc sys run; do
    validate_virtual_mount "$relative"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|--root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "$1 requires a directory." >&2
        usage >&2
        exit 2
      fi
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

for tool in mount mountpoint stat umount chroot; do
  require_tool "$tool"
done

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "$TARGET" in
  /*) ;;
  *) die "--target must be an absolute path" ;;
esac
case "$TARGET" in
  *[[:cntrl:]]*) die "--target must not contain control characters" ;;
  *//*|*/./*|*/.|*/../*|*/..) die "--target must use a canonical absolute path" ;;
esac
[ "$TARGET" != "/" ] || die "refusing to prepare the running root as an installed target"

resolved_target="$(canonical_directory "$TARGET")" ||
  die "installed Ubuntu root must be an existing real directory: $TARGET"
if [ "$resolved_target" != "$TARGET" ]; then
  die "--target must be its exact physical nonsymlink path: $TARGET"
fi
TARGET="$resolved_target"

validate_target_contract

if [ ! -f "$repo_dir/scripts/install-sp11-support.sh" ] ||
   [ -L "$repo_dir/scripts/install-sp11-support.sh" ] ||
   [ ! -x "$repo_dir/scripts/install-sp11-support.sh" ]; then
  echo "Missing support installer: $repo_dir/scripts/install-sp11-support.sh" >&2
  exit 1
fi

echo "Installing Surface Pro 11 helpers into $TARGET..."
"$repo_dir/scripts/install-sp11-support.sh" --installed-system --root "$TARGET"

validate_target_contract

mounted_filesystems=()
mounted_targets=()
cleanup() {
  local original_status="$?" cleanup_failed="false"
  local i filesystem destination resolved

  trap - EXIT HUP INT TERM

  for ((i=${#mounted_targets[@]} - 1; i >= 0; i--)); do
    filesystem="${mounted_filesystems[i]}"
    destination="${mounted_targets[i]}"
    resolved="$(canonical_directory "$destination" 2>/dev/null || true)"
    if [ "$resolved" != "$destination" ] ||
       ! mountpoint -q -- "$destination" ||
       ! mount_matches_host_directory "$filesystem" "$destination"; then
      echo "warning: refusing to unmount changed target path: $destination" >&2
      cleanup_failed="true"
      continue
    fi
    if ! umount -- "$destination"; then
      echo "warning: could not unmount helper-created target: $destination" >&2
      cleanup_failed="true"
    fi
  done
  mounted_filesystems=()
  mounted_targets=()
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  if [ "$cleanup_failed" = "true" ]; then
    exit 1
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for fs in dev proc sys run; do
  destination="$(target_path "$fs")"
  validate_virtual_mount "$fs"
  if ! mountpoint -q -- "$destination"; then
    validate_target_directory "$fs"
    mount --bind "/$fs" "$destination"
    mounted_filesystems+=("$fs")
    mounted_targets+=("$destination")
    if ! mountpoint -q -- "$destination" ||
       ! mount_matches_host_directory "$fs" "$destination"; then
      die "bind mount verification failed for installed target /$fs"
    fi
  fi
done

validate_target_contract
echo "Generating installed GRUB config..."
chroot "$TARGET" update-grub

validate_target_contract
echo "Refreshing installed initramfs..."
chroot "$TARGET" update-initramfs -u -k all

cleanup

echo
echo "Installed system prepared for first Surface Pro 11 NVMe boot."
echo "You can now reboot and test booting without the live USB."
