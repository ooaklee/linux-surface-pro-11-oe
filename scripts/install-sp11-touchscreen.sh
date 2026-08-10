#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SIGNED_MODULE_VALIDATOR="$REPO_DIR/scripts/validate-sp11-signed-modules.py"
MODULES_DIR=""
REQUESTED_RELEASE=""
TARGET_ROOT="/"
WINDOWS_SE_INIT="false"
WORK_DIR=""
WORK_PARENT=""
TARGET_ROOT_ID=""
PREDICTED_PATH=""
CREATED_DIRECTORIES=()
STAGED_FILES=()
TX_SOURCES=()
TX_DESTINATIONS=()
TX_BACKUP_DIRS=()
TX_HAD_OLD=()
TX_INSTALLED=()
TX_INSTALLED_IDENTITIES=()
TX_ACTIVE="false"
DIRECT_BACKUP_PRESERVED="false"
DEPMOD_BACKUP_DIR=""
DEPMOD_ORIGINAL_NAMES=()
DEPMOD_GENERATED_NAMES=()
DEPMOD_GENERATED_IDENTITIES=()
DEPMOD_MUTATED="false"
DEPMOD_RESTORE_ATTEMPTED="false"
DEPMOD_BACKUP_PRESERVED="false"
INITRD=""
INITRD_BACKUP_DIR=""
INITRD_HAD_OLD="false"
INITRD_MUTATED="false"
INITRD_GENERATED_IDENTITY=""
INITRD_RESTORE_ATTEMPTED="false"
INITRD_BACKUP_PRESERVED="false"
INSTALL_COMMITTED="false"

usage() {
  cat <<EOF
Usage: sudo $PROGRAM --modules-dir DIR [options]

Install the matched Surface Pro 11 touchscreen module set for one exact kernel
ABI and rebuild that ABI's initramfs.

Required:
  --modules-dir DIR    Directory containing the exact five-member controlled
                       signed touchscreen bundle.

Options:
  --release RELEASE   Expected kernel release. By default it is inferred from
                       the common module vermagic. A supplied value must match.
  --root DIR          Installed-system root (default /). Non-live roots must be
                       runnable with chroot so their own initramfs tool is used.
  --windows-se-init   Opt in to the experimental captured Windows cold-init
                       controller sequence. The validated default is off.
  -h, --help           Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

require_value() {
  if [ -z "${2:-}" ]; then
    echo "error: $1 requires a value" >&2
    usage >&2
    exit 2
  fi
}

path_has_control_characters() {
  case "$1" in
    *$'\n'*|*$'\r'*) return 0 ;;
  esac
  LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

validate_canonical_absolute_path() {
  local path="$1" description="$2" allow_root="${3:-false}"

  case "$path" in
    /*) ;;
    *) die "$description must be an absolute path: $path" ;;
  esac
  if [ "$path" = "/" ]; then
    [ "$allow_root" = "true" ] || die "$description must not be /"
    return 0
  fi
  case "$path" in
    */|*//*) die "$description must use canonical path spelling: $path" ;;
  esac
  case "/${path#/}/" in
    */./*|*/../*) die "$description must not contain dot or dot-dot components: $path" ;;
  esac
  if path_has_control_characters "$path"; then
    die "$description must not contain control characters"
  fi
  return 0
}

node_identity() {
  local identity

  if identity="$(stat -c '%d:%i' -- "$1" 2>/dev/null)"; then
    :
  elif identity="$(stat -f '%d:%i' "$1" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity"
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
  checksum="$(sha256sum "$path" | awk '{print $1}')" || return 1
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

root_path() {
  local absolute="$1"

  if [ "$TARGET_ROOT" = "/" ]; then
    printf '%s' "$absolute"
  else
    printf '%s%s' "$TARGET_ROOT" "$absolute"
  fi
}

verify_target_root_identity() {
  local current

  [ -d "$TARGET_ROOT" ] && [ ! -L "$TARGET_ROOT" ] ||
    die "target root changed type during installation: $TARGET_ROOT"
  current="$(node_identity "$TARGET_ROOT")" ||
    die "cannot re-identify target root: $TARGET_ROOT"
  [ "$current" = "$TARGET_ROOT_ID" ] ||
    die "target root identity changed during installation: $TARGET_ROOT"
}

predict_physical_directory() {
  local logical="$1"
  shift
  local cursor="$logical" suffix="" component physical candidate allowed

  validate_canonical_absolute_path "$logical" "managed target directory" true
  while [ ! -e "$cursor" ] && [ ! -L "$cursor" ]; do
    component="${cursor##*/}"
    suffix="/$component$suffix"
    cursor="${cursor%/*}"
    [ -n "$cursor" ] || cursor="/"
  done
  [ -d "$cursor" ] ||
    die "managed target ancestor is not a directory: $cursor"
  physical="$(cd "$cursor" && pwd -P)" ||
    die "cannot resolve managed target ancestor: $cursor"
  candidate="${physical%/}${suffix}"
  [ -n "$candidate" ] || candidate="/"

  case "$TARGET_ROOT" in
    /) ;;
    *)
      case "$candidate" in
        "$TARGET_ROOT"|"$TARGET_ROOT"/*) ;;
        *) die "managed target directory escapes target root: $logical -> $candidate" ;;
      esac
      ;;
  esac

  for allowed in "$@"; do
    if [ "$candidate" = "$allowed" ]; then
      PREDICTED_PATH="$candidate"
      return 0
    fi
  done
  die "managed target directory resolves outside its allowed physical path: $logical -> $candidate"
}

predict_target_directory() {
  local relative="$1" allow_usrmerge="${2:-false}"
  local logical alternate suffix

  validate_canonical_absolute_path "$relative" "target-relative directory" true
  logical="$(root_path "$relative")"
  if [ "$allow_usrmerge" = "true" ]; then
    case "$relative" in
      /lib) suffix="" ;;
      /lib/*) suffix="/${relative#/lib/}" ;;
      *) die "internal error: usr-merge allowance used outside /lib" ;;
    esac
    alternate="$(root_path "/usr/lib$suffix")"
    predict_physical_directory "$logical" "$logical" "$alternate"
  else
    predict_physical_directory "$logical" "$logical"
  fi
}

validate_physical_directory_chain() {
  local path="$1" remaining="${1#/}" current="" component

  validate_canonical_absolute_path "$path" "physical target directory" true
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    current="$current/$component"
    if [ -L "$current" ]; then
      die "physical target path must not contain symlinks: $current"
    elif [ -e "$current" ] && [ ! -d "$current" ]; then
      die "physical target path contains a non-directory: $current"
    fi
  done
}

ensure_physical_directory() {
  local path="$1" remaining="${1#/}" current="" component

  validate_physical_directory_chain "$path"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
      *) component="$remaining"; remaining="" ;;
    esac
    current="$current/$component"
    if [ ! -e "$current" ]; then
      mkdir "$current" || die "cannot create target directory: $current"
      CREATED_DIRECTORIES+=("$current")
      chmod 0755 "$current" || die "cannot set target directory mode: $current"
    fi
    [ -d "$current" ] && [ ! -L "$current" ] ||
      die "target directory changed during creation: $current"
  done
}

preflight_leaf() {
  local path="$1" description="$2"

  if [ -L "$path" ]; then
    die "$description must not be a symlink: $path"
  elif [ -e "$path" ] && [ ! -f "$path" ]; then
    die "$description must be absent or a regular file: $path"
  fi
}

require_regular_file() {
  local path="$1" description="$2" allow_empty="${3:-false}"

  [ -f "$path" ] && [ ! -L "$path" ] ||
    die "$description must be a regular, non-symlinked file: $path"
  if [ "$allow_empty" != "true" ]; then
    [ -s "$path" ] || die "$description must not be empty: $path"
  fi
}

target_regular_file_is_safe() {
  local path="$1" resolved

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  resolved="$(realpath -e -- "$path" 2>/dev/null)" || return 1
  case "$TARGET_ROOT" in
    /) ;;
    *)
      case "$resolved" in
        "$TARGET_ROOT"/*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  [ -f "$resolved" ] && [ ! -L "$resolved" ]
}

create_private_work_directory() {
  local raw parent

  raw="$(mktemp -d "${TMPDIR:-/tmp}/sp11-touchscreen-install.XXXXXX")" ||
    die "cannot create private installer work directory"
  [ -d "$raw" ] && [ ! -L "$raw" ] ||
    die "installer work path is not a real directory: $raw"
  WORK_DIR="$(cd "$raw" && pwd -P)" ||
    die "cannot resolve private installer work directory"
  parent="$(dirname "$WORK_DIR")"
  WORK_PARENT="$(cd "$parent" && pwd -P)" ||
    die "cannot resolve installer work parent"
  case "$WORK_DIR" in
    "$WORK_PARENT"/sp11-touchscreen-install.*) ;;
    *) die "private installer work directory has an unexpected path: $WORK_DIR" ;;
  esac
  chmod 0700 "$WORK_DIR" || die "cannot secure installer work directory"
  [ "$(file_mode "$WORK_DIR")" = "700" ] ||
    die "installer work directory is not private"
}

clear_direct_transaction_state() {
  TX_SOURCES=()
  TX_DESTINATIONS=()
  TX_BACKUP_DIRS=()
  TX_HAD_OLD=()
  TX_INSTALLED=()
  TX_INSTALLED_IDENTITIES=()
  TX_ACTIVE="false"
}

remove_direct_backups() {
  local mode="${1:-rollback}" backup index

  DIRECT_BACKUP_PRESERVED="false"

  for ((index=0; index<${#TX_BACKUP_DIRS[@]}; index++)); do
    backup="${TX_BACKUP_DIRS[index]}"
    case "$backup" in
      */.sp11-touchscreen-backup.*)
        if [ -d "$backup" ] && [ ! -L "$backup" ]; then
          if [ "$mode" = "commit" ]; then
            rm -rf -- "$backup" || warn "could not remove touchscreen backup: $backup"
          elif rmdir "$backup" 2>/dev/null; then
            :
          else
            DIRECT_BACKUP_PRESERVED="true"
            if [ -e "$backup/original" ] || [ -L "$backup/original" ]; then
              warn "preserved recoverable touchscreen original: $backup/original"
            else
              warn "preserved nonempty touchscreen rollback container: $backup"
            fi
          fi
        fi
        ;;
    esac
  done
}

