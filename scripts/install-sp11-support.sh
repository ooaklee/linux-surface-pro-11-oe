#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/}"
USB_SAFE="false"
RETIRE_LOOSE_DTB_ONLY="false"
STATE_BACKUP_REL=""
LIVE_ROOT="false"
RETIRE_TX_PREPARED="false"
RETIRE_TX_COMMITTED="false"
RETIRE_STAGE_STARTED="false"
RETIRE_ROLLBACK_INCOMPLETE="false"
RETIRE_MANAGED_RELS=(
  /usr/local/sbin/sp11-grub-inject-dtb
  /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb
  /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb
)
RETIRE_DESTINATIONS=()
RETIRE_BACKUP_DIRS=()
RETIRE_ALL_BACKUP_DIRS=()
RETIRE_HAD_OLD=()
RETIRE_ORIGINAL_IDENTITIES=()
RETIRE_ORIGINAL_FINGERPRINTS=()
RETIRE_GRUB_CFG=""
RETIRE_GRUB_CFG_BACKUP=""
RETIRE_GRUB_CFG_ORIGINAL_IDENTITY=""
RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT=""
RETIRE_GRUB_CFG_GENERATED_IDENTITY=""
RETIRE_GRUBENV=""
RETIRE_GRUBENV_BACKUP=""
RETIRE_GRUBENV_ORIGINAL_IDENTITY=""
RETIRE_GRUBENV_ORIGINAL_FINGERPRINT=""
RETIRE_LOOSE_DTB=""
RETIRE_LOOSE_DTB_BACKUP=""
RETIRE_LOOSE_DTB_HAD_OLD="false"
RETIRE_LOOSE_DTB_ORIGINAL_IDENTITY=""
RETIRE_LOOSE_DTB_ORIGINAL_FINGERPRINT=""
RETIRE_RESERVED_BACKUP=""
RETIRE_CAPTURED_PATH=""
RETIRE_CAPTURED_IDENTITY=""
RETIRE_CAPTURED_PRESENT="false"

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
if [ "$ROOT" = "/" ]; then
  LIVE_ROOT="true"
fi

target() {
  local rel="${1#/}"
  printf '%s/%s' "${ROOT%/}" "$rel"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    return 1
  fi
}

regular_file_identity() {
  local path="$1" metadata checksum

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if metadata="$(stat -c '%d:%i:%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%d:%i:%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  checksum="$(sha256_file "$path")" || return 1
  case "$checksum" in
    ""|*[!0-9A-Fa-f]*) return 1 ;;
  esac
  printf '%s:%s\n' "$metadata" "$checksum"
}

preserved_file_fingerprint() {
  local path="$1" metadata checksum

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if metadata="$(stat -c '%a:%u:%g:%s:%Y' -- "$path" 2>/dev/null)"; then
    :
  elif metadata="$(stat -f '%Lp:%u:%g:%z:%m' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  checksum="$(sha256_file "$path")" || return 1
  case "$checksum" in
    ""|*[!0-9A-Fa-f]*) return 1 ;;
  esac
  printf '%s:%s\n' "$metadata" "$checksum"
}

