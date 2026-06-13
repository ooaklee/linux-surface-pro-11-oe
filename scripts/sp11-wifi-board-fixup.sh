#!/usr/bin/env bash
set -euo pipefail

FW_DIR="${FW_DIR:-/lib/firmware/ath12k/WCN7850/hw2.0}"
BDENCODER_URL="${BDENCODER_URL:-https://raw.githubusercontent.com/qca/qca-swiss-army-knife/refs/heads/master/tools/scripts/ath12k/ath12k-bdencoder}"
SOURCE_BOARD="bus=pci,vendor=17cb,device=1107,subsystem-vendor=17cb,subsystem-device=3378,qmi-chip-id=2,qmi-board-id=255.bin"
TARGET_BOARD="board.bin"

usage() {
  cat <<EOF
Usage: sudo $0 [--firmware-dir DIR]

Extracts a compatible WCN7850 board file for Surface Pro 11 Wi-Fi.

The Surface Pro 11 reports:
  bus=pci,vendor=17cb,device=1107,subsystem-vendor=17cb,subsystem-device=1107,qmi-chip-id=2,qmi-board-id=255

Current linux-firmware may not include an exact match, so we install board.bin
from the closest known entry used by the Surface Pro 11 Arch bring-up.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firmware-dir)
      FW_DIR="$2"
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

for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [ ! -d "$FW_DIR" ]; then
  echo "Firmware directory not found: $FW_DIR" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cd "$tmp"

if [ -f "$FW_DIR/board-2.bin" ]; then
  cp "$FW_DIR/board-2.bin" .
elif [ -f "$FW_DIR/board-2.bin.zst" ]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "board-2.bin is compressed; install zstd." >&2
    exit 1
  fi
  zstd -dc "$FW_DIR/board-2.bin.zst" > board-2.bin
else
  echo "No board-2.bin or board-2.bin.zst found in $FW_DIR" >&2
  exit 1
fi

python3 <(curl -fsSL "$BDENCODER_URL") --extract board-2.bin

if [ ! -f "$SOURCE_BOARD" ]; then
  echo "Expected source board entry not found: $SOURCE_BOARD" >&2
  exit 1
fi

install -m 0644 "$SOURCE_BOARD" "$FW_DIR/$TARGET_BOARD"
echo "Installed $FW_DIR/$TARGET_BOARD"
