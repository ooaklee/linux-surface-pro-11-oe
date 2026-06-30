#!/usr/bin/env bash
set -euo pipefail

# Installs the KDE Plasma desktop (kubuntu-desktop) on an installed Ubuntu
# system for the Surface Pro 11 bring-up. There is no official Kubuntu ARM64
# ISO, so this is the reproducible equivalent of running
# "sudo apt install kubuntu-desktop" on the installed system.
#
# This is a desktop-environment swap only. It does not touch the SP11 kernel,
# DTB, firmware, audio, or Bluetooth bring-up handled by install-sp11-support.sh
# and the other sp11-* helpers; those continue to work under Plasma exactly as
# they do under GNOME.
#
# By default GNOME is kept alongside Plasma so the switch can be validated
# before committing. Use --purge-gnome to remove the GNOME stack after
# confirming Plasma works.
#
# Run from the booted installed Ubuntu system:
#   sudo ./scripts/sp11-install-kde-desktop.sh
#
# Or from the live USB against a mounted installed target:
#   sudo ./scripts/sp11-install-kde-desktop.sh --target /target
#
# The default display manager is switched to SDDM. With --purge-gnome, gdm3,
# gnome-shell, and the ubuntu-desktop metapackage are removed and obsolete
# packages are autoremoved.

TARGET="/"
PURGE_GNOME="false"
REBOOT="false"
YES="false"

usage() {
  cat <<EOF
Usage: sudo $0 [--target DIR] [--purge-gnome] [--reboot] [-y]

Installs kubuntu-desktop (KDE Plasma) on the installed Ubuntu system.

Options:
  --target DIR     Target root, default / (the running installed system).
                   When set to a mounted installed root, packages are
                   installed via chroot. Booted-system mode is preferred;
                   chroot mode is best-effort because display-manager
                   postinst scripts may talk to systemd.
  --purge-gnome    Remove ubuntu-desktop, gdm3, gnome-shell and let apt
                   autoremove the now-orphaned GNOME packages. Off by
                   default; validate Plasma first.
  --reboot         Reboot after a successful install.
  -y, --yes        Non-interactive: pass -y to apt and preseed debconf.
  -h, --help       Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target|--root)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      TARGET="$2"
      shift 2
      ;;
    --purge-gnome)
      PURGE_GNOME="true"
      shift
      ;;
    --reboot)
      REBOOT="true"
      shift
      ;;
    -y|--yes)
      YES="true"
      shift
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

CHROOT_MODE="false"
if [ "$TARGET" != "/" ]; then
  CHROOT_MODE="true"
  if [ ! -d "$TARGET" ] || [ ! -d "$TARGET/usr" ]; then
    echo "Target does not look like an installed root: $TARGET" >&2
    exit 1
  fi
fi

apt_yes=()
if [ "$YES" = "true" ]; then
  apt_yes=(-y)
fi

run_in_target() {
  if [ "$CHROOT_MODE" = "true" ]; then
    chroot "$TARGET" "$@"
  else
    "$@"
  fi
}

preseed_in_target() {
  local line="$1"
  if [ "$CHROOT_MODE" = "true" ]; then
    echo "$line" | chroot "$TARGET" debconf-set-selections
  else
    echo "$line" | debconf-set-selections
  fi
}

setup_chroot() {
  [ "$CHROOT_MODE" = "false" ] && return 0
  mount --bind /proc "$TARGET/proc"
  mount --bind /sys "$TARGET/sys"
  mount --bind /dev "$TARGET/dev"
  mount --bind /run "$TARGET/run" 2>/dev/null || true
  if [ -f /etc/resolv.conf ] && [ ! -e "$TARGET/etc/resolv.conf.sp11-kde-bak" ]; then
    { [ -e "$TARGET/etc/resolv.conf" ] || [ -L "$TARGET/etc/resolv.conf" ]; } &&
      cp -a "$TARGET/etc/resolv.conf" "$TARGET/etc/resolv.conf.sp11-kde-bak" || true
    rm -f "$TARGET/etc/resolv.conf"
    cp /etc/resolv.conf "$TARGET/etc/resolv.conf"
  fi
}

