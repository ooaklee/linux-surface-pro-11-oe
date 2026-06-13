#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/}"
USB_SAFE="false"

usage() {
  cat <<EOF
Usage: sudo $0 [--installed-system | --usb-safe] [--root DIR]

Installs Surface Pro 11 Ubuntu support helpers into an installed Ubuntu root.

  --installed-system   Configure for NVMe-installed Ubuntu.
  --usb-safe           Add the qcom_q6v5_pas blacklist for live USB boot.
  --root DIR           Target root, default /.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --installed-system)
      USB_SAFE="false"
      shift
      ;;
    --usb-safe)
      USB_SAFE="true"
      shift
      ;;
    --root)
      ROOT="$2"
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

target() {
  local rel="${1#/}"
  printf '%s/%s' "${ROOT%/}" "$rel"
}

install -d "$(target /usr/local/sbin)" "$(target /etc/default/grub.d)" \
  "$(target /etc/kernel/postinst.d)" "$(target /etc/kernel/postrm.d)" \
  "$(target /etc/apt/apt.conf.d)"

install -m 0755 "$repo_dir/scripts/sp11-grab-fw.sh" "$(target /usr/local/sbin/sp11-grab-fw)"
install -m 0755 "$repo_dir/scripts/sp11-wifi-board-fixup.sh" "$(target /usr/local/sbin/sp11-wifi-board-fixup)"

cat > "$(target /usr/local/sbin/sp11-grub-inject-dtb)" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BOOT_DTB_NAME="sp11-denali.dtb"
BOOT_DTB="/boot/$BOOT_DTB_NAME"
GRUB_CFG="/boot/grub/grub.cfg"
DTB_NAMES=(
  "x1e80100-microsoft-denali-oled.dtb"
  "x1e80100-microsoft-denali.dtb"
  "x1e80100-microsoft-denali-oled-el2.dtb"
  "sp11-denali.dtb"
)

find_dtb() {
  local name pattern path
  for name in "${DTB_NAMES[@]}"; do
    for pattern in \
      "/usr/lib/firmware/*/device-tree/qcom/$name" \
      "/usr/lib/linux-image-*/qcom/$name" \
      "/boot/dtbs/*/qcom/$name" \
      "/boot/dtbs/*/$name" \
      "/boot/$name"; do
      for path in $pattern; do
        [ -f "$path" ] && printf '%s\n' "$path" && return 0
      done
    done
  done
  return 1
}

dtb="$(find_dtb || true)"
if [ -z "$dtb" ]; then
  echo "Warning: Surface Pro 11 Denali DTB not found; GRUB DTB injection skipped." >&2
  exit 0
fi

install -m 0644 "$dtb" "$BOOT_DTB"

if [ ! -f "$GRUB_CFG" ]; then
  echo "Warning: $GRUB_CFG not found; run update-grub first." >&2
  exit 0
fi

tmp="$(mktemp)"
awk -v dtb="$BOOT_DTB_NAME" '
  /^([[:space:]]*)linux[[:space:]]/ {
    print
    match($0, /^[ \t]*/)
    indent = substr($0, RSTART, RLENGTH)
    print indent "devicetree /boot/" dtb
    next
  }
  /devicetree \/boot\/(x1e80100-microsoft-denali(-oled|-oled-el2)?|sp11-denali)\.dtb/ {
    next
  }
  { print }
' "$GRUB_CFG" > "$tmp"
install -m 0644 "$tmp" "$GRUB_CFG"
rm -f "$tmp"
echo "Injected Surface Pro 11 DTB into $GRUB_CFG"
EOF
chmod 0755 "$(target /usr/local/sbin/sp11-grub-inject-dtb)"

cat > "$(target /etc/default/grub.d/99-surface-pro-11.cfg)" <<EOF
# Surface Pro 11 / Snapdragon X Elite bring-up arguments.
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0"
EOF

if [ "$USB_SAFE" = "true" ]; then
  cat >> "$(target /etc/default/grub.d/99-surface-pro-11.cfg)" <<'EOF'
# USB-safe live boot: avoid aDSP reset breaking the USB root device.
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} modprobe.blacklist=qcom_q6v5_pas"
EOF
fi

cat > "$(target /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb)" <<'EOF'
#!/usr/bin/env bash
set -e
if command -v /usr/local/sbin/sp11-grub-inject-dtb >/dev/null 2>&1; then
  /usr/local/sbin/sp11-grub-inject-dtb || true
fi
EOF
chmod 0755 "$(target /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb)"

cat > "$(target /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb)" <<'EOF'
#!/usr/bin/env bash
set -e
if command -v /usr/local/sbin/sp11-grub-inject-dtb >/dev/null 2>&1; then
  /usr/local/sbin/sp11-grub-inject-dtb || true
fi
EOF
chmod 0755 "$(target /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb)"

cat > "$(target /etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup)" <<'EOF'
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/sp11-wifi-board-fixup ]; then /usr/local/sbin/sp11-wifi-board-fixup || true; fi"; };
EOF

if [ "$ROOT" = "/" ]; then
  if command -v update-grub >/dev/null 2>&1; then
    update-grub || true
  fi
  /usr/local/sbin/sp11-grub-inject-dtb || true
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all || true
  fi
fi

echo "Installed Surface Pro 11 support helpers into $ROOT"
