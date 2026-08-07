#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"
EXPERIMENTAL_ABI=""
FALLBACK_ABI=""
BOOT_DIR="/boot"
APPLY="false"
CONFIRM_FALLBACK="false"
CONFIRM_STUBBLE_DTB="false"

usage() {
  cat <<EOF
Usage:
  $PROGRAM --experimental-abi ABI --fallback-abi ABI [options]

Queue an exact experimental qcom-x1e kernel ABI for the next boot only.
The default is a read-only dry run. This helper never reboots the machine.

Required:
  --experimental-abi ABI      Exact experimental ABI to boot once.
  --fallback-abi ABI          Exact known-good ABI to retain as fallback.

Options:
  --boot-directory DIR        Boot directory containing grub/ and kernel
                              images (default: /boot).
  --confirm-fallback-known-good
                              Confirm the running fallback passed the required
                              hardware checks. Required with --apply.
  --confirm-stubble-dtb       Confirm the experimental Stubble-wrapped image
                              already embeds the intended SP11 DTB. Required
                              with --apply.
  --apply                     Queue the one-shot boot with grub-reboot.
  -h, --help                  Show this help.

Example dry run:
  sudo ./$PROGRAM \
    --experimental-abi 7.2-rc5-jg-0sp11exp1-qcom-x1e \
    --fallback-abi 7.2-rc5-jg-0sp11v3-qcom-x1e

After reviewing the output, repeat with both confirmation flags and --apply.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

validate_abi() {
  local name="$1" abi="$2"

  [ -n "$abi" ] || die "$name is required."
  case "$abi" in
    *-qcom-x1e) ;;
    *) die "$name must be an exact qcom-x1e ABI ending in -qcom-x1e: $abi" ;;
  esac
  case "$abi" in
    *[!A-Za-z0-9._+~-]*) die "$name contains unsupported characters: $abi" ;;
  esac
}

extract_title() {
  local line="$1" value

  value="$(printf '%s\n' "$line" |
    sed -nE "s/^[[:space:]]*(menuentry|submenu)[[:space:]]+'([^']*)'.*/\2/p")"
  if [ -z "$value" ]; then
    value="$(printf '%s\n' "$line" |
      sed -nE 's/^[[:space:]]*(menuentry|submenu)[[:space:]]+"([^"]*)".*/\2/p')"
  fi
  printf '%s\n' "$value"
}

extract_id() {
  local line="$1" value

  value="$(printf '%s\n' "$line" |
    sed -nE "s/.*\\\$menuentry_id_option[[:space:]]+'([^']+)'.*/\1/p")"
  if [ -z "$value" ]; then
    value="$(printf '%s\n' "$line" |
      sed -nE 's/.*\$menuentry_id_option[[:space:]]+"([^"]+)".*/\1/p')"
  fi
  printf '%s\n' "$value"
}

resolve_menuentry() {
  local abi="$1" cfg="$2"
  local line trimmed title entry_id submenu_title="" submenu_id=""
  local in_menuentry="false" parent_component entry_component selector title_selector
  local -a matches=() match_titles=() match_title_selectors=()

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      submenu\ *)
        if [ "$in_menuentry" = "false" ]; then
          submenu_title="$(extract_title "$line")"
          submenu_id="$(extract_id "$line")"
        fi
        ;;
      menuentry\ *)
        title="$(extract_title "$line")"
        entry_id="$(extract_id "$line")"
        in_menuentry="true"

        if [ "$title" = "$abi" ] || [[ "$title" == *" $abi" ]]; then
          entry_component="${entry_id:-$title}"
          if [ -n "$submenu_title" ]; then
            parent_component="${submenu_id:-$submenu_title}"
            selector="$parent_component>$entry_component"
            title_selector="$submenu_title>$title"
          else
            selector="$entry_component"
            title_selector="$title"
          fi
          matches+=("$selector")
          match_titles+=("${submenu_title:+$submenu_title > }$title")
          match_title_selectors+=("$title_selector")
        fi
        ;;
      \})
        if [ "$in_menuentry" = "true" ]; then
          in_menuentry="false"
        elif [ -n "$submenu_title" ]; then
          submenu_title=""
          submenu_id=""
        fi
        ;;
    esac
  done < "$cfg"

  if [ "${#matches[@]}" -eq 0 ]; then
    die "No non-recovery GRUB menuentry ends with exact ABI: $abi"
  fi
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "Ambiguous GRUB entries for exact ABI $abi:" >&2
    printf '  - %s\n' "${match_titles[@]}" >&2
    die "Refusing to choose between ${#matches[@]} GRUB entries."
  fi

  RESOLVED_SELECTOR="${matches[0]}"
  RESOLVED_TITLE="${match_titles[0]}"
  RESOLVED_TITLE_SELECTOR="${match_title_selectors[0]}"
}