teardown_chroot() {
  [ "$CHROOT_MODE" = "false" ] && return 0
  if [ -e "$TARGET/etc/resolv.conf.sp11-kde-bak" ] ||
    [ -L "$TARGET/etc/resolv.conf.sp11-kde-bak" ]; then
    rm -f "$TARGET/etc/resolv.conf"
    mv "$TARGET/etc/resolv.conf.sp11-kde-bak" "$TARGET/etc/resolv.conf" 2>/dev/null || true
  fi
  umount "$TARGET/run" 2>/dev/null || true
  umount "$TARGET/dev" 2>/dev/null || true
  umount "$TARGET/sys" 2>/dev/null || true
  umount "$TARGET/proc" 2>/dev/null || true
}

trap teardown_chroot EXIT

setup_chroot

echo "== SP11: installing KDE Plasma (kubuntu-desktop) on $TARGET =="
if [ "$PURGE_GNOME" = "true" ]; then
  echo "   GNOME will be purged after Plasma installs."
else
  echo "   GNOME will be kept alongside Plasma."
fi
[ "$CHROOT_MODE" = "true" ] && echo "   (chroot mode; display-manager postinst may be limited)"

# Pre-seed SDDM as the default display manager so the kubuntu-desktop debconf
# prompt does not block and does not fall back to gdm3.
preseed_in_target "sddm shared/default-x-display-manager select sddm"
preseed_in_target "sddm sddm/daemon_name string sddm"
preseed_in_target "gdm3 shared/default-x-display-manager select sddm"

run_in_target apt-get update

DEBIAN_FRONTEND=noninteractive run_in_target \
  env DEBIAN_FRONTEND=noninteractive \
  apt-get install "${apt_yes[@]}" kubuntu-desktop

# Make sure SDDM is the active default display manager on the running system.
# "systemctl enable sddm" alone is not enough: on Ubuntu the active display
# manager is selected by the /etc/systemd/system/display-manager.service
# symlink, which the sddm postinst does not always create when debconf
# preseeding is used. Create it explicitly in both modes.
if [ "$CHROOT_MODE" = "false" ]; then
  if command -v sddm >/dev/null 2>&1; then
    echo /usr/bin/sddm > /etc/X11/default-display-manager 2>/dev/null || true
    systemctl disable gdm3 2>/dev/null || true
    systemctl enable sddm 2>/dev/null || true
    ln -sf /lib/systemd/system/sddm.service \
      /etc/systemd/system/display-manager.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi
else
  if [ -x "$TARGET/usr/bin/sddm" ]; then
    echo /usr/bin/sddm > "$TARGET/etc/X11/default-display-manager" 2>/dev/null || true
    ln -sf /lib/systemd/system/sddm.service \
      "$TARGET/etc/systemd/system/display-manager.service" 2>/dev/null || true
  fi
fi

if [ "$PURGE_GNOME" = "true" ]; then
  echo "== SP11: purging GNOME stack =="
  DEBIAN_FRONTEND=noninteractive run_in_target \
    env DEBIAN_FRONTEND=noninteractive \
    apt-get purge "${apt_yes[@]}" gdm3 gnome-shell ubuntu-desktop || true
  DEBIAN_FRONTEND=noninteractive run_in_target \
    env DEBIAN_FRONTEND=noninteractive \
    apt-get autoremove "${apt_yes[@]}" --purge || true
fi

run_in_target apt-get clean

echo "== SP11: KDE Plasma install complete =="
if [ "$CHROOT_MODE" = "true" ]; then
  echo "Packages installed via chroot into $TARGET. Boot the installed system"
  echo "and run this script again with --target / (default) to finalize the"
  echo "display-manager postinst and systemctl state, or simply enable sddm"
  echo "after first boot."
else
  echo "Default display manager: $(cat /etc/X11/default-display-manager 2>/dev/null || echo unknown)"
  echo "Log out (or reboot) and select the Plasma session from SDDM."
fi

if [ "$REBOOT" = "true" ] && [ "$CHROOT_MODE" = "false" ]; then
  echo "Rebooting in 3 seconds..."
  sleep 3
  reboot
fi