rollback_direct_transaction() {
  local index destination backup current_identity

  for ((index=${#TX_INSTALLED[@]}-1; index>=0; index--)); do
    destination="${TX_INSTALLED[index]}"
    current_identity="$(regular_file_identity "$destination" 2>/dev/null || true)"
    if [ -n "$current_identity" ] &&
       [ "$current_identity" = "${TX_INSTALLED_IDENTITIES[index]}" ]; then
      rm -f -- "$destination" || true
    elif [ -e "$destination" ] || [ -L "$destination" ]; then
      warn "preserving changed touchscreen rollback occupant: $destination"
    fi
  done
  for ((index=${#TX_DESTINATIONS[@]}-1; index>=0; index--)); do
    if [ "${TX_HAD_OLD[index]:-false}" = "true" ]; then
      destination="${TX_DESTINATIONS[index]}"
      backup="${TX_BACKUP_DIRS[index]}/original"
      if [ -f "$backup" ] && [ ! -L "$backup" ] &&
         [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        mv "$backup" "$destination" ||
          warn "could not restore touchscreen destination: $destination"
      else
        warn "could not safely restore touchscreen destination: $destination"
      fi
    fi
  done
  TX_ACTIVE="false"
  remove_direct_backups rollback
  if [ "$DIRECT_BACKUP_PRESERVED" != "true" ]; then
    clear_direct_transaction_state
  fi
}

remove_staged_files() {
  local path index

  for ((index=0; index<${#STAGED_FILES[@]}; index++)); do
    path="${STAGED_FILES[index]}"
    case "$path" in
      */.sp11-touchscreen-stage.*)
        if [ -f "$path" ] || [ -L "$path" ]; then
          rm -f -- "$path" 2>/dev/null || true
        fi
        ;;
    esac
  done
  STAGED_FILES=()
}

remove_created_directories() {
  local index

  for ((index=${#CREATED_DIRECTORIES[@]}-1; index>=0; index--)); do
    rmdir "${CREATED_DIRECTORIES[index]}" 2>/dev/null || true
  done
  CREATED_DIRECTORIES=()
}

remove_system_backups() {
  local mode="${1:-rollback}"

  if [ -n "$DEPMOD_BACKUP_DIR" ]; then
    case "$DEPMOD_BACKUP_DIR" in
      */.sp11-touchscreen-depmod-backup.*)
        if [ -d "$DEPMOD_BACKUP_DIR" ] && [ ! -L "$DEPMOD_BACKUP_DIR" ]; then
          if [ "$DEPMOD_BACKUP_PRESERVED" = "true" ]; then
            warn "preserved recoverable depmod backup: $DEPMOD_BACKUP_DIR"
          elif [ "$mode" != "commit" ] &&
               [ "$DEPMOD_RESTORE_ATTEMPTED" = "true" ]; then
            if rmdir "$DEPMOD_BACKUP_DIR" 2>/dev/null; then
              DEPMOD_BACKUP_DIR=""
            else
              DEPMOD_BACKUP_PRESERVED="true"
              warn "preserved nonempty depmod rollback container: $DEPMOD_BACKUP_DIR"
            fi
          else
            rm -rf -- "$DEPMOD_BACKUP_DIR" ||
              warn "could not remove depmod backup: $DEPMOD_BACKUP_DIR"
            DEPMOD_BACKUP_DIR=""
          fi
        fi
        ;;
    esac
  fi
  if [ -n "$INITRD_BACKUP_DIR" ]; then
    case "$INITRD_BACKUP_DIR" in
      */.sp11-touchscreen-initrd-backup.*)
        if [ -d "$INITRD_BACKUP_DIR" ] && [ ! -L "$INITRD_BACKUP_DIR" ]; then
          if [ "$INITRD_BACKUP_PRESERVED" = "true" ]; then
            warn "preserved recoverable initramfs backup: $INITRD_BACKUP_DIR"
          elif [ "$mode" != "commit" ] &&
               [ "$INITRD_RESTORE_ATTEMPTED" = "true" ]; then
            if rmdir "$INITRD_BACKUP_DIR" 2>/dev/null; then
              INITRD_BACKUP_DIR=""
            else
              INITRD_BACKUP_PRESERVED="true"
              warn "preserved nonempty initramfs rollback container: $INITRD_BACKUP_DIR"
            fi
          else
            rm -rf -- "$INITRD_BACKUP_DIR" ||
              warn "could not remove initramfs backup: $INITRD_BACKUP_DIR"
            INITRD_BACKUP_DIR=""
          fi
        fi
        ;;
    esac
  fi
}

restore_depmod_metadata() {
  local current name backup temporary expected_identity current_identity
  local identity_index restore_blocked="false"

  [ "$DEPMOD_MUTATED" = "true" ] || return 0
  DEPMOD_RESTORE_ATTEMPTED="true"
  if [ -z "$DEPMOD_BACKUP_DIR" ] || [ ! -d "$DEPMOD_BACKUP_DIR" ] ||
     [ -L "$DEPMOD_BACKUP_DIR" ]; then
    warn "cannot safely restore depmod metadata: backup is unavailable"
    return 0
  fi

  while IFS= read -r -d '' current; do
    name="${current##*/}"
    if [ -f "$current" ] && [ ! -L "$current" ]; then
      expected_identity=""
      for ((identity_index=0; identity_index<${#DEPMOD_GENERATED_NAMES[@]}; identity_index++)); do
        if [ "${DEPMOD_GENERATED_NAMES[identity_index]}" = "$name" ]; then
          expected_identity="${DEPMOD_GENERATED_IDENTITIES[identity_index]}"
          break
        fi
      done
      current_identity="$(regular_file_identity "$current" 2>/dev/null || true)"
      if [ -z "$expected_identity" ] || [ "$current_identity" != "$expected_identity" ]; then
        warn "preserving changed depmod rollback occupant: $current"
        restore_blocked="true"
      elif ! rm -f -- "$current"; then
        warn "could not remove changed depmod metadata: $current"
        restore_blocked="true"
      fi
    elif [ -L "$current" ]; then
      warn "preserving changed depmod rollback symlink: $current"
      restore_blocked="true"
    else
      warn "refusing to remove unexpected depmod metadata node: $current"
      restore_blocked="true"
    fi
  done < <(find "$MODULE_TREE" -mindepth 1 -maxdepth 1 -name 'modules.*' -print0)

  for name in "${DEPMOD_ORIGINAL_NAMES[@]}"; do
    backup="$DEPMOD_BACKUP_DIR/$name"
    [ -f "$backup" ] && [ ! -L "$backup" ] || {
      warn "depmod metadata backup is invalid: $backup"
      restore_blocked="true"
      continue
    }
    temporary="$(mktemp "$MODULE_TREE/.sp11-touchscreen-restore.XXXXXX")" || {
      warn "could not reserve depmod restore stage in $MODULE_TREE"
      restore_blocked="true"
      continue
    }
    if cp -p -- "$backup" "$temporary" &&
       [ ! -e "$MODULE_TREE/$name" ] && [ ! -L "$MODULE_TREE/$name" ] &&
       mv "$temporary" "$MODULE_TREE/$name"; then
      rm -f -- "$backup" || restore_blocked="true"
    else
      warn "could not restore depmod metadata: $MODULE_TREE/$name"
      restore_blocked="true"
      rm -f -- "$temporary" 2>/dev/null || true
    fi
  done
  if [ "$restore_blocked" = "true" ] &&
     find "$DEPMOD_BACKUP_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    DEPMOD_BACKUP_PRESERVED="true"
    warn "depmod rollback is incomplete; recovery files remain in $DEPMOD_BACKUP_DIR"
  else
    DEPMOD_BACKUP_PRESERVED="false"
  fi
  DEPMOD_MUTATED="false"
}

restore_initrd() {
  local temporary current_identity restore_blocked="false"

  [ "$INITRD_MUTATED" = "true" ] || return 0
  INITRD_RESTORE_ATTEMPTED="true"
  if [ -f "$INITRD" ] && [ ! -L "$INITRD" ]; then
    current_identity="$(regular_file_identity "$INITRD" 2>/dev/null || true)"
    if [ -z "$INITRD_GENERATED_IDENTITY" ] ||
       [ "$current_identity" != "$INITRD_GENERATED_IDENTITY" ]; then
      warn "preserving changed initramfs rollback occupant: $INITRD"
      restore_blocked="true"
    elif ! rm -f -- "$INITRD"; then
      warn "could not remove changed initramfs: $INITRD"
      restore_blocked="true"
    fi
  elif [ -L "$INITRD" ]; then
    warn "preserving changed initramfs rollback symlink: $INITRD"
    restore_blocked="true"
  elif [ -e "$INITRD" ]; then
    warn "refusing to remove unexpected initramfs node: $INITRD"
    restore_blocked="true"
  fi

  if [ "$INITRD_HAD_OLD" = "true" ]; then
    if [ -n "$INITRD_BACKUP_DIR" ] &&
       [ -f "$INITRD_BACKUP_DIR/original" ] &&
       [ ! -L "$INITRD_BACKUP_DIR/original" ] &&
       [ ! -e "$INITRD" ] && [ ! -L "$INITRD" ]; then
      temporary="$(mktemp "$(dirname "$INITRD")/.sp11-touchscreen-restore.XXXXXX")" || {
        warn "could not reserve initramfs restore stage"
        INITRD_BACKUP_PRESERVED="true"
        INITRD_MUTATED="false"
        return 0
      }
      if cp -p -- "$INITRD_BACKUP_DIR/original" "$temporary" && mv "$temporary" "$INITRD"; then
        rm -f -- "$INITRD_BACKUP_DIR/original" || restore_blocked="true"
      else
        warn "could not restore prior initramfs: $INITRD"
        restore_blocked="true"
        rm -f -- "$temporary" 2>/dev/null || true
      fi
    else
      warn "cannot safely restore prior initramfs: $INITRD"
      restore_blocked="true"
    fi
  fi
  if [ "$restore_blocked" = "true" ] &&
     [ -n "$INITRD_BACKUP_DIR" ] &&
     { [ -e "$INITRD_BACKUP_DIR/original" ] || [ -L "$INITRD_BACKUP_DIR/original" ]; }; then
    INITRD_BACKUP_PRESERVED="true"
    warn "initramfs rollback is incomplete; recovery file remains at $INITRD_BACKUP_DIR/original"
  else
    INITRD_BACKUP_PRESERVED="false"
  fi
  INITRD_MUTATED="false"
}

cleanup() {
  local saved_status=$?

  if [ "$INSTALL_COMMITTED" != "true" ]; then
    if [ "$TX_ACTIVE" = "true" ]; then
      rollback_direct_transaction
    else
      remove_direct_backups rollback
      if [ "$DIRECT_BACKUP_PRESERVED" != "true" ]; then
        clear_direct_transaction_state
      fi
    fi
    restore_depmod_metadata
    restore_initrd
    remove_staged_files
    remove_system_backups rollback
    remove_created_directories
  else
    remove_direct_backups commit
    remove_staged_files
    remove_system_backups commit
  fi

  if [ -n "$WORK_DIR" ] && [ -n "$WORK_PARENT" ]; then
    case "$WORK_DIR" in
      "$WORK_PARENT"/sp11-touchscreen-install.*)
        if [ -d "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ]; then
          rm -rf -- "$WORK_DIR"
        fi
        ;;
    esac
  fi
  return "$saved_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stage_install_file() {
  local source="$1" destination_dir="$2" mode="$3" temporary

  require_regular_file "$source" "install source"
  [ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] &&
    [ "$(cd "$destination_dir" && pwd -P)" = "$destination_dir" ] ||
    die "install destination parent is not a physical directory: $destination_dir"
  temporary="$(mktemp "$destination_dir/.sp11-touchscreen-stage.XXXXXX")" ||
    die "cannot reserve private install stage in $destination_dir"
  STAGED_FILES+=("$temporary")
  install -m "$mode" "$source" "$temporary" ||
    die "cannot populate private install stage from $source"
  require_regular_file "$temporary" "staged touchscreen install file"
  [ "$(file_mode "$temporary")" = "${mode#0}" ] ||
    die "staged touchscreen install file has the wrong mode: $temporary"
  STAGED_FILE="$temporary"
}

collect_and_preflight_depmod_metadata() {
  local path name
  local expected_names=(
    modules.alias
    modules.alias.bin
    modules.builtin.alias.bin
    modules.builtin.bin
    modules.builtin.modinfo
    modules.dep
    modules.dep.bin
    modules.devname
    modules.softdep
    modules.symbols
    modules.symbols.bin
    modules.weakdep
  )

  DEPMOD_ORIGINAL_NAMES=()
  for name in "${expected_names[@]}"; do
    preflight_leaf "$MODULE_TREE/$name" "depmod metadata destination"
  done
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    case "$name" in
      modules.*) ;;
      *) die "internal error: unexpected depmod metadata name: $name" ;;
    esac
    path_has_control_characters "$name" &&
      die "depmod metadata name contains control characters"
    preflight_leaf "$path" "depmod metadata destination"
    DEPMOD_ORIGINAL_NAMES+=("$name")
  done < <(find "$MODULE_TREE" -mindepth 1 -maxdepth 1 -name 'modules.*' -print0)
}

capture_depmod_generated_identities() {
  local path name identity

  DEPMOD_GENERATED_NAMES=()
  DEPMOD_GENERATED_IDENTITIES=()
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    path_has_control_characters "$name" &&
      die "generated depmod metadata name contains control characters"
    if identity="$(regular_file_identity "$path" 2>/dev/null)"; then
      DEPMOD_GENERATED_NAMES+=("$name")
      DEPMOD_GENERATED_IDENTITIES+=("$identity")
    fi
  done < <(find "$MODULE_TREE" -mindepth 1 -maxdepth 1 -name 'modules.*' -print0)
}

prepare_system_backups() {
  local name source

  verify_target_root_identity
  collect_and_preflight_depmod_metadata
  preflight_leaf "$INITRD" "target initramfs"

  DEPMOD_BACKUP_DIR="$(mktemp -d "$MODULE_TREE/.sp11-touchscreen-depmod-backup.XXXXXX")" ||
    die "cannot reserve private depmod backup in $MODULE_TREE"
  chmod 0700 "$DEPMOD_BACKUP_DIR" || die "cannot secure depmod backup"
  for name in "${DEPMOD_ORIGINAL_NAMES[@]}"; do
    source="$MODULE_TREE/$name"
    require_regular_file "$source" "depmod metadata" true
    cp -p -- "$source" "$DEPMOD_BACKUP_DIR/$name" ||
      die "cannot snapshot depmod metadata: $source"
    require_regular_file "$DEPMOD_BACKUP_DIR/$name" "depmod metadata backup" true
    cmp -s "$source" "$DEPMOD_BACKUP_DIR/$name" ||
      die "depmod metadata changed while it was being snapshotted: $source"
  done

  INITRD_BACKUP_DIR="$(mktemp -d "$(dirname "$INITRD")/.sp11-touchscreen-initrd-backup.XXXXXX")" ||
    die "cannot reserve private initramfs backup"
  chmod 0700 "$INITRD_BACKUP_DIR" || die "cannot secure initramfs backup"
  if [ -f "$INITRD" ]; then
    cp -p -- "$INITRD" "$INITRD_BACKUP_DIR/original" ||
      die "cannot snapshot existing initramfs: $INITRD"
    require_regular_file "$INITRD_BACKUP_DIR/original" "initramfs backup"
    cmp -s "$INITRD" "$INITRD_BACKUP_DIR/original" ||
      die "initramfs changed while it was being snapshotted: $INITRD"
    INITRD_HAD_OLD="true"
  else
    INITRD_HAD_OLD="false"
  fi
}

publish_direct_transaction() {
  local source destination parent backup index source_identity published_identity

  [ $(( $# % 2 )) -eq 0 ] || die "internal error: unpaired install paths"
  clear_direct_transaction_state
  while [ "$#" -gt 0 ]; do
    source="$1"
    destination="$2"
    shift 2
    require_regular_file "$source" "staged touchscreen install file"
    preflight_leaf "$destination" "touchscreen install destination"
    parent="$(dirname "$destination")"
    [ -d "$parent" ] && [ ! -L "$parent" ] &&
      [ "$(cd "$parent" && pwd -P)" = "$parent" ] ||
      die "touchscreen destination parent is unsafe: $parent"
    backup="$(mktemp -d "$parent/.sp11-touchscreen-backup.XXXXXX")" ||
      die "cannot reserve touchscreen destination backup in $parent"
    TX_SOURCES+=("$source")
    TX_DESTINATIONS+=("$destination")
    TX_BACKUP_DIRS+=("$backup")
    TX_HAD_OLD+=("false")
    chmod 0700 "$backup" || die "cannot secure touchscreen destination backup"
  done

  verify_target_root_identity
  for ((index=0; index<${#TX_DESTINATIONS[@]}; index++)); do
    preflight_leaf "${TX_DESTINATIONS[index]}" "touchscreen install destination"
  done

  TX_ACTIVE="true"
  for ((index=0; index<${#TX_DESTINATIONS[@]}; index++)); do
    destination="${TX_DESTINATIONS[index]}"
    backup="${TX_BACKUP_DIRS[index]}"
    if [ -f "$destination" ]; then
      if ! mv "$destination" "$backup/original"; then
        rollback_direct_transaction
        die "cannot stage existing touchscreen destination for replacement: $destination"
      fi
      TX_HAD_OLD[index]="true"
    fi
  done

  for ((index=0; index<${#TX_SOURCES[@]}; index++)); do
    source="${TX_SOURCES[index]}"
    destination="${TX_DESTINATIONS[index]}"
    require_regular_file "$source" "staged touchscreen install file"
    if [ -e "$destination" ] || [ -L "$destination" ] ||
       ! ln "$source" "$destination"; then
      rollback_direct_transaction
      die "cannot publish touchscreen destination atomically: $destination"
    fi
    source_identity="$(regular_file_identity "$source" 2>/dev/null || true)"
    published_identity="$(regular_file_identity "$destination" 2>/dev/null || true)"
    if [ -z "$source_identity" ] || [ "$published_identity" != "$source_identity" ] ||
       [ "$(node_identity "$source" 2>/dev/null || true)" != \
         "$(node_identity "$destination" 2>/dev/null || true)" ]; then
      rollback_direct_transaction
      die "touchscreen destination changed before publication identity was recorded: $destination"
    fi
    TX_INSTALLED+=("$destination")
    TX_INSTALLED_IDENTITIES+=("$published_identity")
    if ! rm -f -- "$source"; then
      rollback_direct_transaction
      die "cannot retire touchscreen install stage: $source"
    fi
  done
}

commit_install_transaction() {
  INSTALL_COMMITTED="true"
  DEPMOD_MUTATED="false"
  INITRD_MUTATED="false"
  TX_ACTIVE="false"
  remove_direct_backups commit
  clear_direct_transaction_state
  remove_staged_files
  remove_system_backups commit
  CREATED_DIRECTORIES=()
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --modules-dir)
      require_value "$1" "${2:-}"
      MODULES_DIR="$2"
      shift 2
      ;;
    --modules-dir=*)
      MODULES_DIR="${1#*=}"
      [ -n "$MODULES_DIR" ] || die "--modules-dir cannot be empty"
      shift
      ;;
    --release)
      require_value "$1" "${2:-}"
      REQUESTED_RELEASE="$2"
      shift 2
      ;;
    --release=*)
      REQUESTED_RELEASE="${1#*=}"
      [ -n "$REQUESTED_RELEASE" ] || die "--release cannot be empty"
      shift
      ;;
    --root)
      require_value "$1" "${2:-}"
      TARGET_ROOT="$2"
      shift 2
      ;;
    --root=*)
      TARGET_ROOT="${1#*=}"
      [ -n "$TARGET_ROOT" ] || die "--root cannot be empty"
      shift
      ;;
    --windows-se-init)
      WINDOWS_SE_INIT="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$MODULES_DIR" ] || {
  usage >&2
  exit 2
}

for tool in \
  modinfo depmod install realpath sha256sum cmp mktemp grep awk find od tr \
  stat cp mv ln rm mkdir rmdir dirname basename chmod; do
  command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
done
[ -x /usr/bin/python3 ] || die "trusted /usr/bin/python3 is required"
[ -f "$SIGNED_MODULE_VALIDATOR" ] && [ ! -L "$SIGNED_MODULE_VALIDATOR" ] ||
  die "controlled module signature validator is unavailable"

if [ "$(id -u)" -ne 0 ]; then
  die "installation mutates the target system and must be run as root"
fi

validate_canonical_absolute_path "$TARGET_ROOT" "target root" true
[ ! -L "$TARGET_ROOT" ] || die "target root must not be a symlink: $TARGET_ROOT"
resolved_target_root="$(realpath -e -- "$TARGET_ROOT")" || die "cannot resolve --root"
[ "$resolved_target_root" = "$TARGET_ROOT" ] ||
  die "target root must be supplied as its canonical physical path: $TARGET_ROOT -> $resolved_target_root"
[ -d "$TARGET_ROOT" ] || die "not a directory: $TARGET_ROOT"
[ "$(cd "$TARGET_ROOT" && pwd -P)" = "$TARGET_ROOT" ] ||
  die "target root is not a canonical physical directory: $TARGET_ROOT"
TARGET_ROOT_ID="$(node_identity "$TARGET_ROOT")" || die "cannot identify target root"

[ ! -L "$MODULES_DIR" ] ||
  die "module input directory must not be a symlink: $MODULES_DIR"
resolved_modules_dir="$(realpath -e -- "$MODULES_DIR")" || die "cannot resolve --modules-dir"
[ -d "$resolved_modules_dir" ] && [ ! -L "$resolved_modules_dir" ] ||
  die "module input must be a real, non-symlinked directory: $resolved_modules_dir"
[ "$(cd "$resolved_modules_dir" && pwd -P)" = "$resolved_modules_dir" ] ||
  die "module input must be a canonical physical directory: $resolved_modules_dir"
MODULES_DIR="$resolved_modules_dir"
MODULES_DIR_ID="$(node_identity "$MODULES_DIR")" || die "cannot identify module input directory"

create_private_work_directory

module_files=(gpi.ko spi-geni-qcom.ko mshw0485_touch.ko)
module_names=(gpi spi_geni_qcom mshw0485_touch)
module_relpaths=(
  updates/drivers/dma/qcom/gpi.ko
  updates/drivers/spi/spi-geni-qcom.ko
  updates/drivers/input/touchscreen/mshw0485_touch.ko
)
module_sources=()
COMMON_RELEASE=""
module_snapshot="$WORK_DIR/module-snapshot"
mkdir "$module_snapshot" || die "cannot create private module snapshot"
chmod 0700 "$module_snapshot" || die "cannot secure private module snapshot"

bundle_files=(
  gpi.ko
  spi-geni-qcom.ko
  mshw0485_touch.ko
  sp11-module-signing-cert.x509
  sp11-touchscreen-modules-manifest.txt
)
bundle_entry_count=0
while IFS= read -r -d '' bundle_entry; do
  bundle_leaf="$(basename "$bundle_entry")"
  case "$bundle_leaf" in
    gpi.ko|spi-geni-qcom.ko|mshw0485_touch.ko|sp11-module-signing-cert.x509|sp11-touchscreen-modules-manifest.txt) ;;
    *) die "module input directory contains an unexpected bundle member: $bundle_leaf" ;;
  esac
  bundle_entry_count=$((bundle_entry_count + 1))
done < <(find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -print0)
[ "$bundle_entry_count" -eq 5 ] ||
  die "module input directory must contain exactly five controlled bundle members"

for bundle_leaf in "${bundle_files[@]}"; do
  source_path="$MODULES_DIR/$bundle_leaf"
  require_regular_file "$source_path" "controlled bundle input"
  [ -r "$source_path" ] || die "controlled bundle input is not readable: $source_path"
  snapshot_path="$module_snapshot/$bundle_leaf"
  install -m 0400 "$source_path" "$snapshot_path" ||
    die "cannot snapshot controlled bundle input: $source_path"
  require_regular_file "$source_path" "controlled bundle input"
  require_regular_file "$snapshot_path" "private controlled bundle snapshot"
  cmp -s "$source_path" "$snapshot_path" ||
    die "controlled bundle input changed while it was being snapshotted: $source_path"
done

[ "$(node_identity "$MODULES_DIR")" = "$MODULES_DIR_ID" ] ||
  die "module input directory identity changed while it was being snapshotted"
/usr/bin/python3 -I "$SIGNED_MODULE_VALIDATOR" \
  --certificate "$module_snapshot/sp11-module-signing-cert.x509" \
  --module "$module_snapshot/gpi.ko" \
  --module "$module_snapshot/spi-geni-qcom.ko" \
  --module "$module_snapshot/mshw0485_touch.ko" \
  --manifest "$module_snapshot/sp11-touchscreen-modules-manifest.txt" >/dev/null ||
  die "controlled touchscreen module signature validation failed"

for index in "${!module_files[@]}"; do
  snapshot_path="$module_snapshot/${module_files[index]}"

  actual_name="$(modinfo -F name "$snapshot_path" 2>/dev/null || true)"
  [ "$actual_name" = "${module_names[index]}" ] ||
    die "${module_files[index]} has module name '${actual_name:-unknown}', expected '${module_names[index]}'"

  vermagic="$(modinfo -F vermagic "$snapshot_path" 2>/dev/null || true)"
  module_release="${vermagic%%[[:space:]]*}"
  [ -n "$module_release" ] || die "cannot read vermagic from $snapshot_path"

  if [ -z "$COMMON_RELEASE" ]; then
    COMMON_RELEASE="$module_release"
  elif [ "$module_release" != "$COMMON_RELEASE" ]; then
    die "module vermagic releases differ: $COMMON_RELEASE and $module_release"
  fi
  module_sources+=("$snapshot_path")
done

case "$COMMON_RELEASE" in
  ""|*[!A-Za-z0-9._+~-]*|[!A-Za-z0-9]*)
    die "unsafe kernel release inferred from vermagic: '$COMMON_RELEASE'"
    ;;
esac

if [ -n "$REQUESTED_RELEASE" ] && [ "$REQUESTED_RELEASE" != "$COMMON_RELEASE" ]; then
  die "--release '$REQUESTED_RELEASE' does not match module vermagic '$COMMON_RELEASE'"
fi
RELEASE="$COMMON_RELEASE"

case "$RELEASE" in
  *sp11v3*-qcom-x1e) ;;
  *) die "$RELEASE is not an sp11v3 touchscreen kernel ABI" ;;
esac

if ! modinfo -p "${module_sources[1]}" 2>/dev/null |
  grep -q '^sp11_windows_se_init:'; then
  die "spi-geni-qcom.ko lacks sp11_windows_se_init; this is not the required SP11 override"
fi
if ! modinfo -F alias "${module_sources[2]}" 2>/dev/null |
  grep -q 'microsoft,mshw0485'; then
  die "mshw0485_touch.ko lacks the microsoft,mshw0485 device-tree alias"
fi
for index in "${!module_files[@]}"; do
  srcversion="$(modinfo -F srcversion "${module_sources[index]}" 2>/dev/null || true)"
  [ -n "$srcversion" ] || die "${module_files[index]} has no source-version identity"
done

verify_target_root_identity
predict_target_directory "/lib/modules/$RELEASE" true
MODULE_TREE="$PREDICTED_PATH"
[ -d "$MODULE_TREE" ] && [ ! -L "$MODULE_TREE" ] &&
  [ "$(cd "$MODULE_TREE" && pwd -P)" = "$MODULE_TREE" ] ||
  die "target kernel module tree is not a physical directory: $MODULE_TREE"

predict_target_directory /etc false
ETC_DIR="$PREDICTED_PATH"
[ -d "$ETC_DIR" ] && [ ! -L "$ETC_DIR" ] ||
  die "target root lacks a physical /etc: $TARGET_ROOT"
predict_target_directory /boot false
BOOT_DIR="$PREDICTED_PATH"
[ -d "$BOOT_DIR" ] && [ ! -L "$BOOT_DIR" ] ||
  die "target root lacks a physical /boot: $TARGET_ROOT"

config=""
for candidate in \
  "$BOOT_DIR/config-$RELEASE" \
  "$MODULE_TREE/build/.config"; do
  if [ -r "$candidate" ] && target_regular_file_is_safe "$candidate"; then
    config="$(realpath -e -- "$candidate")"
    break
  fi
done
[ -n "$config" ] || die "cannot find the exact target kernel configuration for $RELEASE"
grep -qx 'CONFIG_MODULES=y' "$config" || die "CONFIG_MODULES is not enabled for $RELEASE"
grep -qx 'CONFIG_QCOM_GPI_DMA=m' "$config" || die "CONFIG_QCOM_GPI_DMA must be a replaceable module"
grep -qx 'CONFIG_SPI_QCOM_GENI=m' "$config" || die "CONFIG_SPI_QCOM_GENI must be a replaceable module"
grep -qx 'CONFIG_MODULE_SIG=y' "$config" || die "CONFIG_MODULE_SIG is not enabled for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_SHA512=y' "$config" || die "CONFIG_MODULE_SIG_SHA512 is not enabled for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_HASH="sha512"' "$config" || die "CONFIG_MODULE_SIG_HASH is not sha512 for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_KEY_TYPE_RSA=y' "$config" || die "CONFIG_MODULE_SIG_KEY_TYPE_RSA is not enabled for $RELEASE"

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "touchscreen installation must run on an ARM64 system" ;;
esac

compatible_path="$(root_path /proc/device-tree/compatible)"
compatible="$(tr '\0' ' ' < "$compatible_path" 2>/dev/null || true)"
case " $compatible " in
  *" microsoft,denali-oled "*) ;;
  *) die "running hardware is not the supported Surface Pro 11 OLED (microsoft,denali-oled)" ;;
esac

secure_boot_enabled="false"
if command -v mokutil >/dev/null 2>&1 &&
  mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
  secure_boot_enabled="true"
else
  efi_variables_dir="$(root_path /sys/firmware/efi/efivars)"
  for variable in "$efi_variables_dir"/SecureBoot-*; do
    [ -r "$variable" ] || continue
    byte="$(od -An -t u1 -j 4 -N 1 "$variable" 2>/dev/null | tr -d ' ')"
    [ "$byte" = 1 ] && secure_boot_enabled="true"
  done
fi
[ "$secure_boot_enabled" != "true" ] ||
  die "Secure Boot is enabled; this workflow is validated only with Secure Boot disabled"

touch_dtb=""
for candidate in \
  "$(root_path "/lib/firmware/$RELEASE/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb")" \
  "$(root_path "/usr/lib/linux-image-$RELEASE/qcom/x1e80100-microsoft-denali-oled.dtb")" \
  "$(root_path "/boot/dtbs/$RELEASE/qcom/x1e80100-microsoft-denali-oled.dtb")"; do
  if target_regular_file_is_safe "$candidate" &&
     grep -a -q 'microsoft,mshw0485' "$candidate"; then
    touch_dtb="$(realpath -e -- "$candidate")"
    break
  fi
done
[ -n "$touch_dtb" ] || die "the target ABI has no Denali OLED DTB with microsoft,mshw0485"

firmware_found="false"
for candidate in \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.zst \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf.xz \
  /lib/firmware/qcom/x1e80100/qupv3fw.elf; do
  target_regular_file_is_safe "$(root_path "$candidate")" && firmware_found="true"
done
[ "$firmware_found" = "true" ] || die "target root lacks qcom/x1e80100/qupv3fw.elf firmware"

REFRESH_TOOL=""
REFRESH_COMMAND=""
if [ "$TARGET_ROOT" = "/" ]; then
  if command -v update-initramfs >/dev/null 2>&1; then
    REFRESH_TOOL="update-initramfs"
    REFRESH_COMMAND="$(command -v update-initramfs)"
  elif command -v dracut >/dev/null 2>&1; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="$(command -v dracut)"
  else
    die "neither update-initramfs nor dracut is installed"
  fi
else
  command -v chroot >/dev/null 2>&1 || die "--root requires chroot"
  [ -x "$(root_path /bin/sh)" ] || die "target root has no executable /bin/sh"
  if ! chroot "$TARGET_ROOT" /bin/sh -c ':' >/dev/null 2>&1; then
    die "target root is not runnable with chroot; refusing a partial offline install"
  fi
  if [ -x "$(root_path /usr/sbin/update-initramfs)" ]; then
    REFRESH_TOOL="update-initramfs"
    REFRESH_COMMAND="/usr/sbin/update-initramfs"
  elif [ -x "$(root_path /usr/bin/dracut)" ]; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="/usr/bin/dracut"
  elif [ -x "$(root_path /usr/sbin/dracut)" ]; then
    REFRESH_TOOL="dracut"
    REFRESH_COMMAND="/usr/sbin/dracut"
  else
    die "target root contains neither update-initramfs nor dracut"
  fi
fi

if command -v lsinitramfs >/dev/null 2>&1; then
  INITRD_INSPECTOR="lsinitramfs"
elif command -v lsinitrd >/dev/null 2>&1; then
  INITRD_INSPECTOR="lsinitrd"
else
  die "post-install verification requires lsinitramfs or lsinitrd"
fi
if command -v unmkinitramfs >/dev/null 2>&1; then
  INITRD_EXTRACTOR="unmkinitramfs"
elif command -v lsinitrd >/dev/null 2>&1; then
  INITRD_EXTRACTOR="lsinitrd"
else
  die "exact initramfs module verification requires unmkinitramfs or lsinitrd"
fi

if [ "$WINDOWS_SE_INIT" = "true" ]; then
  warn "--windows-se-init enables an experimental captured Windows cold-init path"
  warn "sp11_windows_se_init changes only the spi_geni_qcom controller initialization path"
  warn "mshw0485_touch separately defaults to the Phase 75 client behavior profile"
  SE_INIT_VALUE=1
  PROFILE="windows-cold-init-opt-in"
else
  SE_INIT_VALUE=0
  PROFILE="linux-integrated"
fi

work_dir="$WORK_DIR"

cat > "$work_dir/sp11-touchscreen.modprobe" <<EOF
# Generated by $PROGRAM for $RELEASE.
# Keep the validated Linux-integrated controller path unless explicitly testing
# the captured Windows cold-init fallback.
softdep spi_geni_qcom pre: gpi
softdep mshw0485_touch pre: spi_geni_qcom
options spi_geni_qcom sp11_windows_se_init=$SE_INIT_VALUE
EOF

cat > "$work_dir/sp11-touchscreen.modules-load" <<'EOF'
# Surface Pro 11 touchscreen transport order.
gpi
spi_geni_qcom
mshw0485_touch
EOF

cat > "$work_dir/sp11-touchscreen.initramfs-hook" <<'EOF'
#!/bin/sh
set -eu

PREREQ=""
prereqs() { printf '%s\n' "$PREREQ"; }

case "${1:-}" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

release="${version:-}"
[ -n "$release" ] || {
  echo "sp11-touchscreen hook: initramfs kernel version is unavailable" >&2
  exit 1
}

marker="/etc/sp11-touchscreen/releases/$release"
[ -f "$marker" ] || exit 0

for relative in \
  updates/drivers/dma/qcom/gpi.ko \
  updates/drivers/spi/spi-geni-qcom.ko \
  updates/drivers/input/touchscreen/mshw0485_touch.ko; do
  source_path="/lib/modules/$release/$relative"
  if [ ! -f "$source_path" ]; then
    echo "sp11-touchscreen hook: required override missing: $source_path" >&2
    exit 1
  fi
  copy_file module "$source_path" "$source_path" || {
    result=$?
    [ "$result" -eq 1 ] || exit "$result"
  }
done

manual_add_modules gpi spi_geni_qcom mshw0485_touch
EOF

cat > "$work_dir/sp11-touchscreen.dracut" <<'EOF'
# Surface Pro 11 QSPI touchscreen transport and client. depmod selects the
# exact updates/ overrides installed for the initramfs kernel release.
force_drivers+=" gpi spi_geni_qcom mshw0485_touch "
EOF

{
  printf 'release=%s\n' "$RELEASE"
  printf 'profile=%s\n' "$PROFILE"
  for index in "${!module_files[@]}"; do
    checksum="$(sha256sum "${module_sources[index]}" | awk '{print $1}')"
    printf '%s_sha256=%s\n' "${module_names[index]}" "$checksum"
  done
} > "$work_dir/release-marker"

predict_physical_directory \
  "$MODULE_TREE/updates/drivers/dma/qcom" \
  "$MODULE_TREE/updates/drivers/dma/qcom"
GPI_DESTINATION_DIR="$PREDICTED_PATH"
predict_physical_directory \
  "$MODULE_TREE/updates/drivers/spi" \
  "$MODULE_TREE/updates/drivers/spi"
SPI_DESTINATION_DIR="$PREDICTED_PATH"
predict_physical_directory \
  "$MODULE_TREE/updates/drivers/input/touchscreen" \
  "$MODULE_TREE/updates/drivers/input/touchscreen"
TOUCH_DESTINATION_DIR="$PREDICTED_PATH"
predict_target_directory /etc/modprobe.d false
MODPROBE_DESTINATION_DIR="$PREDICTED_PATH"
predict_target_directory /etc/modules-load.d false
MODULES_LOAD_DESTINATION_DIR="$PREDICTED_PATH"
predict_target_directory /etc/initramfs-tools/hooks false
INITRAMFS_HOOK_DESTINATION_DIR="$PREDICTED_PATH"
predict_target_directory /etc/dracut.conf.d false
DRACUT_DESTINATION_DIR="$PREDICTED_PATH"
predict_target_directory /etc/sp11-touchscreen/releases false
RELEASE_MARKER_DESTINATION_DIR="$PREDICTED_PATH"

GPI_DESTINATION="$GPI_DESTINATION_DIR/gpi.ko"
SPI_DESTINATION="$SPI_DESTINATION_DIR/spi-geni-qcom.ko"
TOUCH_DESTINATION="$TOUCH_DESTINATION_DIR/mshw0485_touch.ko"
MODPROBE_DESTINATION="$MODPROBE_DESTINATION_DIR/sp11-touchscreen.conf"
MODULES_LOAD_DESTINATION="$MODULES_LOAD_DESTINATION_DIR/sp11-touchscreen.conf"
INITRAMFS_HOOK_DESTINATION="$INITRAMFS_HOOK_DESTINATION_DIR/sp11-touchscreen"
DRACUT_DESTINATION="$DRACUT_DESTINATION_DIR/91-sp11-touchscreen.conf"
RELEASE_MARKER_DESTINATION="$RELEASE_MARKER_DESTINATION_DIR/$RELEASE"
INITRD="$BOOT_DIR/initrd.img-$RELEASE"

# Resolve and inspect the complete destination set before creating the first
# directory or private stage. This makes a late FIFO, directory, or symlink
# collision fail without retiring any earlier managed peer.
for destination_dir in \
  "$GPI_DESTINATION_DIR" \
  "$SPI_DESTINATION_DIR" \
  "$TOUCH_DESTINATION_DIR" \
  "$MODPROBE_DESTINATION_DIR" \
  "$MODULES_LOAD_DESTINATION_DIR" \
  "$INITRAMFS_HOOK_DESTINATION_DIR" \
  "$DRACUT_DESTINATION_DIR" \
  "$RELEASE_MARKER_DESTINATION_DIR"; do
  validate_physical_directory_chain "$destination_dir"
done
for destination in \
  "$GPI_DESTINATION" \
  "$SPI_DESTINATION" \
  "$TOUCH_DESTINATION" \
  "$MODPROBE_DESTINATION" \
  "$MODULES_LOAD_DESTINATION" \
  "$INITRAMFS_HOOK_DESTINATION" \
  "$DRACUT_DESTINATION" \
  "$RELEASE_MARKER_DESTINATION"; do
  preflight_leaf "$destination" "touchscreen install destination"
done
collect_and_preflight_depmod_metadata
preflight_leaf "$INITRD" "target initramfs"

for destination_dir in \
  "$GPI_DESTINATION_DIR" \
  "$SPI_DESTINATION_DIR" \
  "$TOUCH_DESTINATION_DIR" \
  "$MODPROBE_DESTINATION_DIR" \
  "$MODULES_LOAD_DESTINATION_DIR" \
  "$INITRAMFS_HOOK_DESTINATION_DIR" \
  "$DRACUT_DESTINATION_DIR" \
  "$RELEASE_MARKER_DESTINATION_DIR"; do
  ensure_physical_directory "$destination_dir"
done

stage_install_file "${module_sources[0]}" "$GPI_DESTINATION_DIR" 0644
GPI_STAGE="$STAGED_FILE"
stage_install_file "${module_sources[1]}" "$SPI_DESTINATION_DIR" 0644
SPI_STAGE="$STAGED_FILE"
stage_install_file "${module_sources[2]}" "$TOUCH_DESTINATION_DIR" 0644
TOUCH_STAGE="$STAGED_FILE"
stage_install_file "$work_dir/sp11-touchscreen.modprobe" "$MODPROBE_DESTINATION_DIR" 0644
MODPROBE_STAGE="$STAGED_FILE"
stage_install_file "$work_dir/sp11-touchscreen.modules-load" "$MODULES_LOAD_DESTINATION_DIR" 0644
MODULES_LOAD_STAGE="$STAGED_FILE"
stage_install_file "$work_dir/sp11-touchscreen.initramfs-hook" "$INITRAMFS_HOOK_DESTINATION_DIR" 0755
INITRAMFS_HOOK_STAGE="$STAGED_FILE"
stage_install_file "$work_dir/sp11-touchscreen.dracut" "$DRACUT_DESTINATION_DIR" 0644
DRACUT_STAGE="$STAGED_FILE"
stage_install_file "$work_dir/release-marker" "$RELEASE_MARKER_DESTINATION_DIR" 0644
RELEASE_MARKER_STAGE="$STAGED_FILE"

prepare_system_backups

echo "Installing Surface Pro 11 touchscreen support for exact ABI: $RELEASE"
publish_direct_transaction \
  "$GPI_STAGE" "$GPI_DESTINATION" \
  "$SPI_STAGE" "$SPI_DESTINATION" \
  "$TOUCH_STAGE" "$TOUCH_DESTINATION" \
  "$MODPROBE_STAGE" "$MODPROBE_DESTINATION" \
  "$MODULES_LOAD_STAGE" "$MODULES_LOAD_DESTINATION" \
  "$INITRAMFS_HOOK_STAGE" "$INITRAMFS_HOOK_DESTINATION" \
  "$DRACUT_STAGE" "$DRACUT_DESTINATION" \
  "$RELEASE_MARKER_STAGE" "$RELEASE_MARKER_DESTINATION"

DEPMOD_MUTATED="true"
depmod_status=0
depmod -b "$TARGET_ROOT" -a "$RELEASE" || depmod_status=$?
capture_depmod_generated_identities
[ "$depmod_status" -eq 0 ] || die "depmod failed for exact target ABI: $RELEASE"

for index in "${!module_files[@]}"; do
  selected="$(modinfo -b "$TARGET_ROOT" -k "$RELEASE" -n "${module_names[index]}" 2>/dev/null || true)"
  expected_suffix="/lib/modules/$RELEASE/${module_relpaths[index]}"
  case "$selected" in
    *"$expected_suffix"|*"/usr$expected_suffix") ;;
    *) die "depmod selects '${selected:-nothing}' for ${module_names[index]}, expected updates/${module_relpaths[index]#updates/}" ;;
  esac
  cmp -s "${module_sources[index]}" "$MODULE_TREE/${module_relpaths[index]}" ||
    die "installed module differs from source: ${module_files[index]}"
  echo "Verified disk selection: ${module_names[index]} -> $selected"
done

INITRD_MUTATED="true"
refresh_status=0
if [ "$REFRESH_TOOL" = "update-initramfs" ]; then
  if [ "$INITRD_HAD_OLD" = "true" ]; then
    action=-u
  else
    action=-c
  fi
  if [ "$TARGET_ROOT" = "/" ]; then
    "$REFRESH_COMMAND" "$action" -k "$RELEASE" || refresh_status=$?
  else
    chroot "$TARGET_ROOT" "$REFRESH_COMMAND" "$action" -k "$RELEASE" || refresh_status=$?
  fi
else
  if [ "$TARGET_ROOT" = "/" ]; then
    "$REFRESH_COMMAND" --force "/boot/initrd.img-$RELEASE" "$RELEASE" || refresh_status=$?
  else
    chroot "$TARGET_ROOT" "$REFRESH_COMMAND" --force "/boot/initrd.img-$RELEASE" "$RELEASE" || refresh_status=$?
  fi
fi
INITRD_GENERATED_IDENTITY="$(regular_file_identity "$INITRD" 2>/dev/null || true)"
[ "$refresh_status" -eq 0 ] || die "initramfs refresh failed for exact target ABI: $RELEASE"

[ -s "$INITRD" ] || die "initramfs was not created or updated: $INITRD"
initrd_listing="$work_dir/initrd.list"
if [ "$INITRD_INSPECTOR" = "lsinitramfs" ]; then
  lsinitramfs "$INITRD" > "$initrd_listing" || die "lsinitramfs could not inspect $INITRD"
else
  lsinitrd "$INITRD" > "$initrd_listing" || die "lsinitrd could not inspect $INITRD"
fi

for relative in "${module_relpaths[@]}"; do
  initrd_path="lib/modules/$RELEASE/$relative"
  if ! grep -Fq "$initrd_path" "$initrd_listing" &&
     ! grep -Fq "usr/$initrd_path" "$initrd_listing"; then
    die "initramfs does not contain exact override path: $initrd_path"
  fi
  echo "Verified initramfs path: $initrd_path"
done

initrd_extract="$work_dir/initrd-extracted"
mkdir -p "$initrd_extract"
if [ "$INITRD_EXTRACTOR" = "unmkinitramfs" ]; then
  unmkinitramfs "$INITRD" "$initrd_extract" || die "unmkinitramfs could not extract $INITRD"
else
  (
    cd "$initrd_extract"
    lsinitrd --unpack "$INITRD"
  ) || die "lsinitrd could not extract $INITRD"
fi

for index in "${!module_files[@]}"; do
  expected_relative="lib/modules/$RELEASE/${module_relpaths[index]}"
  embedded="$(
    find "$initrd_extract" -type f \
      \( -path "*/$expected_relative" -o -path "*/usr/$expected_relative" \
         -o -path "*/$expected_relative.*" -o -path "*/usr/$expected_relative.*" \) \
      -print -quit
  )"
  [ -n "$embedded" ] || die "cannot locate extracted initramfs override for ${module_files[index]}"
  source_srcversion="$(modinfo -F srcversion "${module_sources[index]}")"
  embedded_srcversion="$(modinfo -F srcversion "$embedded" 2>/dev/null || true)"
  [ "$embedded_srcversion" = "$source_srcversion" ] ||
    die "initramfs ${module_files[index]} srcversion ${embedded_srcversion:-unknown} differs from $source_srcversion"

  unexpected="$(
    find "$initrd_extract" -type f -name "${module_files[index]}*" \
      ! -path "*/${module_relpaths[index]}" \
      ! -path "*/${module_relpaths[index]}.*" -print -quit
  )"
  [ -z "$unexpected" ] || die "initramfs also contains a stock/duplicate ${module_files[index]}: $unexpected"
  echo "Verified initramfs srcversion: ${module_names[index]} -> $embedded_srcversion"
done

commit_install_transaction

echo
echo "Surface Pro 11 touchscreen modules installed successfully."
echo "Profile: $PROFILE (sp11_windows_se_init=$SE_INIT_VALUE)"
if [ "$TARGET_ROOT" = "/" ] && [ "$(uname -r)" = "$RELEASE" ]; then
  echo "Reboot is required; the currently loaded modules were not replaced in memory."
else
  echo "Boot the exact kernel release '$RELEASE' to activate the installed stack."
fi
