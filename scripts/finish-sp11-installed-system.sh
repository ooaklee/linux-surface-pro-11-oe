#!/usr/bin/env bash
set -euo pipefail

FIRMWARE_MODE=""
WINDOWS_ROOT=""
REBOOT="false"
RUN_WIFI_FIXUP="true"

usage() {
  cat <<EOF
Usage: sudo $0 (--download | --windows-root DIR | --skip-firmware) [options]

Finishes Surface Pro 11 support setup from the installed Ubuntu system.

Run this after the first successful boot into installed Ubuntu, with the
SP11DATA USB partition mounted:

  cd /media/<user>/SP11DATA/support
  sudo ./scripts/finish-sp11-installed-system.sh --download --reboot

Options:
  --download           Download firmware CABs from the public WOA driver repo.
  --windows-root DIR   Copy firmware from a mounted Windows partition.
  --skip-firmware      Install support helpers only; do not install firmware.
  --skip-wifi-fixup    Do not run the ath12k WCN7850 board-file fixup.
  --reboot             Reboot after setup completes.
  --no-reboot          Do not reboot after setup completes (default).
  -h, --help           Show this help.
EOF
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

windows_path_hint() {
  cat >&2 <<'EOF'
The Windows root is the mounted NTFS partition containing the Windows directory.
If the mount path contains spaces, quote it, for example:
  --windows-root "/run/media/$USER/Local Disk"
Do not pass the Linux /boot/efi mount or a path inside the EFI partition.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --download)
      FIRMWARE_MODE="download"
      shift
      ;;
    --windows-root)
      require_arg "$1" "${2:-}"
      FIRMWARE_MODE="windows"
      WINDOWS_ROOT="$2"
      shift 2
      ;;
    --windows-root=*)
      FIRMWARE_MODE="windows"
      WINDOWS_ROOT="${1#*=}"
      shift
      ;;
    --skip-firmware)
      FIRMWARE_MODE="skip"
      shift
      ;;
    --skip-wifi-fixup)
      RUN_WIFI_FIXUP="false"
      shift
      ;;
    --reboot)
      REBOOT="true"
      shift
      ;;
    --no-reboot)
      REBOOT="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      if [ "$FIRMWARE_MODE" = "windows" ] && [ -n "$WINDOWS_ROOT" ]; then
        windows_path_hint
      fi
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

if [ -z "$FIRMWARE_MODE" ]; then
  echo "Choose one firmware mode: --download, --windows-root DIR, or --skip-firmware." >&2
  usage >&2
  exit 2
fi

if [ "$FIRMWARE_MODE" = "windows" ]; then
  if [ -z "$WINDOWS_ROOT" ]; then
    echo "--windows-root requires a mounted Windows root directory." >&2
    windows_path_hint
    exit 2
  fi
  if [ ! -d "$WINDOWS_ROOT/Windows" ]; then
    echo "Not a Windows root: $WINDOWS_ROOT" >&2
    windows_path_hint
    exit 1
  fi
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -x "$repo_dir/scripts/install-sp11-support.sh" ]; then
  echo "Missing support installer: $repo_dir/scripts/install-sp11-support.sh" >&2
  exit 1
fi

echo "Installing Surface Pro 11 support helpers..."
"$repo_dir/scripts/install-sp11-support.sh" --installed-system

case "$FIRMWARE_MODE" in
  download)
    echo "Downloading and installing Surface Pro 11 firmware..."
    /usr/local/sbin/sp11-grab-fw --download
    ;;
  windows)
    if [ -z "$WINDOWS_ROOT" ]; then
      echo "--windows-root requires a mounted Windows root directory." >&2
      exit 2
    fi
    echo "Installing Surface Pro 11 firmware from $WINDOWS_ROOT..."
    /usr/local/sbin/sp11-grab-fw --windows-root "$WINDOWS_ROOT"
    ;;
  skip)
    echo "Skipping firmware install."
    ;;
esac

if [ "$RUN_WIFI_FIXUP" = "true" ]; then
  echo "Applying ath12k WCN7850 Wi-Fi board-file fixup if possible..."
  if /usr/local/sbin/sp11-wifi-board-fixup; then
    if command -v update-initramfs >/dev/null 2>&1; then
      echo "Refreshing initramfs after Wi-Fi board-file fixup..."
      update-initramfs -u -k all || true
    fi
  else
    echo "Warning: Wi-Fi board-file fixup failed; continue and rerun later after firmware/networking is available." >&2
  fi
fi

echo
echo "Installed-system Surface Pro 11 setup complete."

if [ "$REBOOT" = "true" ]; then
  echo "Rebooting..."
  reboot
else
  echo "Reboot when ready."
fi