verify_boot_artifacts() {
  local role="$1" abi="$2" path

  for path in "$BOOT_DIR/vmlinuz-$abi" "$BOOT_DIR/initrd.img-$abi"; do
    [ -f "$path" ] || die "$role ABI is missing required boot artifact: $path"
    [ -s "$path" ] || die "$role ABI has an empty boot artifact: $path"
  done
}

read_grubenv() {
  local listing line

  listing="$(grub-editenv "$GRUB_ENV" list)" ||
    die "Cannot read GRUB environment block: $GRUB_ENV"

  ENV_SAVED_ENTRY=""
  ENV_NEXT_ENTRY=""
  ENV_PREV_SAVED_ENTRY=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      saved_entry=*) ENV_SAVED_ENTRY="${line#saved_entry=}" ;;
      next_entry=*) ENV_NEXT_ENTRY="${line#next_entry=}" ;;
      prev_saved_entry=*) ENV_PREV_SAVED_ENTRY="${line#prev_saved_entry=}" ;;
    esac
  done <<< "$listing"
}

verify_grub_one_shot_logic() {
  grep -Eq 'set[[:space:]]+default=.*next_entry' "$GRUB_CFG" ||
    die "GRUB config does not select next_entry as the next default."
  grep -Eq 'set[[:space:]]+next_entry=' "$GRUB_CFG" ||
    die "GRUB config does not clear next_entry during boot."
  grep -Eq 'save_env.*next_entry' "$GRUB_CFG" ||
    die "GRUB config does not persistently clear next_entry during boot."
  grep -Eq 'set[[:space:]]+boot_once=true' "$GRUB_CFG" ||
    die "GRUB config does not mark a next_entry boot as one-shot."
}

grub_persistent_default_uses_saved_entry() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    BEGIN {
      active = 0
      depth = 0
      outer_else = 0
      found = 0
    }

    {
      line = trim($0)
    }

    !active && line ~ /^if[[:space:]]*\[.*next_entry.*\][[:space:]]*;?[[:space:]]*then$/ {
      active = 1
      depth = 1
      next
    }

    active {
      if (line ~ /^if[[:space:]].*;[[:space:]]*then$/) {
        depth++
        next
      }
      if (line ~ /^fi[[:space:]]*;?$/) {
        depth--
        if (depth == 0) {
          active = 0
        }
        next
      }
      if (depth == 1 && line ~ /^else[[:space:]]*$/) {
        outer_else = 1
        next
      }
      if (depth == 1 && outer_else &&
          line ~ /^set[[:space:]]+default=["]?[$][{]?saved_entry[}]?["]?[[:space:]]*;?$/) {
        found = 1
      }
    }

    END {
      exit(found ? 0 : 1)
    }
  ' "$GRUB_CFG"
}

