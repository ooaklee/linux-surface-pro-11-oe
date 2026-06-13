#!/usr/bin/env bash
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-WOA-Project/Qualcomm-Reference-Drivers}"
DEVICE="${DEVICE:-Surface/8380_DEN}"
DRIVER_REPO_API_URL="https://api.github.com/repos/${GITHUB_REPO}/contents/${DEVICE}"
DRIVER_REPO_DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/master/${DEVICE}"
DEST_PREFIX="${DEST_PREFIX:-/lib/firmware}"
WINDOWS_ROOT=""
MODE="download"
ADSP_POLICY="auto"

# source file | source cab | destination under /lib/firmware
firmware=(
  "qcdxkmsuc8380.mbn"   "qcdx8380.cab"                    "qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn"
  "qcdxkmsucpurwa.mbn"  "qcdx8380.cab"                    "qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn"
  "adsp_dtbs.elf"       "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn"
  "qcadsp8380.mbn"      "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn"
  "adspr.jsn"           "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/adspr.jsn"
  "adsps.jsn"           "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/adsps.jsn"
  "adspua.jsn"          "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/adspua.jsn"
  "battmgr.jsn"         "surfacepro_ext_adsp8380.cab"     "qcom/x1e80100/microsoft/Denali/battmgr.jsn"
  "cdsp_dtbs.elf"       "qcnspmcdm_ext_cdsp8380.cab"      "qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn"
  "qccdsp8380.mbn"      "qcnspmcdm_ext_cdsp8380.cab"      "qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn"
  "cdspr.jsn"           "qcnspmcdm_ext_cdsp8380.cab"      "qcom/x1e80100/microsoft/Denali/cdspr.jsn"
)

usage() {
  cat <<EOF
Usage: sudo $0 [--download | --windows-root DIR] [options]

Options:
  --download             Download CABs from WOA-Project (default).
  --windows-root DIR     Copy latest matching files from a mounted Windows root.
  --dest DIR             Firmware root, default /lib/firmware.
  --usb-safe             Disable adsp_dtb.mbn after install.
  --enable-adsp          Leave adsp_dtb.mbn enabled.
  --adsp-auto            Disable aDSP only when root is not NVMe (default).
  -h, --help             Show this help.

The aDSP DTB can reset USB during live-USB boot on SP11. Keep it disabled
while booted from USB; enable it only after installing to NVMe.
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
    -d|--download)
      MODE="download"
      shift
      ;;
    -w|--windows-root)
      require_arg "$1" "${2:-}"
      MODE="windows"
      WINDOWS_ROOT="$2"
      shift 2
      ;;
    --windows-root=*)
      MODE="windows"
      WINDOWS_ROOT="${1#*=}"
      shift
      ;;
    --dest)
      require_arg "$1" "${2:-}"
      DEST_PREFIX="$2"
      shift 2
      ;;
    --dest=*)
      DEST_PREFIX="${1#*=}"
      shift
      ;;
    --usb-safe|--disable-adsp)
      ADSP_POLICY="disable"
      shift
      ;;
    --enable-adsp)
      ADSP_POLICY="enable"
      shift
      ;;
    --adsp-auto)
      ADSP_POLICY="auto"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      if [ "$MODE" = "windows" ] && [ -n "$WINDOWS_ROOT" ]; then
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

require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "Install them with: sudo apt update && sudo apt install ${missing[*]}" >&2
    exit 1
  fi
}

install_fw_file() {
  local src="$1"
  local dst_rel="$2"
  local dst="$DEST_PREFIX/$dst_rel"

  install -d -m 0755 "$(dirname "$dst")"
  install -m 0644 "$src" "$dst"
  echo "Installed $dst"
}

latest_version() {
  curl -fsSL "$DRIVER_REPO_API_URL" |
    jq -r '.[] | select(.type == "dir") | .name' |
    sort -V |
    tail -n 1
}

grab_download() {
  require_tools cabextract curl jq

  local latest
  latest="$(latest_version)"
  if [ -z "$latest" ] || [ "$latest" = "null" ]; then
    echo "Could not determine latest WOA driver version." >&2
    exit 1
  fi
  echo "Using WOA driver set: $latest"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  for ((i=0; i<${#firmware[@]}; i+=3)); do
    local src="${firmware[i]}"
    local cab="${firmware[i+1]}"
    local dst="${firmware[i+2]}"

    if [ ! -f "$tmp/$cab" ]; then
      echo "Downloading $cab..."
      curl -fL "$DRIVER_REPO_DOWNLOAD_URL/$latest/$cab" -o "$tmp/$cab"
    fi

    rm -f "$tmp/$src"
    if cabextract "$tmp/$cab" -F "$src" -d "$tmp" -q >/dev/null 2>&1; then
      install_fw_file "$tmp/$src" "$dst"
    else
      echo "Warning: $src not found in $cab" >&2
    fi
  done
}

grab_windows() {
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

  local source_prefix="$WINDOWS_ROOT/Windows/System32/DriverStore/FileRepository"
  for ((i=0; i<${#firmware[@]}; i+=3)); do
    local src="${firmware[i]}"
    local dst="${firmware[i+2]}"
    local latest_file

    latest_file="$(
      find "$WINDOWS_ROOT/Windows/System32" "$source_prefix" -type f -name "$src" -printf "%T@ %p\n" 2>/dev/null |
      sort -nr |
      awk 'NR==1 { sub(/^[^ ]+ /, ""); print }'
    )"

    if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
      install_fw_file "$latest_file" "$dst"
    else
      echo "Warning: $src not found under $WINDOWS_ROOT" >&2
    fi
  done
}

root_is_nvme() {
  local source pkname
  source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ -n "$source" ] || return 1
  pkname="$(lsblk -no PKNAME "$source" 2>/dev/null | head -n 1 || true)"
  [[ "$pkname" == nvme* ]]
}

apply_adsp_policy() {
  local adsp="$DEST_PREFIX/qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn"
  local disabled="$adsp.disabled"

  [ -f "$adsp" ] || return 0

  case "$ADSP_POLICY" in
    enable)
      echo "Leaving aDSP DTB enabled."
      ;;
    disable)
      mv -f "$adsp" "$disabled"
      echo "Disabled aDSP DTB for USB-safe boot: $disabled"
      ;;
    auto)
      if root_is_nvme; then
        echo "Root appears to be NVMe; leaving aDSP DTB enabled."
      else
        mv -f "$adsp" "$disabled"
        echo "Root does not appear to be NVMe; disabled aDSP DTB: $disabled"
      fi
      ;;
  esac
}

case "$MODE" in
  download) grab_download ;;
  windows) grab_windows ;;
esac

apply_adsp_policy

if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k all || true
fi
