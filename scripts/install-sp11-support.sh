#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/}"
USB_SAFE="false"
RETIRE_LOOSE_DTB_ONLY="false"
STATE_BACKUP_REL=""

usage() {
  cat <<EOF
Usage: sudo $0 [--installed-system | --usb-safe] [--retire-loose-dtb-only] [--root DIR]

Installs Surface Pro 11 Ubuntu support helpers into an installed Ubuntu root.

  --installed-system   Configure for NVMe-installed Ubuntu.
  --usb-safe           Add the qcom_q6v5_pas blacklist for live USB boot.
  --retire-loose-dtb-only
                       Retire only the obsolete installed loose-DTB helper and
                       hooks, then regenerate GRUB when the target root is /.
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
    --retire-loose-dtb-only)
      RETIRE_LOOSE_DTB_ONLY="true"
      shift
      ;;
    --root)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --root." >&2
        usage >&2
        exit 2
      fi
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

if [ "$RETIRE_LOOSE_DTB_ONLY" = "true" ] && [ "$USB_SAFE" = "true" ]; then
  echo "--retire-loose-dtb-only cannot be combined with --usb-safe." >&2
  exit 2
fi

if [ "$EUID" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

case "$ROOT" in
  /*) ;;
  *)
    echo "--root must be an absolute path: $ROOT" >&2
    exit 2
    ;;
esac

if [ ! -d "$ROOT" ]; then
  echo "Target root does not exist: $ROOT" >&2
  exit 1
fi

ROOT="$(cd "$ROOT" && pwd -P)"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

target() {
  local rel="${1#/}"
  printf '%s/%s' "${ROOT%/}" "$rel"
}

offline_path_error() {
  local rel="$1" reason="$2"

  echo "Unsafe offline target path $rel: $reason" >&2
  return 1
}

assert_offline_directory_chain_safe() {
  local rel="$1" symlink_policy="${2:-allow-contained}"
  local trimmed component candidate resolved

  # The live system has legitimate distribution-managed symlinks. Containment
  # is an offline-root property, so retain the established live-root behavior.
  if [ "$ROOT" = "/" ]; then
    return 0
  fi

  case "$rel" in
    /*) ;;
    *)
      offline_path_error "$rel" "managed paths must be absolute"
      return 1
      ;;
  esac
  trimmed="${rel#/}"
  case "/$trimmed/" in
    *"/../"*|*"/./"*|*"//"*)
      offline_path_error "$rel" "dot and empty path components are not allowed"
      return 1
      ;;
  esac

  candidate="${ROOT%/}"
  while [ -n "$trimmed" ]; do
    component="${trimmed%%/*}"
    if [ "$trimmed" = "$component" ]; then
      trimmed=""
    else
      trimmed="${trimmed#*/}"
    fi
    candidate="$candidate/$component"

    if [ -L "$candidate" ] && [ "$symlink_policy" = "reject" ]; then
      offline_path_error "$rel" "directory component is a symlink: $candidate"
      return 1
    fi
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      if [ ! -d "$candidate" ]; then
        offline_path_error "$rel" "directory component is not a real directory: $candidate"
        return 1
      fi
      resolved="$(cd "$candidate" && pwd -P)"
      case "$resolved" in
        "$ROOT"|"$ROOT"/*) ;;
        *)
          offline_path_error "$rel" \
            "directory component resolves outside the target root: $candidate"
          return 1
          ;;
      esac
    fi
  done
}

assert_offline_target_parent_safe() {
  local rel="$1" symlink_policy="${2:-allow-contained}" parent

  parent="${rel%/*}"
  [ -n "$parent" ] || parent="/"
  assert_offline_directory_chain_safe "$parent" "$symlink_policy"
}

assert_offline_managed_file_safe() {
  local rel="$1" path

  assert_offline_target_parent_safe "$rel" allow-contained
  path="$(target "$rel")"
  if [ -L "$path" ]; then
    offline_path_error "$rel" "managed file leaf is a symlink"
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    offline_path_error "$rel" "managed file leaf is not a regular file"
    return 1
  fi
}

assert_managed_symlink_leaf_safe() {
  local rel="$1" path

  assert_offline_target_parent_safe "$rel" allow-contained
  path="$(target "$rel")"
  if [ -L "$path" ]; then
    return 0
  fi
  if [ -e "$path" ]; then
    offline_path_error "$rel" \
      "managed symlink leaf exists but is not already a symlink"
    return 1
  fi
}

assert_retirement_file_leaf_safe() {
  local rel="$1" path

  path="$(target "$rel")"
  if [ -L "$path" ]; then
    offline_path_error "$rel" "retirement file leaf is a symlink"
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    offline_path_error "$rel" "retirement file leaf is not a regular file"
    return 1
  fi
}

preflight_managed_loose_dtb_artifacts() {
  # Reject every symlinked parent before removing any artifact. This makes the
  # three-path retirement operation fail closed and all-or-nothing offline.
  assert_offline_target_parent_safe \
    /usr/local/sbin/sp11-grub-inject-dtb reject
  assert_offline_target_parent_safe \
    /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb reject
  assert_offline_target_parent_safe \
    /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb reject
  assert_offline_target_parent_safe /boot/sp11-denali.dtb reject

  # Inspect every removal leaf before deleting the first one. Unexpected
  # symlinks or special nodes must not turn an exact three-file retirement into
  # a partial transaction.
  assert_retirement_file_leaf_safe /usr/local/sbin/sp11-grub-inject-dtb
  assert_retirement_file_leaf_safe \
    /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb
  assert_retirement_file_leaf_safe \
    /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb
}

preflight_full_install_destinations() {
  local rel

  for rel in \
    /usr/local/sbin \
    /etc/default/grub.d \
    /etc/kernel/postinst.d \
    /etc/kernel/postrm.d \
    /etc/apt/apt.conf.d \
    /lib/firmware/qcom/x1e80100 \
    /usr/share/alsa/ucm2/Qualcomm/x1e80100 \
    /usr/share/alsa/ucm2/conf.d/x1e80100 \
    /etc/systemd/system \
    /etc/systemd/system/multi-user.target.wants \
    /var/lib/alsa; do
    assert_offline_directory_chain_safe "$rel" allow-contained
  done

  for rel in \
    /usr/local/sbin/sp11-grab-fw \
    /usr/local/sbin/sp11-wifi-board-fixup \
    /usr/local/sbin/sp11-bluetooth-mac \
    /usr/local/sbin/troubleshoot-sp11-audio \
    /usr/local/sbin/troubleshoot-sp11-bluetooth \
    /usr/local/sbin/troubleshoot-sp11-wifi-rfkill \
    /usr/local/sbin/install-sp11-touchscreen \
    /usr/local/sbin/troubleshoot-sp11-touchscreen \
    /usr/local/sbin/sp11-pipewire-speaker-sink \
    /usr/local/sbin/sp11-audio-topology \
    /usr/local/sbin/sp11-enable-wsa-routing \
    /usr/local/sbin/sp11-fix-audio-boot-race \
    /etc/default/grub.d/99-surface-pro-11.cfg \
    /etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup \
    /var/lib/alsa/asound.state; do
    assert_offline_managed_file_safe "$rel"
  done
  STATE_BACKUP_REL="/var/lib/alsa/asound.state.bak.$(date +%Y%m%d%H%M%S)"
  assert_offline_managed_file_safe "$STATE_BACKUP_REL"

  if [ -f "$repo_dir/scripts/systemd/sp11-wsa-routing.service" ]; then
    assert_offline_managed_file_safe \
      /etc/systemd/system/sp11-wsa-routing.service
    assert_managed_symlink_leaf_safe \
      /etc/systemd/system/alsa-restore.service
    assert_managed_symlink_leaf_safe \
      /etc/systemd/system/alsa-state.service
    assert_managed_symlink_leaf_safe \
      /etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service
  fi
  if [ -f "$repo_dir/payload/audio/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" ]; then
    assert_offline_managed_file_safe \
      /lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin
  fi
  if [ -f "$repo_dir/payload/audio/MICROSOFT-Surface-Pro-11.conf" ]; then
    assert_offline_managed_file_safe \
      /usr/share/alsa/ucm2/Qualcomm/x1e80100/MICROSOFT-Surface-Pro-11.conf
  fi
  if [ -f "$repo_dir/payload/audio/Surface11-HiFi.conf" ]; then
    assert_offline_managed_file_safe \
      /usr/share/alsa/ucm2/Qualcomm/x1e80100/Surface11-HiFi.conf
  fi
  if [ -f "$repo_dir/payload/audio/x1e80100.conf" ]; then
    assert_offline_managed_file_safe \
      /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf
  fi
}

retire_managed_loose_dtb_artifact() {
  local rel="$1" path

  path="$(target "$rel")"
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f -- "$path"
    echo "Retired project-managed loose-DTB artifact: $rel"
  fi
}

retire_managed_loose_dtb_artifacts() {
  local legacy_loose_dtb

  retire_managed_loose_dtb_artifact /usr/local/sbin/sp11-grub-inject-dtb
  retire_managed_loose_dtb_artifact /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb
  retire_managed_loose_dtb_artifact /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb

  legacy_loose_dtb="$(target /boot/sp11-denali.dtb)"
  if [ -e "$legacy_loose_dtb" ] || [ -L "$legacy_loose_dtb" ]; then
    echo "Existing /boot/sp11-denali.dtb was left untouched as inert recovery evidence."
  fi
}

regenerate_grub_after_loose_dtb_retirement() {
  if [ "$ROOT" = "/" ]; then
    if ! command -v update-grub >/dev/null 2>&1; then
      echo "update-grub is required to retire generated loose-DTB references." >&2
      return 1
    fi
    update-grub
  else
    echo "GRUB regeneration deferred for offline target root; target grub.cfg was not modified."
  fi
}

preflight_managed_loose_dtb_artifacts
if [ "$RETIRE_LOOSE_DTB_ONLY" != "true" ]; then
  preflight_full_install_destinations
fi

retire_managed_loose_dtb_artifacts

if [ "$RETIRE_LOOSE_DTB_ONLY" = "true" ]; then
  regenerate_grub_after_loose_dtb_retirement
  echo "Retired installed loose-DTB integration in $ROOT"
  exit 0
fi

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
install -m 0755 "$repo_dir/scripts/sp11-enable-wsa-routing.sh" "$(target /usr/local/sbin/sp11-enable-wsa-routing)"
install -m 0755 "$repo_dir/scripts/sp11-fix-audio-boot-race.sh" "$(target /usr/local/sbin/sp11-fix-audio-boot-race)"

# --- Audio boot race fix: mask alsa-restore, install WSA routing service ---
# alsactl restores WSA mixer state at boot before the AudioReach DSP finishes
# loading the audio graph, causing an APM CMD timeout, SoundWire bus clash,
# and no audio. Mask alsa-restore and use a dedicated service instead.
# See docs/adr/adr-0035-audio-boot-race-alsactl.md.
if [ -f "$repo_dir/scripts/systemd/sp11-wsa-routing.service" ]; then
  install -d "$(target /etc/systemd/system)"
  install -m 0644 "$repo_dir/scripts/systemd/sp11-wsa-routing.service" \
    "$(target /etc/systemd/system/sp11-wsa-routing.service)"

  # Mask alsa-restore so it doesn't race the DSP at boot
  if [ "$ROOT" = "/" ]; then
    systemctl mask alsa-restore.service 2>/dev/null || true
    systemctl mask alsa-state.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable sp11-wsa-routing.service 2>/dev/null || true
  else
    # For chroot/target installs, create the mask symlinks manually
    ln -sfn /dev/null "$(target /etc/systemd/system/alsa-restore.service)"
    ln -sfn /dev/null "$(target /etc/systemd/system/alsa-state.service)"
    # Enable via symlink (will be picked up after chroot boot)
    ln -sfn /etc/systemd/system/sp11-wsa-routing.service \
      "$(target /etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service)" 2>/dev/null || true
  fi

  # Clear WSA controls from asound.state if it exists
  local_state="$(target /var/lib/alsa/asound.state)"
  if [ -f "$local_state" ]; then
    cp "$local_state" "$(target "$STATE_BACKUP_REL")"
    tmp="$(mktemp)"
    awk '
      BEGIN { skip=0 }
      /^[[:space:]]*control\.[0-9]+[[:space:]]*\{/ {
        block=""; skip=0; collecting=1
      }
      collecting==1 {
        block = block $0 "\n"
        if ($0 ~ /^[[:space:]]*name[[:space:]]/) {
          if ($0 ~ /WSA|Spkr/) { skip=1 }
        }
        if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) {
          collecting=0
          if (skip==0) { printf "%s", block }
        }
        next
      }
      { print }
    ' "$local_state" > "$tmp"
    [ -s "$tmp" ] && cp "$tmp" "$local_state" || true
    rm -f "$tmp"
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

cat > "$(target /etc/apt/apt.conf.d/99surface-pro-11-wifi-fixup)" <<'EOF'
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/sp11-wifi-board-fixup ]; then /usr/local/sbin/sp11-wifi-board-fixup || true; fi"; };
EOF

regenerate_grub_after_loose_dtb_retirement
if [ "$ROOT" = "/" ]; then
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all || true
  fi
fi

echo "Installed Surface Pro 11 support helpers into $ROOT"