check_grubenv_storage() {
  local mount_options="" abstractions="" grub_fs=""

  require_command findmnt
  if ! mount_options="$(findmnt -no OPTIONS --target "$GRUB_ENV" 2>/dev/null)"; then
    die "Could not determine mount options for $GRUB_ENV; no GRUB state was changed."
  fi
  case ",$mount_options," in
    *,rw,*) ;;
    *,ro,*) die "The filesystem containing $GRUB_ENV is read-only; no GRUB state was changed." ;;
    *) die "Could not verify a writable filesystem for $GRUB_ENV; no GRUB state was changed." ;;
  esac

  require_command grub-probe
  if ! grub_fs="$(grub-probe --target=fs "$GRUB_ENV" 2>/dev/null)"; then
    die "Could not determine the GRUB environment filesystem; no GRUB state was changed."
  fi
  case "$grub_fs" in
    ext2|ext3|ext4)
      ;;
    btrfs|zfs|zfscrypt)
      die "GRUB environment filesystem '$grub_fs' is unsafe for reliable boot-time save_env; no GRUB state was changed."
      ;;
    "")
      die "Could not determine the GRUB environment filesystem; no GRUB state was changed."
      ;;
    *)
      die "GRUB environment filesystem '$grub_fs' is outside the verified ext-family allowlist; no GRUB state was changed."
      ;;
  esac

  if ! abstractions="$(grub-probe --target=abstraction "$GRUB_ENV" 2>/dev/null)"; then
    die "Could not determine GRUB storage abstractions; no GRUB state was changed."
  fi
  case " $abstractions " in
    *' diskfilter '*|*' lvm '*|*' mdraid '*|*' mdraid09 '*|*' mdraid1x '*)
      die "GRUB environment uses storage abstraction '$abstractions'; one-shot clearing is not reliable."
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --experimental-abi)
      [ "$#" -ge 2 ] || die "--experimental-abi requires a value."
      EXPERIMENTAL_ABI="$2"
      shift 2
      ;;
    --fallback-abi)
      [ "$#" -ge 2 ] || die "--fallback-abi requires a value."
      FALLBACK_ABI="$2"
      shift 2
      ;;
    --boot-directory)
      [ "$#" -ge 2 ] || die "--boot-directory requires a value."
      BOOT_DIR="${2%/}"
      [ -n "$BOOT_DIR" ] || BOOT_DIR="/"
      shift 2
      ;;
    --confirm-fallback-known-good)
      CONFIRM_FALLBACK="true"
      shift
      ;;
    --confirm-stubble-dtb)
      CONFIRM_STUBBLE_DTB="true"
      shift
      ;;
    --apply)
      APPLY="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

validate_abi "--experimental-abi" "$EXPERIMENTAL_ABI"
validate_abi "--fallback-abi" "$FALLBACK_ABI"
[ "$EXPERIMENTAL_ABI" != "$FALLBACK_ABI" ] ||
  die "Experimental and fallback ABIs must be different."

GRUB_CFG="$BOOT_DIR/grub/grub.cfg"
GRUB_ENV="$BOOT_DIR/grub/grubenv"

require_command grub-editenv
[ -r "$GRUB_CFG" ] || die "Cannot read GRUB config: $GRUB_CFG"
[ -r "$GRUB_ENV" ] || die "Cannot read GRUB environment: $GRUB_ENV"

RUNNING_ABI="$(uname -r)"
[ "$RUNNING_ABI" = "$FALLBACK_ABI" ] || {
  echo "Running ABI:  $RUNNING_ABI" >&2
  echo "Fallback ABI: $FALLBACK_ABI" >&2
  die "Run this helper from the exact known-good fallback kernel."
}

verify_boot_artifacts "Experimental" "$EXPERIMENTAL_ABI"
verify_boot_artifacts "Fallback" "$FALLBACK_ABI"
verify_grub_one_shot_logic
PERSISTENT_DEFAULT_USES_SAVED_ENTRY="false"
if grub_persistent_default_uses_saved_entry; then
  PERSISTENT_DEFAULT_USES_SAVED_ENTRY="true"
fi
check_grubenv_storage

resolve_menuentry "$EXPERIMENTAL_ABI" "$GRUB_CFG"
EXPERIMENTAL_SELECTOR="$RESOLVED_SELECTOR"
EXPERIMENTAL_TITLE="$RESOLVED_TITLE"
resolve_menuentry "$FALLBACK_ABI" "$GRUB_CFG"
FALLBACK_SELECTOR="$RESOLVED_SELECTOR"
FALLBACK_TITLE="$RESOLVED_TITLE"
FALLBACK_TITLE_SELECTOR="$RESOLVED_TITLE_SELECTOR"

read_grubenv
[ -z "$ENV_NEXT_ENTRY" ] ||
  die "GRUB already has a queued next_entry; clear or boot it before replacing it: $ENV_NEXT_ENTRY"
[ -z "$ENV_PREV_SAVED_ENTRY" ] ||
  die "GRUB has a stale prev_saved_entry; resolve it before queuing an experiment."

SAVED_ENTRY_BEFORE="$ENV_SAVED_ENTRY"

SAVED_ENTRY_MATCHES_FALLBACK="false"
if [ "$SAVED_ENTRY_BEFORE" = "$FALLBACK_SELECTOR" ] ||
  [ "$SAVED_ENTRY_BEFORE" = "$FALLBACK_TITLE_SELECTOR" ]; then
  SAVED_ENTRY_MATCHES_FALLBACK="true"
fi

if [ "$SAVED_ENTRY_MATCHES_FALLBACK" = "true" ] &&
  [ "$PERSISTENT_DEFAULT_USES_SAVED_ENTRY" = "true" ]; then
  PREFLIGHT_RESULT="passed"
