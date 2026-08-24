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
  "$(target /etc/apt/apt.conf.d)" \
  "$(target /lib/firmware/qcom/x1e80100)" \
  "$(target /usr/share/alsa/ucm2/Qualcomm/x1e80100)" \
  "$(target /usr/share/alsa/ucm2/conf.d/x1e80100)"

install -m 0755 "$repo_dir/scripts/sp11-grab-fw.sh" "$(target /usr/local/sbin/sp11-grab-fw)"
install -m 0755 "$repo_dir/scripts/sp11-wifi-board-fixup.sh" "$(target /usr/local/sbin/sp11-wifi-board-fixup)"
install -m 0755 "$repo_dir/scripts/sp11-bluetooth-mac.sh" "$(target /usr/local/sbin/sp11-bluetooth-mac)"
install -m 0755 "$repo_dir/scripts/troubleshoot-sp11-audio.sh" "$(target /usr/local/sbin/troubleshoot-sp11-audio)"
install -m 0755 "$repo_dir/scripts/troubleshoot-sp11-bluetooth.sh" "$(target /usr/local/sbin/troubleshoot-sp11-bluetooth)"
install -m 0755 "$repo_dir/scripts/troubleshoot-sp11-wifi-rfkill.sh" "$(target /usr/local/sbin/troubleshoot-sp11-wifi-rfkill)"
install -m 0755 "$repo_dir/scripts/install-sp11-touchscreen.sh" "$(target /usr/local/sbin/install-sp11-touchscreen)"
install -m 0755 "$repo_dir/scripts/troubleshoot-sp11-touchscreen.sh" "$(target /usr/local/sbin/troubleshoot-sp11-touchscreen)"
install -m 0755 "$repo_dir/scripts/sp11-pipewire-speaker-sink.sh" "$(target /usr/local/sbin/sp11-pipewire-speaker-sink)"
install -m 0755 "$repo_dir/scripts/sp11-audio-topology.sh" "$(target /usr/local/sbin/sp11-audio-topology)"
install -m 0755 "$repo_dir/scripts/sp11-enable-wsa-routing.sh" "$(target /usr/local/sbin/sp11-enable-wsa-routing.sh)"
# Remove the mismatched name emitted by the previous main installer.
rm -f "$(target /usr/local/sbin/sp11-enable-wsa-routing)"
install -m 0755 "$repo_dir/scripts/sp11-fix-audio-boot-race.sh" "$(target /usr/local/sbin/sp11-fix-audio-boot-race)"

# --- Audio routing and graph/path exercise service ---
# The service runs after any ALSA-state restore, waits for the late-probing
# card, applies the complete WSA path while PCM1 is closed, and exercises it
# with a real PCM open.  Do not rewrite asound.state or mask distro services:
# 0x1001021 is an SPF readiness query, not evidence of an alsactl graph race.
if [ -f "$repo_dir/scripts/systemd/sp11-wsa-routing.service" ]; then
  install -d "$(target /etc/systemd/system)"
  install -m 0644 "$repo_dir/scripts/systemd/sp11-wsa-routing.service" \
    "$(target /etc/systemd/system/sp11-wsa-routing.service)"

  if [ "$ROOT" = "/" ]; then
    # Releases before the corrected GET_SPF_STATE diagnosis masked these.
    # Restore the distribution units before adding After= ordering on them.
    systemctl unmask alsa-restore.service alsa-state.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable sp11-wsa-routing.service 2>/dev/null || true
  else
    # For an offline root, remove only the exact masks created by old builds.
    for alsa_unit in alsa-restore.service alsa-state.service; do
      alsa_unit_path="$(target "/etc/systemd/system/$alsa_unit")"
      if [ -L "$alsa_unit_path" ] && [ "$(readlink "$alsa_unit_path")" = /dev/null ]; then
        rm -f "$alsa_unit_path"
      fi
    done
    # Enable via symlink (will be picked up after chroot boot)
    install -d "$(target /etc/systemd/system/multi-user.target.wants)"
    ln -sf /etc/systemd/system/sp11-wsa-routing.service \
      "$(target /etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service)" 2>/dev/null || true
  fi
fi