file_mode() {
  local mode

  if mode="$(stat -c '%a' -- "$1" 2>/dev/null)"; then
    :
  elif mode="$(stat -f '%Lp' "$1" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  case "$mode" in
    ""|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$mode"
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
  if [ "$ROOT" = "/" ] && [ "$symlink_policy" != "reject" ]; then
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
      case "$ROOT" in
        /) ;;
        *)
          case "$resolved" in
            "$ROOT"|"$ROOT"/*) ;;
            *)
              offline_path_error "$rel" \
                "directory component resolves outside the target root: $candidate"
              return 1
              ;;
          esac
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
  assert_retirement_file_leaf_safe /boot/sp11-denali.dtb
}

preflight_live_retirement_state() {
  local rel path

  for rel in /boot/grub/grub.cfg /boot/grub/grubenv; do
    assert_offline_target_parent_safe "$rel" reject
    assert_retirement_file_leaf_safe "$rel"
    path="$(target "$rel")"
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      echo "Live retirement requires a regular, non-symlinked $rel." >&2
      return 1
    fi
  done
  if [ ! -s "$(target /boot/grub/grub.cfg)" ]; then
    echo "Live retirement requires a nonempty /boot/grub/grub.cfg." >&2
    return 1
  fi
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

retirement_warn() {
  echo "warning: $*" >&2
}

reserve_retirement_backup() {
  local destination="$1" parent

  parent="$(dirname "$destination")"
  RETIRE_RESERVED_BACKUP="$(
    mktemp -d "$parent/.sp11-loose-dtb-retirement-backup.XXXXXX"
  )" || {
    echo "Could not reserve a private retirement backup in $parent." >&2
    return 1
  }
  RETIRE_ALL_BACKUP_DIRS+=("$RETIRE_RESERVED_BACKUP")
  chmod 0700 "$RETIRE_RESERVED_BACKUP" || {
    echo "Could not secure retirement backup: $RETIRE_RESERVED_BACKUP" >&2
    return 1
  }
  if [ ! -d "$RETIRE_RESERVED_BACKUP" ] ||
     [ -L "$RETIRE_RESERVED_BACKUP" ] ||
     [ "$(file_mode "$RETIRE_RESERVED_BACKUP")" != "700" ]; then
    echo "Retirement backup is not a private directory: $RETIRE_RESERVED_BACKUP" >&2
    return 1
  fi
  case "$RETIRE_RESERVED_BACKUP" in
    "$parent"/.sp11-loose-dtb-retirement-backup.*) ;;
    *)
      echo "Retirement backup escaped its destination filesystem: $RETIRE_RESERVED_BACKUP" >&2
      return 1
      ;;
  esac
}

snapshot_retirement_file() {
  local source="$1" backup="$2" description="$3"
  local before after source_fingerprint backup_fingerprint

  before="$(regular_file_identity "$source")" || {
    echo "$description changed type before it could be snapshotted: $source" >&2
    return 1
  }
  source_fingerprint="$(preserved_file_fingerprint "$source")" || return 1
  cp -p -- "$source" "$backup/original" || {
    echo "Could not snapshot $description: $source" >&2
    return 1
  }
  after="$(regular_file_identity "$source")" || return 1
  backup_fingerprint="$(preserved_file_fingerprint "$backup/original")" || return 1
  if [ "$after" != "$before" ] ||
     [ "$backup_fingerprint" != "$source_fingerprint" ]; then
    echo "$description changed while it was being snapshotted: $source" >&2
    return 1
  fi
}

state_matches_original() {
  local path="$1" had_old="$2" identity="$3" current

  if [ "$had_old" = "true" ]; then
    current="$(regular_file_identity "$path" 2>/dev/null || true)"
    [ -n "$current" ] && [ "$current" = "$identity" ]
  else
    [ ! -e "$path" ] && [ ! -L "$path" ]
  fi
}

prepare_retirement_transaction() {
  local index rel destination identity fingerprint

  RETIRE_TX_PREPARED="true"
  for ((index=0; index<${#RETIRE_MANAGED_RELS[@]}; index++)); do
    rel="${RETIRE_MANAGED_RELS[index]}"
    destination="$(target "$rel")"
    RETIRE_DESTINATIONS+=("$destination")
    RETIRE_BACKUP_DIRS+=("")
    RETIRE_HAD_OLD+=("false")
    RETIRE_ORIGINAL_IDENTITIES+=("")
    RETIRE_ORIGINAL_FINGERPRINTS+=("")
    if [ -f "$destination" ] && [ ! -L "$destination" ]; then
      RETIRE_HAD_OLD[index]="true"
      identity="$(regular_file_identity "$destination")" || return 1
      fingerprint="$(preserved_file_fingerprint "$destination")" || return 1
      RETIRE_ORIGINAL_IDENTITIES[index]="$identity"
      RETIRE_ORIGINAL_FINGERPRINTS[index]="$fingerprint"
      reserve_retirement_backup "$destination"
      RETIRE_BACKUP_DIRS[index]="$RETIRE_RESERVED_BACKUP"
      snapshot_retirement_file \
        "$destination" "$RETIRE_RESERVED_BACKUP" \
        "managed retirement leaf"
    fi
  done

  RETIRE_LOOSE_DTB="$(target /boot/sp11-denali.dtb)"
  if [ -f "$RETIRE_LOOSE_DTB" ] && [ ! -L "$RETIRE_LOOSE_DTB" ]; then
    RETIRE_LOOSE_DTB_HAD_OLD="true"
    RETIRE_LOOSE_DTB_ORIGINAL_IDENTITY="$(
      regular_file_identity "$RETIRE_LOOSE_DTB"
    )" || return 1
    RETIRE_LOOSE_DTB_ORIGINAL_FINGERPRINT="$(
      preserved_file_fingerprint "$RETIRE_LOOSE_DTB"
    )" || return 1
    reserve_retirement_backup "$RETIRE_LOOSE_DTB"
    RETIRE_LOOSE_DTB_BACKUP="$RETIRE_RESERVED_BACKUP"
    snapshot_retirement_file \
      "$RETIRE_LOOSE_DTB" "$RETIRE_LOOSE_DTB_BACKUP" \
      "historical loose DTB"
  fi

  if [ "$LIVE_ROOT" = "true" ]; then
    RETIRE_GRUB_CFG="$(target /boot/grub/grub.cfg)"
    RETIRE_GRUB_CFG_ORIGINAL_IDENTITY="$(
      regular_file_identity "$RETIRE_GRUB_CFG"
    )" || return 1
    RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT="$(
      preserved_file_fingerprint "$RETIRE_GRUB_CFG"
    )" || return 1
    reserve_retirement_backup "$RETIRE_GRUB_CFG"
    RETIRE_GRUB_CFG_BACKUP="$RETIRE_RESERVED_BACKUP"
    snapshot_retirement_file \
      "$RETIRE_GRUB_CFG" "$RETIRE_GRUB_CFG_BACKUP" "live grub.cfg"

    RETIRE_GRUBENV="$(target /boot/grub/grubenv)"
    RETIRE_GRUBENV_ORIGINAL_IDENTITY="$(
      regular_file_identity "$RETIRE_GRUBENV"
    )" || return 1
    RETIRE_GRUBENV_ORIGINAL_FINGERPRINT="$(
      preserved_file_fingerprint "$RETIRE_GRUBENV"
    )" || return 1
    reserve_retirement_backup "$RETIRE_GRUBENV"
    RETIRE_GRUBENV_BACKUP="$RETIRE_RESERVED_BACKUP"
    snapshot_retirement_file \
      "$RETIRE_GRUBENV" "$RETIRE_GRUBENV_BACKUP" "live grubenv"
  fi
}

verify_retirement_prestate() {
  local index destination

  for ((index=0; index<${#RETIRE_DESTINATIONS[@]}; index++)); do
    destination="${RETIRE_DESTINATIONS[index]}"
    if ! state_matches_original \
      "$destination" "${RETIRE_HAD_OLD[index]}" \
      "${RETIRE_ORIGINAL_IDENTITIES[index]}"; then
      echo "Managed retirement leaf changed after preflight: $destination" >&2
      return 1
    fi
  done
  if ! state_matches_original \
    "$RETIRE_LOOSE_DTB" "$RETIRE_LOOSE_DTB_HAD_OLD" \
    "$RETIRE_LOOSE_DTB_ORIGINAL_IDENTITY"; then
    echo "Historical loose DTB changed after preflight: $RETIRE_LOOSE_DTB" >&2
    return 1
  fi
  if [ "$LIVE_ROOT" = "true" ]; then
    if ! state_matches_original \
      "$RETIRE_GRUB_CFG" true "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"; then
      echo "Live grub.cfg changed after preflight: $RETIRE_GRUB_CFG" >&2
      return 1
    fi
    if ! state_matches_original \
      "$RETIRE_GRUBENV" true "$RETIRE_GRUBENV_ORIGINAL_IDENTITY"; then
      echo "Live grubenv changed after preflight: $RETIRE_GRUBENV" >&2
      return 1
    fi
  fi
}

stage_managed_retirement() {
  local index destination backup

  RETIRE_STAGE_STARTED="true"
  for ((index=0; index<${#RETIRE_DESTINATIONS[@]}; index++)); do
    if [ "${RETIRE_HAD_OLD[index]}" != "true" ]; then
      continue
    fi
    destination="${RETIRE_DESTINATIONS[index]}"
    backup="${RETIRE_BACKUP_DIRS[index]}"
    if ! state_matches_original \
      "$destination" true "${RETIRE_ORIGINAL_IDENTITIES[index]}"; then
      echo "Managed retirement leaf changed before retirement: $destination" >&2
      return 1
    fi
    if [ -z "$backup" ] ||
       [ "$(preserved_file_fingerprint \
         "$backup/original" 2>/dev/null || true)" != \
         "${RETIRE_ORIGINAL_FINGERPRINTS[index]}" ]; then
      echo "Managed retirement snapshot changed before retirement: $destination" >&2
      return 1
    fi
    if ! mv "$destination" "$backup/retired"; then
      echo "Could not stage managed retirement leaf: $destination" >&2
      return 1
    fi
    if [ "$(regular_file_identity "$backup/retired" 2>/dev/null || true)" != \
         "${RETIRE_ORIGINAL_IDENTITIES[index]}" ]; then
      echo "Managed retirement backup lost identity: $backup/retired" >&2
      return 1
    fi
    echo "Retired project-managed loose-DTB artifact: ${RETIRE_MANAGED_RELS[index]}"
  done
  if [ "$LIVE_ROOT" = "true" ]; then
    if ! state_matches_original \
      "$RETIRE_GRUB_CFG" true "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"; then
      echo "Live grub.cfg changed before GRUB regeneration." >&2
      return 1
    fi
    if [ "$(preserved_file_fingerprint \
      "$RETIRE_GRUB_CFG_BACKUP/original" 2>/dev/null || true)" != \
      "$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT" ]; then
      echo "The live grub.cfg snapshot changed before GRUB regeneration." >&2
      return 1
    fi
    if ! mv "$RETIRE_GRUB_CFG" "$RETIRE_GRUB_CFG_BACKUP/retired"; then
      echo "Could not stage the prior live grub.cfg for GRUB regeneration." >&2
      return 1
    fi
    if [ "$(regular_file_identity \
      "$RETIRE_GRUB_CFG_BACKUP/retired" 2>/dev/null || true)" != \
      "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY" ]; then
      echo "The staged prior grub.cfg lost identity." >&2
      return 1
    fi
  fi
}

grub_cfg_has_project_loose_dtb() {
  LC_ALL=C awk '
    /^[[:space:]]*devicetree[[:space:]]+/ {
      value = $0
      sub(/^[[:space:]]*devicetree[[:space:]]+/, "", value)
      sub(/[[:space:]]+#.*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      gsub(/["\047]/, "", value)
      if (value == "/sp11-denali.dtb" ||
          value == "/boot/sp11-denali.dtb") {
        found = 1
      }
    }
    END { exit !found }
  ' "$1"
}

postcheck_retirement_transaction() {
  local index destination

  for ((index=0; index<${#RETIRE_DESTINATIONS[@]}; index++)); do
    destination="${RETIRE_DESTINATIONS[index]:-}"
    [ -n "$destination" ] || continue
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      echo "Managed retirement leaf reappeared: $destination" >&2
      return 1
    fi
  done
  if ! state_matches_original \
    "$RETIRE_LOOSE_DTB" "$RETIRE_LOOSE_DTB_HAD_OLD" \
    "$RETIRE_LOOSE_DTB_ORIGINAL_IDENTITY"; then
    echo "Historical loose DTB changed during retirement." >&2
    return 1
  fi
  if [ "$LIVE_ROOT" = "true" ]; then
    if [ ! -f "$RETIRE_GRUB_CFG" ] || [ -L "$RETIRE_GRUB_CFG" ] ||
       [ ! -s "$RETIRE_GRUB_CFG" ]; then
      echo "update-grub did not produce a regular, nonempty grub.cfg." >&2
      return 1
    fi
    RETIRE_GRUB_CFG_GENERATED_IDENTITY="$(
      regular_file_identity "$RETIRE_GRUB_CFG"
    )" || return 1
    if grub_cfg_has_project_loose_dtb "$RETIRE_GRUB_CFG"; then
      echo "Generated grub.cfg still contains the project-managed loose-DTB reference." >&2
      return 1
    fi
    if ! state_matches_original \
      "$RETIRE_GRUBENV" true "$RETIRE_GRUBENV_ORIGINAL_IDENTITY"; then
      echo "Live grubenv changed during retirement." >&2
      return 1
    fi
  fi
}

secure_recovery_backup() {
  local backup="$1"

  if [ -d "$backup" ] && [ ! -L "$backup" ]; then
    chmod 0700 "$backup" 2>/dev/null || true
    if [ "$(file_mode "$backup" 2>/dev/null || true)" = "700" ]; then
      retirement_warn "preserved private recovery backup: $backup"
    else
      retirement_warn "recovery backup could not be secured to mode 0700: $backup"
    fi
  fi
}

capture_live_rollback_occupant() {
  local path="$1" backup="$2" description="$3" recovery

  RETIRE_CAPTURED_PATH=""
  RETIRE_CAPTURED_IDENTITY=""
  RETIRE_CAPTURED_PRESENT="false"
  if [ -z "$backup" ] || [ ! -d "$backup" ] || [ -L "$backup" ]; then
    if [ -e "$path" ] || [ -L "$path" ]; then
      retirement_warn "cannot privately capture $description rollback occupant: $path"
      return 1
    fi
    return 0
  fi

  recovery="$backup/rollback-current"
  if [ -e "$recovery" ] || [ -L "$recovery" ]; then
    retirement_warn "private $description rollback leaf is already occupied: $recovery"
    return 1
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if ! mv "$path" "$recovery"; then
    if [ ! -e "$recovery" ] && [ ! -L "$recovery" ]; then
      retirement_warn "could not capture $description rollback occupant: $path"
      return 1
    fi
  fi
  RETIRE_CAPTURED_PATH="$recovery"
  RETIRE_CAPTURED_PRESENT="true"
  RETIRE_CAPTURED_IDENTITY="$(
    regular_file_identity "$recovery" 2>/dev/null || true
  )"
}

recovery_source_matches() {
  local source="$1" match_kind="$2" expected="$3"

  [ -n "$source" ] && [ -n "$expected" ] || return 1
  case "$match_kind" in
    identity)
      [ "$(regular_file_identity "$source" 2>/dev/null || true)" = \
        "$expected" ]
      ;;
    fingerprint)
      [ "$(preserved_file_fingerprint "$source" 2>/dev/null || true)" = \
        "$expected" ]
      ;;
    *) return 1 ;;
  esac
}

publish_recovery_source() {
  local source="$1" destination="$2" match_kind="$3" expected="$4"
  local keep_source="$5" source_identity destination_identity
  local publish_source="$source" restore_stage="" parent

  recovery_source_matches "$source" "$match_kind" "$expected" || return 1
  if [ "$keep_source" = "true" ]; then
    [ "$match_kind" = "fingerprint" ] || return 1
    parent="$(dirname "$source")"
    restore_stage="$(
      mktemp "$parent/.sp11-loose-dtb-restore.XXXXXX"
    )" || return 1
    if ! cp -p -- "$source" "$restore_stage" ||
       ! recovery_source_matches "$restore_stage" "$match_kind" "$expected"; then
      return 1
    fi
    publish_source="$restore_stage"
  fi
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  source_identity="$(regular_file_identity "$publish_source" 2>/dev/null || true)"
  [ -n "$source_identity" ] || return 1
  if ! ln "$publish_source" "$destination"; then
    destination_identity="$(
      regular_file_identity "$destination" 2>/dev/null || true
    )"
    [ "$destination_identity" = "$source_identity" ] || return 1
  fi
  destination_identity="$(
    regular_file_identity "$destination" 2>/dev/null || true
  )"
  [ "$destination_identity" = "$source_identity" ] || return 1
  recovery_source_matches "$source" "$match_kind" "$expected" || return 1
  if [ "$keep_source" = "true" ]; then
    rm -f -- "$restore_stage" || return 1
  else
    rm -f -- "$source" || return 1
  fi
}

discard_private_recovery_source() {
  local source="$1" match_kind="$2" expected="$3"

  if [ -e "$source" ] || [ -L "$source" ]; then
    recovery_source_matches "$source" "$match_kind" "$expected" || return 1
    rm -f -- "$source" || return 1
  fi
}

restore_monitored_snapshot() {
  local path="$1" backup="$2" had_old="$3" identity="$4" fingerprint="$5"
  local description="$6" source match_kind expected keep_source unknown

  if [ "$had_old" != "true" ]; then
    if [ -e "$path" ] || [ -L "$path" ]; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "preserving changed $description rollback occupant: $path"
    fi
    return 0
  fi
  if [ -z "$backup" ] || [ -z "$identity" ] || [ -z "$fingerprint" ]; then
    if [ "$(regular_file_identity "$path" 2>/dev/null || true)" = "$identity" ] &&
       [ -n "$identity" ]; then
      return 0
    fi
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "$description was not fully snapshotted; leaving it untouched"
    return 0
  fi
  if ! recovery_source_matches \
    "$backup/original" fingerprint "$fingerprint"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "$description recovery snapshot is not trustworthy"
    secure_recovery_backup "$backup"
    return 0
  fi
  if ! capture_live_rollback_occupant "$path" "$backup" "$description"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    secure_recovery_backup "$backup"
    return 0
  fi

  source="$backup/original"
  match_kind="fingerprint"
  expected="$fingerprint"
  keep_source="false"
  unknown="false"
  if [ "$RETIRE_CAPTURED_PRESENT" = "true" ]; then
    if [ "$RETIRE_CAPTURED_IDENTITY" = "$identity" ]; then
      source="$RETIRE_CAPTURED_PATH"
      match_kind="identity"
      expected="$identity"
    else
      unknown="true"
      keep_source="true"
    fi
  fi
  if ! publish_recovery_source \
    "$source" "$path" "$match_kind" "$expected" "$keep_source"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not safely restore $description: $path"
    secure_recovery_backup "$backup"
    return 0
  fi

  if [ "$unknown" = "true" ]; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "preserved changed $description occupant: $RETIRE_CAPTURED_PATH"
    secure_recovery_backup "$backup"
    return 0
  fi
  if ! discard_private_recovery_source \
    "$backup/original" fingerprint "$fingerprint"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not discard redundant $description recovery snapshot"
  fi
}

restore_prior_grub_cfg() {
  local source match_kind expected keep_source unknown captured_generated

  [ "$LIVE_ROOT" = "true" ] || return 0
  if [ -z "$RETIRE_GRUB_CFG" ] ||
     [ -z "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY" ] ||
     [ -z "$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT" ]; then
    if [ "$RETIRE_STAGE_STARTED" = "true" ]; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "live grub.cfg was not fully identified; leaving it untouched"
    fi
    return 0
  fi
  if [ -z "$RETIRE_GRUB_CFG_BACKUP" ]; then
    if [ "$(regular_file_identity \
      "$RETIRE_GRUB_CFG" 2>/dev/null || true)" = \
      "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY" ]; then
      return 0
    fi
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "live grub.cfg changed before a recovery snapshot was available"
    return 0
  fi
  if ! recovery_source_matches \
    "$RETIRE_GRUB_CFG_BACKUP/original" fingerprint \
    "$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "prior grub.cfg recovery snapshot is not trustworthy"
    secure_recovery_backup "$RETIRE_GRUB_CFG_BACKUP"
    return 0
  fi
  if ! capture_live_rollback_occupant \
    "$RETIRE_GRUB_CFG" "$RETIRE_GRUB_CFG_BACKUP" "grub.cfg"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    secure_recovery_backup "$RETIRE_GRUB_CFG_BACKUP"
    return 0
  fi

  source=""
  match_kind=""
  expected=""
  keep_source="false"
  unknown="false"
  captured_generated="false"
  if [ "$RETIRE_CAPTURED_PRESENT" = "true" ] &&
     [ "$RETIRE_CAPTURED_IDENTITY" = \
       "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY" ]; then
    source="$RETIRE_CAPTURED_PATH"
    match_kind="identity"
    expected="$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"
  else
    if recovery_source_matches \
      "$RETIRE_GRUB_CFG_BACKUP/retired" identity \
      "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"; then
      source="$RETIRE_GRUB_CFG_BACKUP/retired"
      match_kind="identity"
      expected="$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"
    else
      source="$RETIRE_GRUB_CFG_BACKUP/original"
      match_kind="fingerprint"
      expected="$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT"
    fi
    if [ "$RETIRE_CAPTURED_PRESENT" = "true" ]; then
      if [ -n "$RETIRE_GRUB_CFG_GENERATED_IDENTITY" ] &&
         [ "$RETIRE_CAPTURED_IDENTITY" = \
           "$RETIRE_GRUB_CFG_GENERATED_IDENTITY" ]; then
        captured_generated="true"
      else
        unknown="true"
        keep_source="true"
        source="$RETIRE_GRUB_CFG_BACKUP/original"
        match_kind="fingerprint"
        expected="$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT"
      fi
    fi
  fi

  if ! publish_recovery_source \
    "$source" "$RETIRE_GRUB_CFG" "$match_kind" "$expected" "$keep_source"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not safely restore prior grub.cfg"
    secure_recovery_backup "$RETIRE_GRUB_CFG_BACKUP"
    return 0
  fi
  if [ "$unknown" = "true" ]; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "preserved changed grub.cfg occupant: $RETIRE_CAPTURED_PATH"
    secure_recovery_backup "$RETIRE_GRUB_CFG_BACKUP"
    return 0
  fi
  if [ "$captured_generated" = "true" ] &&
     ! discard_private_recovery_source \
       "$RETIRE_CAPTURED_PATH" identity \
       "$RETIRE_GRUB_CFG_GENERATED_IDENTITY"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not discard captured generated grub.cfg"
  fi
  if ! discard_private_recovery_source \
    "$RETIRE_GRUB_CFG_BACKUP/retired" identity \
    "$RETIRE_GRUB_CFG_ORIGINAL_IDENTITY"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not discard redundant exact prior grub.cfg"
  fi
  if ! discard_private_recovery_source \
    "$RETIRE_GRUB_CFG_BACKUP/original" fingerprint \
    "$RETIRE_GRUB_CFG_ORIGINAL_FINGERPRINT"; then
    RETIRE_ROLLBACK_INCOMPLETE="true"
    retirement_warn "could not discard redundant prior grub.cfg snapshot"
  fi
}

restore_managed_retirement() {
  local index destination backup had_old identity fingerprint
  local source match_kind expected keep_source unknown

  for ((index=${#RETIRE_DESTINATIONS[@]}-1; index>=0; index--)); do
    destination="${RETIRE_DESTINATIONS[index]:-}"
    backup="${RETIRE_BACKUP_DIRS[index]:-}"
    had_old="${RETIRE_HAD_OLD[index]:-false}"
    identity="${RETIRE_ORIGINAL_IDENTITIES[index]:-}"
    fingerprint="${RETIRE_ORIGINAL_FINGERPRINTS[index]:-}"
    [ -n "$destination" ] || continue

    if [ "$had_old" != "true" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        RETIRE_ROLLBACK_INCOMPLETE="true"
        retirement_warn "preserving changed managed-leaf rollback occupant: $destination"
      fi
      continue
    fi

    if [ -z "$backup" ] || [ -z "$identity" ] || [ -z "$fingerprint" ]; then
      if [ "$(regular_file_identity \
        "$destination" 2>/dev/null || true)" = "$identity" ] &&
         [ -n "$identity" ]; then
        continue
      fi
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "managed retirement leaf was not fully snapshotted: $destination"
      continue
    fi
    if ! recovery_source_matches "$backup/original" fingerprint "$fingerprint"; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "managed retirement recovery snapshot is not trustworthy: $destination"
      secure_recovery_backup "$backup"
      continue
    fi
    if ! capture_live_rollback_occupant \
      "$destination" "$backup" "managed-leaf"; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      secure_recovery_backup "$backup"
      continue
    fi

    source=""
    match_kind=""
    expected=""
    keep_source="false"
    unknown="false"
    if [ "$RETIRE_CAPTURED_PRESENT" = "true" ] &&
       [ "$RETIRE_CAPTURED_IDENTITY" = "$identity" ]; then
      source="$RETIRE_CAPTURED_PATH"
      match_kind="identity"
      expected="$identity"
    else
      if recovery_source_matches "$backup/retired" identity "$identity"; then
        source="$backup/retired"
        match_kind="identity"
        expected="$identity"
      else
        source="$backup/original"
        match_kind="fingerprint"
        expected="$fingerprint"
      fi
      if [ "$RETIRE_CAPTURED_PRESENT" = "true" ]; then
        unknown="true"
        keep_source="true"
        source="$backup/original"
        match_kind="fingerprint"
        expected="$fingerprint"
      fi
    fi
    if ! publish_recovery_source \
      "$source" "$destination" "$match_kind" "$expected" "$keep_source"; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "could not safely restore managed retirement leaf: $destination"
      secure_recovery_backup "$backup"
      continue
    fi
    if [ "$unknown" = "true" ]; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "preserved changed managed-leaf occupant: $RETIRE_CAPTURED_PATH"
      secure_recovery_backup "$backup"
      continue
    fi
    if ! discard_private_recovery_source \
      "$backup/retired" identity "$identity"; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "could not discard redundant exact managed retirement leaf"
    fi
    if ! discard_private_recovery_source \
      "$backup/original" fingerprint "$fingerprint"; then
      RETIRE_ROLLBACK_INCOMPLETE="true"
      retirement_warn "could not discard redundant managed retirement snapshot"
    fi
  done
}

remove_empty_retirement_backups() {
  local index backup

  for ((index=0; index<${#RETIRE_ALL_BACKUP_DIRS[@]}; index++)); do
    backup="${RETIRE_ALL_BACKUP_DIRS[index]:-}"
    [ -n "$backup" ] || continue
    if [ -d "$backup" ] && [ ! -L "$backup" ]; then
      if ! rmdir "$backup" 2>/dev/null; then
        RETIRE_ROLLBACK_INCOMPLETE="true"
        secure_recovery_backup "$backup"
      fi
    fi
  done
}

rollback_retirement_transaction() {
  restore_prior_grub_cfg
  if [ -n "$RETIRE_GRUBENV_BACKUP" ]; then
    restore_monitored_snapshot \
      "$RETIRE_GRUBENV" "$RETIRE_GRUBENV_BACKUP" true \
      "$RETIRE_GRUBENV_ORIGINAL_IDENTITY" \
      "$RETIRE_GRUBENV_ORIGINAL_FINGERPRINT" "grubenv"
  fi
  if [ -n "$RETIRE_LOOSE_DTB" ]; then
    restore_monitored_snapshot \
      "$RETIRE_LOOSE_DTB" "$RETIRE_LOOSE_DTB_BACKUP" \
      "$RETIRE_LOOSE_DTB_HAD_OLD" \
      "$RETIRE_LOOSE_DTB_ORIGINAL_IDENTITY" \
      "$RETIRE_LOOSE_DTB_ORIGINAL_FINGERPRINT" "historical loose-DTB"
  fi
  restore_managed_retirement
  remove_empty_retirement_backups
}

discard_retirement_backups() {
  local index backup

  for ((index=0; index<${#RETIRE_ALL_BACKUP_DIRS[@]}; index++)); do
    backup="${RETIRE_ALL_BACKUP_DIRS[index]:-}"
    [ -n "$backup" ] || continue
    if [ -d "$backup" ] && [ ! -L "$backup" ]; then
      if [ -f "$backup/original" ] && [ ! -L "$backup/original" ]; then
        rm -f -- "$backup/original" ||
          retirement_warn "could not discard committed retirement backup: $backup/original"
      fi
      if [ -f "$backup/retired" ] && [ ! -L "$backup/retired" ]; then
        rm -f -- "$backup/retired" ||
          retirement_warn "could not discard committed retirement backup: $backup/retired"
      fi
      if ! rmdir "$backup" 2>/dev/null; then
        secure_recovery_backup "$backup"
      fi
    fi
  done
}

retirement_cleanup() {
  local saved_status=$?

  trap - EXIT
  if [ "$RETIRE_TX_PREPARED" = "true" ] &&
     [ "$RETIRE_TX_COMMITTED" != "true" ]; then
    rollback_retirement_transaction
    echo "DO NOT REBOOT. DO NOT RUN apt OR dpkg until this retirement failure is reviewed." >&2
    if [ "$RETIRE_ROLLBACK_INCOMPLETE" = "true" ]; then
      echo "Rollback was obstructed; preserve reported occupants and use any reported mode-0700 recovery backup before continuing." >&2
    else
      echo "The prior managed leaves and GRUB state were restored." >&2
    fi
  fi
  return "$saved_status"
}

run_retirement_transaction() {
  if [ "$LIVE_ROOT" = "true" ] &&
     ! command -v update-grub >/dev/null 2>&1; then
    echo "update-grub is required to retire generated loose-DTB references." >&2
    return 1
  fi

  trap retirement_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  prepare_retirement_transaction
  verify_retirement_prestate
  stage_managed_retirement

  if [ "$LIVE_ROOT" = "true" ]; then
    if ! update-grub; then
      RETIRE_GRUB_CFG_GENERATED_IDENTITY="$(
        regular_file_identity "$RETIRE_GRUB_CFG" 2>/dev/null || true
      )"
      echo "update-grub failed; the loose-DTB retirement cannot be committed." >&2
      return 1
    fi
    RETIRE_GRUB_CFG_GENERATED_IDENTITY="$(
      regular_file_identity "$RETIRE_GRUB_CFG" 2>/dev/null || true
    )"
  else
    echo "GRUB regeneration deferred for offline target root; target grub.cfg was not modified."
  fi

  postcheck_retirement_transaction
  if [ "$RETIRE_LOOSE_DTB_HAD_OLD" = "true" ]; then
    echo "Existing /boot/sp11-denali.dtb was left untouched as inert recovery evidence."
  fi
  RETIRE_TX_COMMITTED="true"
  discard_retirement_backups
  RETIRE_TX_PREPARED="false"
  trap - EXIT HUP INT TERM
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
  local legacy_loose_dtb rel

  for rel in "${RETIRE_MANAGED_RELS[@]}"; do
    retire_managed_loose_dtb_artifact "$rel"
  done
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
if [ "$RETIRE_LOOSE_DTB_ONLY" = "true" ]; then
  if [ "$LIVE_ROOT" = "true" ]; then
    preflight_live_retirement_state
  fi
  run_retirement_transaction
  echo "Retired installed loose-DTB integration in $ROOT"
  exit 0
fi

preflight_full_install_destinations
retire_managed_loose_dtb_artifacts

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