else
  PREFLIGHT_RESULT="blocked"
fi

cat <<EOF
Surface Pro 11 one-shot kernel preflight $PREFLIGHT_RESULT.

  Running known-good ABI: $RUNNING_ABI
  Fallback GRUB entry:    $FALLBACK_TITLE
  Fallback selector:      $FALLBACK_SELECTOR
  Experimental ABI:      $EXPERIMENTAL_ABI
  Experimental entry:    $EXPERIMENTAL_TITLE
  One-shot selector:      $EXPERIMENTAL_SELECTOR
  Preserved saved_entry:  ${SAVED_ENTRY_BEFORE:-<unset>}

IMPORTANT: this helper only selects an installed kernel image. It does not
replace or inject a device tree. The Surface Pro 11 uses the DTB embedded in
the Stubble-wrapped kernel image, so that image must already contain the
intended, validated DTB before it is queued.
EOF

if [ "$PERSISTENT_DEFAULT_USES_SAVED_ENTRY" != "true" ]; then
  cat >&2 <<EOF

BLOCKED: the generated GRUB non-one-shot path does not consume saved_entry.
Even a matching saved_entry cannot be the verified persistent fallback while
grub.cfg uses a static default.

This helper will not edit GRUB defaults. Align the generated configuration
before changing saved_entry:

  1. Set GRUB_DEFAULT=saved in /etc/default/grub or the final effective drop-in.
  2. Run: sudo update-grub
  3. Confirm grub.cfg falls back from next_entry to saved_entry.
  4. Run: sudo grub-set-default '$FALLBACK_TITLE_SELECTOR'
  5. Repeat this dry run.

grub-set-default alone is insufficient when generated grub.cfg uses a static
default. No GRUB state was changed.
EOF
fi

if [ "$SAVED_ENTRY_MATCHES_FALLBACK" != "true" ]; then
  cat >&2 <<EOF

BLOCKED: grubenv saved_entry does not identify the declared fallback ABI.

  Current saved_entry:    ${SAVED_ENTRY_BEFORE:-<unset>}
  Accepted fallback ID:   $FALLBACK_SELECTOR
  Accepted fallback title: $FALLBACK_TITLE_SELECTOR

This helper will not change saved_entry. After independently verifying the
fallback kernel and confirming generated grub.cfg consumes saved_entry, align
it explicitly with:

  sudo grub-set-default '$FALLBACK_TITLE_SELECTOR'

Then inspect the result and repeat this dry run:

  sudo grub-editenv $GRUB_ENV list

No GRUB state was changed.
EOF
fi

if [ "$PREFLIGHT_RESULT" != "passed" ]; then
  exit 1
fi

if [ "$APPLY" != "true" ]; then
  cat <<EOF

DRY RUN: no GRUB state was changed. Re-run as root with --apply,
--confirm-fallback-known-good, and --confirm-stubble-dtb after reviewing this
selection. The helper will queue one boot and will not reboot the machine.
EOF
  exit 0
fi

[ "$EUID" -eq 0 ] || die "--apply must run as root (for example, with sudo)."
[ "$CONFIRM_FALLBACK" = "true" ] ||
  die "--apply requires --confirm-fallback-known-good."
[ "$CONFIRM_STUBBLE_DTB" = "true" ] ||
  die "--apply requires --confirm-stubble-dtb."
[ -w "$GRUB_ENV" ] || die "GRUB environment is not writable: $GRUB_ENV"
require_command grub-reboot

grub-reboot --boot-directory="$BOOT_DIR" "$EXPERIMENTAL_SELECTOR"

read_grubenv
[ "$ENV_SAVED_ENTRY" = "$SAVED_ENTRY_BEFORE" ] ||
  die "grub-reboot changed saved_entry unexpectedly; inspect $GRUB_ENV before rebooting."
[ -z "$ENV_PREV_SAVED_ENTRY" ] ||
  die "grub-reboot created prev_saved_entry unexpectedly; inspect $GRUB_ENV before rebooting."
[ "$ENV_NEXT_ENTRY" = "$EXPERIMENTAL_SELECTOR" ] ||
  die "GRUB did not record the expected one-shot selector; inspect $GRUB_ENV before rebooting."

cat <<EOF

Queued exactly one experimental boot. The persistent saved_entry is unchanged.
This helper did not reboot the machine.

Before rebooting, keep recovery media available. To cancel the queued boot:
  sudo grub-editenv $GRUB_ENV unset next_entry
EOF