# --- Audio topology & UCM ---
AUDIO_ASSETS_DIR="$repo_dir/payload/audio"
if [ -f "$AUDIO_ASSETS_DIR/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ]; then
  install -m 0644 "$AUDIO_ASSETS_DIR/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" \
    "$(target /lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin)"
fi
if [ -f "$AUDIO_ASSETS_DIR/MICROSOFT-Surface-Pro-11.conf" ]; then
  install -m 0644 "$AUDIO_ASSETS_DIR/MICROSOFT-Surface-Pro-11.conf" \
    "$(target /usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf)"
fi
if [ -f "$AUDIO_ASSETS_DIR/Surface11-HiFi.conf" ]; then
  install -m 0644 "$AUDIO_ASSETS_DIR/Surface11-HiFi.conf" \
    "$(target /usr/share/alsa/ucm2/Qualcomm/x1e80100/Surface11-HiFi.conf)"
fi
if [ -f "$AUDIO_ASSETS_DIR/x1e80100.conf" ]; then
  install -m 0644 "$AUDIO_ASSETS_DIR/x1e80100.conf" \
    "$(target /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf)"
fi

cat > "$(target /usr/local/sbin/sp11-grub-inject-dtb)" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BOOT_DTB_NAME="sp11-denali.dtb"
BOOT_DTB="/boot/$BOOT_DTB_NAME"
GRUB_CFG="/boot/grub/grub.cfg"

# X1P/LCD uses a different device tree from X1E/OLED.  Prefer the LCD DTB
# only when the currently running device tree identifies the X1P variant;
# otherwise preserve the existing X1E/OLED preference.
running_compatible="$(tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null || true)"
if printf '%s\n' "$running_compatible" | grep -Eq 'x1p64100|denali-lcd'; then
  DTB_NAMES=(
    "x1p64100-microsoft-denali.dtb"
    "sp11-denali.dtb"
    "x1e80100-microsoft-denali-oled.dtb"
    "x1e80100-microsoft-denali.dtb"
    "x1e80100-microsoft-denali-oled-el2.dtb"
  )
else
  DTB_NAMES=(
    "x1e80100-microsoft-denali-oled.dtb"
    "x1e80100-microsoft-denali.dtb"
    "x1e80100-microsoft-denali-oled-el2.dtb"
    "sp11-denali.dtb"
  )
fi

# Pick the newest candidate DTB, preferring Surface Pro 11 specific builds.
# The plain jglathe qcom-x1e builds use the upstream 4.8 MHz DMIC clock; the
# SP11 builds (suffixed sp11vN) carry the validated 2.4 MHz clock. Plain sort -V
# ranks the sp11vN suffix below the plain name, so prefer it explicitly.
pick_dtb() {
  local sp11 newest_suffix
  sp11="$(printf '%s\n' "$@" | grep -E 'sp11v[0-9]+' || true)"
  if [ -n "$sp11" ]; then
    newest_suffix="$(printf '%s\n' "$sp11" | sed -nE 's/.*sp11v([0-9]+).*/\1/p' | sort -n | tail -n 1)"
    printf '%s\n' "$sp11" | grep -E "sp11v${newest_suffix}" | sort -V | tail -n 1
  else
    printf '%s\n' "$@" | sort -V | tail -n 1
  fi
}

find_dtb() {
  local name pattern path candidates rfkill_candidates
  for name in "${DTB_NAMES[@]}"; do
    candidates=()
    for pattern in \
      "/usr/lib/firmware/*/device-tree/qcom/$name" \
      "/usr/lib/linux-image-*/qcom/$name" \
      "/boot/dtbs/*/qcom/$name" \
      "/boot/dtbs/*/$name" \
      "/boot/$name"; do
      for path in $pattern; do
        [ -f "$path" ] && candidates+=("$path")
      done
    done
    if [ "${#candidates[@]}" -gt 0 ]; then
      rfkill_candidates=()
      for path in "${candidates[@]}"; do
        if grep -a -q 'disable-rfkill' "$path" 2>/dev/null; then
          rfkill_candidates+=("$path")
        fi
      done
      if [ "${#rfkill_candidates[@]}" -gt 0 ]; then
        pick_dtb "${rfkill_candidates[@]}"
      else
        pick_dtb "${candidates[@]}"
      fi
      return 0
    fi
  done
  return 1
}

dtb="$(find_dtb || true)"
if [ -z "$dtb" ]; then
  echo "Warning: Surface Pro 11 Denali DTB not found; GRUB DTB injection skipped." >&2
  exit 0
fi

install -m 0644 "$dtb" "$BOOT_DTB"
echo "Using Surface Pro 11 DTB: $dtb"

if [ ! -f "$GRUB_CFG" ]; then
  echo "Warning: $GRUB_CFG not found; run update-grub first." >&2
  exit 0
fi

tmp="$(mktemp)"
awk -v dtb="$BOOT_DTB_NAME" '
  /^[ \t]*devicetree[ \t]+\/(boot\/)?(x1p64100-microsoft-denali|x1e80100-microsoft-denali(-oled|-oled-el2)?|sp11-denali)\.dtb([ \t]|$)/ {
    next
  }
  /^[ \t]*linux[ \t]/ {
    print
    match($0, /^[ \t]*/)
    indent = substr($0, RSTART, RLENGTH)
    rest = $0
    sub(/^[ \t]*linux[ \t]+/, "", rest)
    split(rest, fields, /[ \t]+/)
    kernel = fields[1]
    if (kernel ~ /^\/boot\//) {
      print indent "devicetree /boot/" dtb
    } else {
      print indent "devicetree /" dtb
    }
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
# Enable SP11 feedback-port Offset2 parity used by the geocausa reference cmdline.
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE_LINUX_DEFAULT} clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0 soundwire_qcom.sp11_feedback_active_offset2_zero=1"
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
