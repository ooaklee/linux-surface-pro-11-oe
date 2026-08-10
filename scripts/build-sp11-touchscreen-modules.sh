#!/usr/bin/env bash
set -euo pipefail

sanitize_git_environment() {
  local variable_name

  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_COMMON_DIR
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM
  unset GIT_CONFIG_GLOBAL GIT_DIR GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_EXEC_PATH
  unset GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_PREFIX
  unset GIT_SHALLOW_FILE GIT_WORK_TREE
  for variable_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
    unset "$variable_name"
  done
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_ATTR_NOSYSTEM=1
  export GIT_NO_REPLACE_OBJECTS=1
}

sanitize_git_environment

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
repo_build_dir="$repo_dir/build"
signed_module_validator="$repo_dir/scripts/validate-sp11-signed-modules.py"
module_signing_trust_anchor="$repo_dir/config/kernel-signing/sp11-module-signing-cert.pem"
APPROVED_MODULE_SIGNING_CERT_SHA256="8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b"

# Build the Surface Pro 11 OLED touchscreen module set from an immutable
# geocausa Phase 91 revision. Installation is delegated to the guarded
# installer, which also rebuilds and verifies the target initramfs.

GIT_URL="https://github.com/geocausa/SP11X1e-touchscreen.git"
# Phase 91 release merge. The later ddb79dd revision used for the original v3
# artifacts changes documentation only; the module sources are identical.
GIT_REF="6bbcf7a4759a73014047a57e819219dd7f34951a"
SOURCE_DIR="build/SP11X1e-touchscreen"
OUT_DIR=".sp11-kmod-v3"
RELEASE=""
KERNEL_BUILD_DIR=""
KERNEL_COMMON_HEADERS_DEB=""
KERNEL_HEADERS_DEB=""
KERNEL_HEADERS_EXTRACT_DIR=""
KERNEL_HEADERS_TEMP_BASE=""
OUT_ABS=""
OUT_PARENT_ABS=""
OUTPUT_STAGE_DIR=""
OUTPUT_BACKUP_CONTAINER=""
OUTPUT_BACKUP_ACTIVE="false"
INSTALL_SNAPSHOT_DIR=""
INSTALL="false"
OFFLINE="false"
ALLOW_UNSUPPORTED_RELEASE="false"
WINDOWS_SE_INIT="false"
MODULE_SIGNING_KEY=""
MODULE_SIGNING_CERTIFICATE=""
MODULE_SIGNING_PIN_FILE=""
MODULE_SIGNING_KEY_IDENTITY=""
MODULE_SIGNING_CERTIFICATE_IDENTITY=""
MODULE_SIGNING_PIN_IDENTITY=""
STAGED_MODULE_SIGNING_KEY=""
STAGED_MODULE_SIGNING_CERTIFICATE=""
STAGED_MODULE_SIGNING_PIN_FILE=""
SIGNING_VALIDATION_DIR=""
SIGNING_TEMP_BASE=""
TRUSTED_OPENSSL=""
TRUSTED_OPENSSL_IDENTITY=""
TRUSTED_PYTHON="/usr/bin/python3"
unset KBUILD_SIGN_PIN

usage() {
  cat <<EOF
Usage: $0 [options]

Builds the pinned geocausa Phase 91 gpi, spi-geni-qcom, and
mshw0485_touch modules for a Surface Pro 11 touchscreen kernel.

Options:
  --release VER       Target kernel release. By default, use the running v3
                      release or the sole installed sp11v3 release.
  --kernel-build-dir DIR
                      Exact prepared kernel build tree. By default, use
                      /lib/modules/<release>/build.
  --kernel-common-headers-deb PATH
                      Exact linux-qcom-x1e-headers Deb from the kernel build.
  --kernel-headers-deb PATH
                      Exact architecture headers Deb from the kernel build.
                      Supply both header Deb options together for release
                      provenance; local builds may omit both.
  --source-dir DIR    Managed geocausa checkout, default $SOURCE_DIR.
  --source-url URL    Source repository, default $GIT_URL.
  --source-ref REF    Immutable source commit, default $GIT_REF.
  --out-dir DIR       Module output directory, default $OUT_DIR.
  --module-signing-key PATH
                      Controlled RSA-4096 private key. Private key material,
                      its path, and KBUILD_SIGN_PIN are never retained.
  --module-signing-certificate PATH
                      Matching public X.509 certificate in exact PEM form.
  --module-signing-pin-file PATH
                      One-line PIN for the encrypted PKCS#8 private key.
  --offline           Do not fetch; require source-ref in the local checkout.
  --install           Install, rebuild the exact target initramfs, and verify.
  --windows-se-init   Opt in to the experimental captured Windows cold-init
                      controller path. The validated default leaves it off.
  --allow-unsupported-release
                      Build for a release without an sp11v3 ABI marker. This
                      cannot make a kernel without the touchscreen DT usable.
  -h, --help          Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

cleanup_kernel_headers() {
  [ -n "$KERNEL_HEADERS_EXTRACT_DIR" ] || return 0
  case "$KERNEL_HEADERS_EXTRACT_DIR" in
    "$KERNEL_HEADERS_TEMP_BASE"/sp11-touchscreen-headers.*)
      rm -rf -- "$KERNEL_HEADERS_EXTRACT_DIR"
      ;;
    *)
      echo "warning: refusing to remove unexpected headers directory: $KERNEL_HEADERS_EXTRACT_DIR" >&2
      ;;
  esac
}

cleanup_output_transaction() {
  if [ "$OUTPUT_BACKUP_ACTIVE" = "true" ] &&
     [ -n "$OUTPUT_BACKUP_CONTAINER" ] &&
     [ -d "$OUTPUT_BACKUP_CONTAINER/previous" ] &&
     [ -n "$OUT_ABS" ]; then
    if [ -e "$OUT_ABS" ] || [ -L "$OUT_ABS" ]; then
      echo "warning: output appeared during publication; preserving it at $OUT_ABS and the prior output at $OUTPUT_BACKUP_CONTAINER/previous" >&2
    else
      mv "$OUTPUT_BACKUP_CONTAINER/previous" "$OUT_ABS" ||
        echo "warning: could not restore prior module output: $OUT_ABS" >&2
    fi
  fi

  if [ -n "$OUTPUT_STAGE_DIR" ]; then
    case "$OUTPUT_STAGE_DIR" in
      "$OUT_PARENT_ABS"/.sp11-touchscreen-stage.*) rm -rf -- "$OUTPUT_STAGE_DIR" ;;
      *) echo "warning: refusing to remove unexpected module stage: $OUTPUT_STAGE_DIR" >&2 ;;
    esac
  fi
  if [ -n "$OUTPUT_BACKUP_CONTAINER" ]; then
    case "$OUTPUT_BACKUP_CONTAINER" in
      "$OUT_PARENT_ABS"/.sp11-touchscreen-backup.*)
        if [ ! -e "$OUTPUT_BACKUP_CONTAINER/previous" ]; then
          rm -rf -- "$OUTPUT_BACKUP_CONTAINER"
        fi
        ;;
      *) echo "warning: refusing to remove unexpected module backup: $OUTPUT_BACKUP_CONTAINER" >&2 ;;
    esac
  fi
}

cleanup_install_snapshot() {
  [ -n "$INSTALL_SNAPSHOT_DIR" ] || return 0
  case "$INSTALL_SNAPSHOT_DIR" in
    "$OUT_PARENT_ABS"/.sp11-touchscreen-install.*)
      if [ -d "$INSTALL_SNAPSHOT_DIR" ] && [ ! -L "$INSTALL_SNAPSHOT_DIR" ]; then
        chmod 0700 "$INSTALL_SNAPSHOT_DIR" 2>/dev/null || true
      fi
      rm -rf -- "$INSTALL_SNAPSHOT_DIR"
      ;;
    *) echo "warning: refusing to remove unexpected install snapshot: $INSTALL_SNAPSHOT_DIR" >&2 ;;
  esac
}

cleanup_signing_validation() {
  [ -n "$SIGNING_VALIDATION_DIR" ] || return 0
  case "$SIGNING_VALIDATION_DIR" in
    "$SIGNING_TEMP_BASE"/sp11-touchscreen-signing.*)
      rm -rf -- "$SIGNING_VALIDATION_DIR"
      ;;
    *) echo "warning: refusing to remove unexpected signing validation directory" >&2 ;;
  esac
}

cleanup_all() {
  cleanup_install_snapshot
  cleanup_output_transaction
  cleanup_kernel_headers
  cleanup_signing_validation
}

trap cleanup_all EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

validate_managed_path_text() {
  local value="$1" label="$2"

  case "$value" in
    ""|/|.|..|*/|*//*|*/../*|../*|*/..|*/./*|./*|*/.|*[!A-Za-z0-9._+/-]*)
      die "$label has an unsafe path: $value"
      ;;
  esac
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
  case "$mode" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mode"
}

regular_file_metadata_identity() {
  local path="$1" identity

  [ -s "$path" ] && [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if identity="$(stat -c '%d:%i:%f:%u:%g:%s:%Y:%Z:%h' -- "$path" 2>/dev/null)"; then
    :
  elif identity="$(stat -f '%d:%i:%p:%u:%g:%z:%m:%c:%l' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  printf '%s\n' "$identity"
}

file_link_count() {
  local count

  if count="$(stat -c '%h' -- "$1" 2>/dev/null)"; then
    :
  elif count="$(stat -f '%l' "$1" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  case "$count" in ""|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$count"
}

select_trusted_openssl() {
  local candidate parent leaf mode owner

  case "$(uname -s)" in
    Linux) candidate="/usr/bin/openssl" ;;
    Darwin)
      if [ -x /opt/homebrew/opt/openssl@3/bin/openssl ]; then
        candidate="/opt/homebrew/opt/openssl@3/bin/openssl"
      elif [ -x /usr/local/opt/openssl@3/bin/openssl ]; then
        candidate="/usr/local/opt/openssl@3/bin/openssl"
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  parent="$(cd "$(dirname "$candidate")" && pwd -P)" || return 1
  leaf="$(basename "$candidate")"
  candidate="$parent/$leaf"
  [ -s "$candidate" ] && [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
    [ -x "$candidate" ] || return 1
  mode="$(file_mode "$candidate")" || return 1
  [ $((8#$mode & 8#22)) -eq 0 ] || return 1
  if [ "$(uname -s)" = "Linux" ]; then
    if owner="$(stat -c '%u' -- "$candidate" 2>/dev/null)"; then
      :
    elif owner="$(stat -f '%u' "$candidate" 2>/dev/null)"; then
      :
    else
      return 1
    fi
    [ "$owner" -eq 0 ] || return 1
  fi
  printf '%s\n' "$candidate"
}

verify_trusted_openssl() {
  local current_identity

  current_identity="$(regular_file_metadata_identity "$TRUSTED_OPENSSL")" || return 1
  [ "$current_identity" = "$TRUSTED_OPENSSL_IDENTITY" ]
}

source_git() {
  command git \
    -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false \
    "$@"
}

resolve_source_path() {
  local requested_abs source_parent source_leaf source_parent_physical source_physical

  validate_managed_path_text "$SOURCE_DIR" "source directory"
  [ -d "$repo_build_dir" ] && [ ! -L "$repo_build_dir" ] ||
    die "repository build directory must already be a real, non-symlinked directory"
  [ "$(cd "$repo_build_dir" && pwd -P)" = "$repo_build_dir" ] ||
    die "repository build directory contains a symlink component"
  case "$SOURCE_DIR" in
    /*) requested_abs="$SOURCE_DIR" ;;
    *) requested_abs="$repo_dir/$SOURCE_DIR" ;;
  esac
  source_parent="$(dirname "$requested_abs")"
  source_leaf="$(basename "$requested_abs")"
  case "$source_leaf" in
    ""|.|..|*[!A-Za-z0-9._+-]*) die "source directory has an unsafe leaf: $source_leaf" ;;
  esac
  [ -d "$source_parent" ] && [ ! -L "$source_parent" ] ||
    die "source directory parent must already be a real directory: $source_parent"
  source_parent_physical="$(cd "$source_parent" && pwd -P)"
  [ "$source_parent_physical" = "$source_parent" ] ||
    die "source directory parent contains a symlink component"
  case "$source_parent_physical" in
    "$repo_build_dir"|"$repo_build_dir"/*) ;;
    *) die "source directory must be a physical descendant of repository build/" ;;
  esac
  SOURCE_DIR="$source_parent_physical/$source_leaf"
  if [ -e "$SOURCE_DIR" ] || [ -L "$SOURCE_DIR" ]; then
    [ -d "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR" ] ||
      die "source directory must be a real, non-symlinked directory: $SOURCE_DIR"
    source_physical="$(cd "$SOURCE_DIR" && pwd -P)"
    [ "$source_physical" = "$SOURCE_DIR" ] ||
      die "source directory contains a symlink component"
  fi
}

validate_source_git_binding() {
  local common_dir common_physical git_dir git_physical top_level top_physical

  [ -d "$SOURCE_DIR/.git" ] && [ ! -L "$SOURCE_DIR/.git" ] ||
    die "source checkout must contain a real, non-symlinked .git directory: $SOURCE_DIR"
  git_physical="$(cd "$SOURCE_DIR/.git" && pwd -P)"
  [ "$git_physical" = "$SOURCE_DIR/.git" ] ||
    die "source checkout .git directory contains a symlink component"
  if ! top_level="$(source_git -C "$SOURCE_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
     ! git_dir="$(source_git -C "$SOURCE_DIR" rev-parse --absolute-git-dir 2>/dev/null)" ||
     ! common_dir="$(source_git -C "$SOURCE_DIR" rev-parse --git-common-dir 2>/dev/null)"; then
    die "could not bind the source checkout worktree and Git directory"
  fi
  [ -d "$top_level" ] && [ ! -L "$top_level" ] ||
    die "source checkout worktree is not a physical directory"
  top_physical="$(cd "$top_level" && pwd -P)"
  git_physical="$(cd "$git_dir" && pwd -P)"
  [ "$top_level" = "$SOURCE_DIR" ] && [ "$top_physical" = "$SOURCE_DIR" ] ||
    die "source checkout core.worktree redirects outside the managed checkout"
  [ "$git_dir" = "$SOURCE_DIR/.git" ] && [ "$git_physical" = "$SOURCE_DIR/.git" ] ||
    die "source checkout Git directory redirects outside the managed checkout"
  case "$common_dir" in
    /*) ;;
    *) common_dir="$SOURCE_DIR/$common_dir" ;;
  esac
  [ -d "$common_dir" ] && [ ! -L "$common_dir" ] ||
    die "source checkout common Git directory is not a physical directory"
  common_physical="$(cd "$common_dir" && pwd -P)"
  [ "$common_physical" = "$SOURCE_DIR/.git" ] ||
    die "source checkout common Git directory redirects outside the managed checkout"
}

validate_source_local_git_config() {
  local config_name config_names normalized_name

  if ! config_names="$(source_git -C "$SOURCE_DIR" config --local --includes --name-only --list)"; then
    die "could not inspect the source checkout local Git configuration"
  fi
  while IFS= read -r config_name; do
    [ -n "$config_name" ] || continue
    normalized_name="$(printf '%s\n' "$config_name" | tr '[:upper:]' '[:lower:]')"
    case "$normalized_name" in
      filter.*|core.attributesfile|include.*|includeif.*|extensions.worktreeconfig)
        die "source checkout local Git configuration is unsafe: $config_name"
        ;;
    esac
  done <<EOF_SOURCE_CONFIG
$config_names
EOF_SOURCE_CONFIG
}

resolve_output_path() {
  local requested_abs output_parent output_leaf output_parent_physical output_physical
  local dedicated_root dedicated_root_physical

  validate_managed_path_text "$OUT_DIR" "output directory"
  case "$OUT_DIR" in
    /*) requested_abs="$OUT_DIR" ;;
    *) requested_abs="$repo_dir/$OUT_DIR" ;;
  esac
  output_parent="$(dirname "$requested_abs")"
  output_leaf="$(basename "$requested_abs")"
  case "$output_leaf" in
    ""|.|..|*[!A-Za-z0-9._+-]*) die "output directory has an unsafe leaf: $output_leaf" ;;
  esac
  [ -d "$output_parent" ] && [ ! -L "$output_parent" ] ||
    die "output directory parent must already be a real directory: $output_parent"
  output_parent_physical="$(cd "$output_parent" && pwd -P)"
  [ "$output_parent_physical" = "$output_parent" ] ||
    die "output directory parent contains a symlink component"

  case "$requested_abs" in
    "$repo_dir"/.sp11-kmod-v*)
      [ "$output_parent_physical" = "$repo_dir" ] &&
      [[ "$output_leaf" =~ ^\.sp11-kmod-v[0-9]+([._+-][A-Za-z0-9._+-]+)?$ ]] ||
        die "repository-root output must match .sp11-kmod-vN"
      ;;
    "$repo_build_dir"/sp11-touchscreen-module-output/*)
      dedicated_root="$repo_build_dir/sp11-touchscreen-module-output"
      [ -d "$dedicated_root" ] && [ ! -L "$dedicated_root" ] ||
        die "dedicated module output root must already be a real directory"
      dedicated_root_physical="$(cd "$dedicated_root" && pwd -P)"
      [ "$dedicated_root_physical" = "$dedicated_root" ] ||
        die "dedicated module output root contains a symlink component"
      case "$output_parent_physical" in
        "$dedicated_root_physical"|"$dedicated_root_physical"/*) ;;
        *) die "output directory parent escapes the dedicated module output root" ;;
      esac
      ;;
    "$repo_build_dir"/*-touchscreen-modules)
      [ "$output_parent_physical" = "$repo_build_dir" ] &&
        [[ "$output_leaf" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*-touchscreen-modules$ ]] ||
        die "direct build output must use a safe *-touchscreen-modules leaf"
      ;;
    *)
      die "output directory must match repository .sp11-kmod-vN, a direct build/*-touchscreen-modules leaf, or live under build/sp11-touchscreen-module-output/"
      ;;
  esac

  OUT_PARENT_ABS="$output_parent_physical"
  OUT_ABS="$OUT_PARENT_ABS/$output_leaf"
  OUT_DIR="$OUT_ABS"
  if [ -e "$OUT_ABS" ] || [ -L "$OUT_ABS" ]; then
    [ -d "$OUT_ABS" ] && [ ! -L "$OUT_ABS" ] ||
      die "output path must be a real, non-symlinked directory: $OUT_ABS"
    output_physical="$(cd "$OUT_ABS" && pwd -P)"
    [ "$output_physical" = "$OUT_ABS" ] ||
      die "output directory contains a symlink component"
  fi
}

validate_output_leaves() {
  local directory="$1" require_all="$2" expected_mode="${3:-644}"
  local entry entry_name mode count=0

  [ -d "$directory" ] && [ ! -L "$directory" ] ||
    die "module output is not a real directory: $directory"
  while IFS= read -r -d '' entry; do
    entry_name="$(basename "$entry")"
    case "$entry_name" in
      gpi.ko|spi-geni-qcom.ko|mshw0485_touch.ko|sp11-module-signing-cert.x509|sp11-touchscreen-modules-manifest.txt) ;;
      *) die "module output contains an unexpected entry: $entry_name" ;;
    esac
    [ -f "$entry" ] && [ ! -L "$entry" ] ||
      die "module output leaf is not a regular, non-symlinked file: $entry_name"
    if [ "$require_all" = "true" ]; then
      [ -s "$entry" ] || die "module output leaf is empty: $entry_name"
      mode="$(file_mode "$entry")" || die "could not inspect module output mode: $entry_name"
      [ "$mode" = "$expected_mode" ] ||
        die "module output leaf has the wrong mode: $entry_name ($mode)"
    fi
    count=$((count + 1))
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
  if [ "$require_all" = "true" ]; then
    [ "$count" -eq 5 ] || die "module output does not contain exactly five release files"
  fi
}

validate_signed_bundle() {
  local directory="$1"

  "$TRUSTED_PYTHON" -I "$signed_module_validator" \
    --certificate "$directory/sp11-module-signing-cert.x509" \
    --module "$directory/gpi.ko" \
    --module "$directory/spi-geni-qcom.ko" \
    --module "$directory/mshw0485_touch.ko" \
    --manifest "$directory/sp11-touchscreen-modules-manifest.txt" >/dev/null ||
    die "controlled touchscreen module signature validation failed"
}

validate_module_identities() {
  local directory="$1" module actual_name actual_release

  for module in gpi spi-geni-qcom mshw0485_touch; do
    [ -s "$directory/$module.ko" ] && [ -f "$directory/$module.ko" ] &&
      [ ! -L "$directory/$module.ko" ] ||
      die "staged module is not a non-empty regular file: $module.ko"
    actual_name="$(modinfo -F name "$directory/$module.ko")"
    case "$module:$actual_name" in
      gpi:gpi|spi-geni-qcom:spi_geni_qcom|mshw0485_touch:mshw0485_touch) ;;
      *) die "$module.ko has unexpected staged module name $actual_name" ;;
    esac
    actual_release="$(modinfo -F vermagic "$directory/$module.ko" | awk '{print $1}')"
    [ "$actual_release" = "$RELEASE" ] ||
      die "$module.ko staged copy is for $actual_release, not $RELEASE"
    [ -n "$(modinfo -F srcversion "$directory/$module.ko")" ] ||
      die "$module.ko staged copy has no srcversion"
  done
  modinfo -p "$directory/spi-geni-qcom.ko" | grep -q '^sp11_windows_se_init:' ||
    die "staged spi-geni-qcom.ko lacks the expected SP11 controller parameter"
  modinfo -F alias "$directory/mshw0485_touch.ko" | grep -q 'microsoft,mshw0485' ||
    die "staged mshw0485_touch.ko lacks the Surface Pro 11 device-tree alias"
}

atomic_publish_directory() {
  "$TRUSTED_PYTHON" - "$1" "$2" <<'PY_ATOMIC_RENAME'
import ctypes
import os
import sys

source = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)

if sys.platform.startswith("linux"):
    rename = libc.renameat2
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    result = rename(-100, source, -100, destination, 1)
elif sys.platform == "darwin":
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    result = rename(source, destination, 4)
else:
    raise SystemExit("exclusive directory publication is unsupported on this platform")

if result != 0:
    error_number = ctypes.get_errno()
    raise OSError(error_number, os.strerror(error_number), sys.argv[2])
PY_ATOMIC_RENAME
}

prepare_install_snapshot() {
  local leaf source_sha snapshot_sha

  INSTALL_SNAPSHOT_DIR="$(mktemp -d "$OUT_PARENT_ABS/.sp11-touchscreen-install.XXXXXX")"
  INSTALL_SNAPSHOT_DIR="$(cd "$INSTALL_SNAPSHOT_DIR" && pwd -P)"
  chmod 0700 "$INSTALL_SNAPSHOT_DIR"
  for leaf in \
    gpi.ko spi-geni-qcom.ko mshw0485_touch.ko \
    sp11-module-signing-cert.x509 \
    sp11-touchscreen-modules-manifest.txt; do
    install -m 0400 "$OUTPUT_STAGE_DIR/$leaf" "$INSTALL_SNAPSHOT_DIR/$leaf"
    source_sha="$(sha256sum "$OUTPUT_STAGE_DIR/$leaf" | awk '{print $1}')"
    snapshot_sha="$(sha256sum "$INSTALL_SNAPSHOT_DIR/$leaf" | awk '{print $1}')"
    [ "$snapshot_sha" = "$source_sha" ] ||
      die "private install snapshot changed while copying $leaf"
  done
  validate_output_leaves "$INSTALL_SNAPSHOT_DIR" true 400
  validate_module_identities "$INSTALL_SNAPSHOT_DIR"
  validate_signed_bundle "$INSTALL_SNAPSHOT_DIR"
  chmod 0500 "$INSTALL_SNAPSHOT_DIR"
}

publish_output_stage() {
  local current_parent

  current_parent="$(cd "$OUT_PARENT_ABS" && pwd -P)"
  [ "$current_parent" = "$OUT_PARENT_ABS" ] && [ ! -L "$OUT_PARENT_ABS" ] ||
    die "output parent changed before publication"
  validate_output_leaves "$OUTPUT_STAGE_DIR" true
  if [ -e "$OUT_ABS" ] || [ -L "$OUT_ABS" ]; then
    validate_output_leaves "$OUT_ABS" false
    OUTPUT_BACKUP_CONTAINER="$(mktemp -d "$OUT_PARENT_ABS/.sp11-touchscreen-backup.XXXXXX")"
    OUTPUT_BACKUP_CONTAINER="$(cd "$OUTPUT_BACKUP_CONTAINER" && pwd -P)"
    chmod 0700 "$OUTPUT_BACKUP_CONTAINER"
    OUTPUT_BACKUP_ACTIVE="true"
    mv "$OUT_ABS" "$OUTPUT_BACKUP_CONTAINER/previous"
  fi
  [ ! -e "$OUT_ABS" ] && [ ! -L "$OUT_ABS" ] ||
    die "output path appeared during atomic publication: $OUT_ABS"
  chmod 0755 "$OUTPUT_STAGE_DIR"
  atomic_publish_directory "$OUTPUT_STAGE_DIR" "$OUT_ABS"
  OUTPUT_STAGE_DIR=""
  validate_output_leaves "$OUT_ABS" true
  validate_signed_bundle "$OUT_ABS"
  if [ "$OUTPUT_BACKUP_ACTIVE" = "true" ]; then
    OUTPUT_BACKUP_ACTIVE="false"
    rm -rf -- "$OUTPUT_BACKUP_CONTAINER"
    OUTPUT_BACKUP_CONTAINER=""
  fi
}

validate_extracted_header_root() {
  local header_root="$1" package_label="$2"
  local header_link header_link_target resolved_header_link

  [ -d "$header_root/usr" ] && [ ! -L "$header_root/usr" ] &&
    [ -d "$header_root/usr/src" ] && [ ! -L "$header_root/usr/src" ] ||
    die "$package_label does not provide a safe usr/src hierarchy"
  if ! find "$header_root" -print >/dev/null; then
    die "could not inspect the extracted $package_label"
  fi
  if find "$header_root" ! -type f ! -type d ! -type l -print -quit | grep -q .; then
    die "extracted $package_label contains a special filesystem entry"
  fi
  while IFS= read -r -d '' header_link; do
    header_link_target="$(readlink "$header_link")"
    case "$header_link_target" in
      /*) die "extracted $package_label usr/src input contains an absolute symlink" ;;
    esac
    if ! resolved_header_link="$(readlink -f -- "$header_link")" ||
       [ -z "$resolved_header_link" ]; then
      die "extracted $package_label usr/src input contains a broken symlink"
    fi
    case "$resolved_header_link" in
      "$header_root"/*) ;;
      *) die "extracted $package_label usr/src input contains a symlink outside its pristine root" ;;
    esac
  done < <(find "$header_root/usr/src" -type l -print0)
}

require_single_header_source_root() {
  local header_root="$1" expected_name="$2" package_label="$3"
  local entry
  local -a entries=()

  [ -d "$header_root/usr" ] && [ ! -L "$header_root/usr" ] &&
    [ -d "$header_root/usr/src" ] && [ ! -L "$header_root/usr/src" ] ||
    die "$package_label does not provide a safe usr/src hierarchy"
  while IFS= read -r -d '' entry; do
    entries+=("$(basename "$entry")")
  done < <(find "$header_root/usr/src" -mindepth 1 -maxdepth 1 -print0)
  if [ "${#entries[@]}" -ne 1 ] || [ "${entries[0]:-}" != "$expected_name" ] ||
     [ ! -d "$header_root/usr/src/$expected_name" ] ||
     [ -L "$header_root/usr/src/$expected_name" ]; then
    die "$package_label must contain exactly one safe usr/src/$expected_name tree"
  fi
}

resolve_release() {
  local running candidate
  local -a candidates=()

  if [ -n "$RELEASE" ]; then
    printf '%s\n' "$RELEASE"
    return 0
  fi

  running="$(uname -r)"
  case "$running" in
    *sp11v3*-qcom-x1e)
      if [ -d "/lib/modules/$running/build" ]; then
        printf '%s\n' "$running"
        return 0
      fi
      ;;
  esac

  for candidate in /lib/modules/*sp11v3*-qcom-x1e; do
    [ -d "$candidate/build" ] || continue
    candidates+=("${candidate##*/}")
  done

  if [ "${#candidates[@]}" -eq 1 ]; then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    die "no installed sp11v3 kernel with matching headers; pass --release VER"
  fi

  echo "Multiple installed sp11v3 header trees found:" >&2
  printf '  - %s\n' "${candidates[@]}" >&2
  die "choose the exact target with --release VER"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      require_arg "$1" "${2:-}"
      RELEASE="$2"
      shift 2
      ;;
    --source-dir)
      require_arg "$1" "${2:-}"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --kernel-build-dir)
      require_arg "$1" "${2:-}"
      KERNEL_BUILD_DIR="$2"
      shift 2
      ;;
    --kernel-common-headers-deb)
      require_arg "$1" "${2:-}"
      KERNEL_COMMON_HEADERS_DEB="$2"
      shift 2
      ;;
    --kernel-headers-deb)
      require_arg "$1" "${2:-}"
      KERNEL_HEADERS_DEB="$2"
      shift 2
      ;;
    --source-url)
      require_arg "$1" "${2:-}"
      GIT_URL="$2"
      shift 2
      ;;
    --source-ref)
      require_arg "$1" "${2:-}"
      GIT_REF="$2"
      shift 2
      ;;
    --out-dir)
      require_arg "$1" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --module-signing-key)
      require_arg "$1" "${2:-}"
      MODULE_SIGNING_KEY="$2"
      shift 2
      ;;
    --module-signing-certificate)
      require_arg "$1" "${2:-}"
      MODULE_SIGNING_CERTIFICATE="$2"
      shift 2
      ;;
    --module-signing-pin-file)
      require_arg "$1" "${2:-}"
      MODULE_SIGNING_PIN_FILE="$2"
      shift 2
      ;;
    --offline)
      OFFLINE="true"
      shift
      ;;
    --install)
      INSTALL="true"
      shift
      ;;
    --windows-se-init)
      WINDOWS_SE_INIT="true"
      shift
      ;;
    --allow-unsupported-release)
      ALLOW_UNSUPPORTED_RELEASE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$WINDOWS_SE_INIT" = "true" ] && [ "$INSTALL" != "true" ]; then
  die "--windows-se-init only applies with --install"
fi
if [ -z "$MODULE_SIGNING_KEY" ] || [ -z "$MODULE_SIGNING_CERTIFICATE" ] ||
   [ -z "$MODULE_SIGNING_PIN_FILE" ]; then
  die "controlled module signing requires all three signing file options"
fi
if [[ ! "$GIT_REF" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  die "--source-ref must be an immutable 40- or 64-character hexadecimal commit"
fi
require_tool tr
GIT_REF="$(printf '%s' "$GIT_REF" | tr '[:upper:]' '[:lower:]')"

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "module build requires an ARM64 host" ;;
esac

RELEASE="$(resolve_release)"
case "$RELEASE" in
  *sp11v3*-qcom-x1e) ;;
  *)
    if [ "$ALLOW_UNSUPPORTED_RELEASE" != "true" ]; then
      die "$RELEASE is not an sp11v3 touchscreen ABI; pass --allow-unsupported-release only for development"
    fi
    echo "Warning: building for unsupported release $RELEASE." >&2
    ;;
esac

require_tool git
require_tool grep
require_tool install
require_tool make
require_tool modinfo
require_tool sha256sum
require_tool basename
require_tool chmod
require_tool dirname
require_tool find
require_tool mktemp
require_tool mv
[ -x "$TRUSTED_PYTHON" ] || die "trusted /usr/bin/python3 is required"
require_tool stat

[ -f "$signed_module_validator" ] && [ ! -L "$signed_module_validator" ] ||
  die "controlled module signature validator is unavailable"
MODULE_SIGNING_KEY_IDENTITY="$(regular_file_metadata_identity "$MODULE_SIGNING_KEY")" ||
  die "controlled module-signing private key must be a non-empty readable regular non-symlinked file"
[ -r "$MODULE_SIGNING_KEY" ] ||
  die "controlled module-signing private key is not readable"
[ "$(file_link_count "$MODULE_SIGNING_KEY")" = "1" ] ||
  die "controlled module-signing private key must have exactly one filesystem link"
module_signing_key_mode="$(file_mode "$MODULE_SIGNING_KEY")" ||
  die "could not inspect controlled module-signing private key mode"
case "$module_signing_key_mode" in 400|600) ;; *) die "controlled module-signing private key mode must be 0400 or 0600" ;; esac
MODULE_SIGNING_CERTIFICATE_IDENTITY="$(regular_file_metadata_identity "$MODULE_SIGNING_CERTIFICATE")" ||
  die "controlled module-signing certificate must be a readable non-empty regular non-symlinked file"
[ -r "$MODULE_SIGNING_CERTIFICATE" ] ||
  die "controlled module-signing certificate is not readable"
[ "$(file_link_count "$MODULE_SIGNING_CERTIFICATE")" = "1" ] ||
  die "controlled module-signing certificate must have exactly one filesystem link"
module_signing_certificate_mode="$(file_mode "$MODULE_SIGNING_CERTIFICATE")" ||
  die "could not inspect controlled module-signing certificate mode"
[ $((8#$module_signing_certificate_mode & 8#22)) -eq 0 ] ||
  die "controlled module-signing certificate must not be group- or world-writable"
MODULE_SIGNING_PIN_IDENTITY="$(regular_file_metadata_identity "$MODULE_SIGNING_PIN_FILE")" ||
  die "controlled module-signing PIN file must be a non-empty readable regular non-symlinked file"
[ -r "$MODULE_SIGNING_PIN_FILE" ] ||
  die "controlled module-signing PIN file is not readable"
[ "$(file_link_count "$MODULE_SIGNING_PIN_FILE")" = "1" ] ||
  die "controlled module-signing PIN file must have exactly one filesystem link"
module_signing_pin_mode="$(file_mode "$MODULE_SIGNING_PIN_FILE")" ||
  die "could not inspect controlled module-signing PIN file mode"
case "$module_signing_pin_mode" in 400|600) ;; *) die "controlled module-signing PIN file mode must be 0400 or 0600" ;; esac
TRUSTED_OPENSSL="$(select_trusted_openssl)" ||
  die "fixed OpenSSL authority is unavailable for controlled module signing"
TRUSTED_OPENSSL_IDENTITY="$(regular_file_metadata_identity "$TRUSTED_OPENSSL")" ||
  die "could not bind the fixed OpenSSL authority"
[ -s "$module_signing_trust_anchor" ] && [ -f "$module_signing_trust_anchor" ] &&
  [ ! -L "$module_signing_trust_anchor" ] ||
  die "committed module-signing public trust anchor is unavailable"

SIGNING_TEMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
SIGNING_VALIDATION_DIR="$(mktemp -d "$SIGNING_TEMP_BASE/sp11-touchscreen-signing.XXXXXX")"
SIGNING_VALIDATION_DIR="$(cd "$SIGNING_VALIDATION_DIR" && pwd -P)"
chmod 0700 "$SIGNING_VALIDATION_DIR"
if ! "$TRUSTED_PYTHON" -I - "$MODULE_SIGNING_KEY" "$MODULE_SIGNING_CERTIFICATE" \
    "$MODULE_SIGNING_PIN_FILE" "$SIGNING_VALIDATION_DIR" 2>/dev/null <<'PY_VALIDATE_SIGNING_INPUTS'
import os
import re
import stat
import sys

key_path, certificate_path, pin_path, staging_path = sys.argv[1:]

def read_bounded(path, maximum):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        data = os.read(descriptor, maximum + 1)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
        value.st_uid,
        value.st_gid,
    )
    if not data or len(data) > maximum or len(data) != before.st_size:
        raise RuntimeError
    if stable(before) != stable(after) or stable(before) != stable(os.stat(path, follow_symlinks=False)):
        raise RuntimeError
    return data

key = read_bounded(key_path, 131072)
begin_key = b"-----BEGIN ENCRYPTED " + b"PRIVATE KEY-----"
end_key = b"-----END ENCRYPTED " + b"PRIVATE KEY-----"
key_lines = key.splitlines()
if (
    len(key_lines) < 3
    or key_lines[0] != begin_key
    or key_lines[-1] != end_key
    or not key.endswith(b"\n")
    or any(not re.fullmatch(rb"[A-Za-z0-9+/=]+", line) for line in key_lines[1:-1])
):
    raise RuntimeError

certificate = read_bounded(certificate_path, 131072)
certificate_lines = certificate.splitlines()
if (
    len(certificate_lines) < 3
    or certificate_lines[0] != b"-----BEGIN CERTIFICATE-----"
    or certificate_lines[-1] != b"-----END CERTIFICATE-----"
    or not certificate.endswith(b"\n")
    or any(
        not re.fullmatch(rb"[A-Za-z0-9+/=]+", line)
        for line in certificate_lines[1:-1]
    )
):
    raise RuntimeError

pin = read_bounded(pin_path, 4096)
if pin.endswith(b"\n"):
    pin = pin[:-1]
if not pin or b"\n" in pin or b"\r" in pin or any(byte < 0x20 or byte > 0x7E for byte in pin):
    raise RuntimeError

root_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
root = os.open(staging_path, root_flags)
try:
    root_metadata = os.fstat(root)
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
        or root_metadata.st_uid != os.geteuid()
        or root_metadata.st_nlink < 1
    ):
        raise RuntimeError

    def stage(name, data):
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        descriptor = os.open(name, flags, 0o400, dir_fd=root)
        try:
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                if written <= 0:
                    raise RuntimeError
                offset += written
            os.fchmod(descriptor, 0o400)
            os.fsync(descriptor)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != len(data):
                raise RuntimeError
        finally:
            os.close(descriptor)

    stage("private-key.pem", key)
    stage("certificate.pem", certificate)
    stage("pin", pin + b"\n")
finally:
    os.close(root)
PY_VALIDATE_SIGNING_INPUTS
then
  die "controlled module-signing inputs do not satisfy the encrypted-key, exact-certificate, and one-line-PIN contract"
fi
STAGED_MODULE_SIGNING_KEY="$SIGNING_VALIDATION_DIR/private-key.pem"
STAGED_MODULE_SIGNING_CERTIFICATE="$SIGNING_VALIDATION_DIR/certificate.pem"
STAGED_MODULE_SIGNING_PIN_FILE="$SIGNING_VALIDATION_DIR/pin"

verify_trusted_openssl ||
  die "fixed OpenSSL authority mapping changed before certificate validation"
if ! /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
    "$TRUSTED_OPENSSL" x509 -inform PEM -in "$STAGED_MODULE_SIGNING_CERTIFICATE" \
    -outform DER -out "$SIGNING_VALIDATION_DIR/provided-certificate.der" \
    >/dev/null 2>&1 ||
   ! /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
    "$TRUSTED_OPENSSL" x509 -inform PEM -in "$module_signing_trust_anchor" \
    -outform DER -out "$SIGNING_VALIDATION_DIR/trusted-certificate.der" \
    >/dev/null 2>&1; then
  die "controlled module-signing certificate conversion failed"
fi
verify_trusted_openssl ||
  die "fixed OpenSSL authority mapping changed during certificate validation"
cmp -s "$SIGNING_VALIDATION_DIR/provided-certificate.der" \
  "$SIGNING_VALIDATION_DIR/trusted-certificate.der" ||
  die "controlled module-signing certificate does not match the committed public trust anchor"
[ "$(sha256sum "$SIGNING_VALIDATION_DIR/trusted-certificate.der" | awk '{print $1}')" = \
  "$APPROVED_MODULE_SIGNING_CERT_SHA256" ] ||
  die "committed module-signing public trust anchor does not match the approved certificate identity"

IFS= read -r signing_pin < "$STAGED_MODULE_SIGNING_PIN_FILE" || [ -n "${signing_pin:-}" ]
verify_trusted_openssl ||
  die "fixed OpenSSL authority mapping changed before key validation"
if ! /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
    KBUILD_SIGN_PIN="$signing_pin" \
    "$TRUSTED_OPENSSL" pkey -in "$STAGED_MODULE_SIGNING_KEY" \
    -passin env:KBUILD_SIGN_PIN -pubout -outform DER \
    -out "$SIGNING_VALIDATION_DIR/private-key-public.der" >/dev/null 2>&1 ||
   ! /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
    "$TRUSTED_OPENSSL" x509 -inform DER \
    -in "$SIGNING_VALIDATION_DIR/trusted-certificate.der" -pubkey -noout \
    2>/dev/null | /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C \
    "$TRUSTED_OPENSSL" pkey -pubin -outform DER \
    -out "$SIGNING_VALIDATION_DIR/certificate-public.der" >/dev/null 2>&1; then
  unset signing_pin
  die "controlled module-signing private key or certificate public-key extraction failed"
fi
unset signing_pin
verify_trusted_openssl ||
  die "fixed OpenSSL authority mapping changed during key validation"
cmp -s "$SIGNING_VALIDATION_DIR/private-key-public.der" \
  "$SIGNING_VALIDATION_DIR/certificate-public.der" ||
  die "controlled module-signing private key does not match the committed certificate"
[ "$(regular_file_metadata_identity "$MODULE_SIGNING_KEY")" = "$MODULE_SIGNING_KEY_IDENTITY" ] &&
  [ "$(regular_file_metadata_identity "$MODULE_SIGNING_CERTIFICATE")" = "$MODULE_SIGNING_CERTIFICATE_IDENTITY" ] &&
  [ "$(regular_file_metadata_identity "$MODULE_SIGNING_PIN_FILE")" = "$MODULE_SIGNING_PIN_IDENTITY" ] ||
  die "controlled module-signing input identity changed during validation"

if [ -n "$KERNEL_COMMON_HEADERS_DEB" ] || [ -n "$KERNEL_HEADERS_DEB" ]; then
  [ -n "$KERNEL_COMMON_HEADERS_DEB" ] && [ -n "$KERNEL_HEADERS_DEB" ] ||
    die "supply --kernel-common-headers-deb and --kernel-headers-deb together"
  [ -z "$KERNEL_BUILD_DIR" ] ||
    die "release header Debs cannot be combined with --kernel-build-dir; the Debs are extracted into a pristine build tree"
  require_tool dpkg-deb
  require_tool find
  require_tool mktemp
  require_tool readlink
  for headers_deb in "$KERNEL_COMMON_HEADERS_DEB" "$KERNEL_HEADERS_DEB"; do
    [ -s "$headers_deb" ] && [ -f "$headers_deb" ] && [ ! -L "$headers_deb" ] ||
      die "kernel headers Deb must be a non-empty regular, non-symlinked file: $headers_deb"
  done
  kernel_common_headers_deb_name="$(basename "$KERNEL_COMMON_HEADERS_DEB")"
  kernel_headers_deb_name="$(basename "$KERNEL_HEADERS_DEB")"
  case "$kernel_common_headers_deb_name" in
    linux-qcom-x1e-headers-"${RELEASE%-qcom-x1e}"_*_all.deb) ;;
    *) die "common headers Deb does not match target ABI $RELEASE: $kernel_common_headers_deb_name" ;;
  esac
  case "$kernel_headers_deb_name" in
    linux-headers-"$RELEASE"_*_arm64.deb) ;;
    *) die "architecture headers Deb does not match target ABI $RELEASE: $kernel_headers_deb_name" ;;
  esac
  common_headers_without_arch="${kernel_common_headers_deb_name%_all.deb}"
  architecture_headers_without_arch="${kernel_headers_deb_name%_arm64.deb}"
  common_headers_version="${common_headers_without_arch##*_}"
  architecture_headers_version="${architecture_headers_without_arch##*_}"
  [ -n "$common_headers_version" ] &&
    [ "$common_headers_version" = "$architecture_headers_version" ] ||
    die "kernel header Deb package versions do not match"
  kernel_common_headers_deb_sha256="$(sha256sum "$KERNEL_COMMON_HEADERS_DEB" | awk '{print $1}')"
  kernel_headers_deb_sha256="$(sha256sum "$KERNEL_HEADERS_DEB" | awk '{print $1}')"
  kernel_headers_input_mode="extracted-debs-v1"

  KERNEL_HEADERS_TEMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  KERNEL_HEADERS_EXTRACT_DIR="$(mktemp -d "$KERNEL_HEADERS_TEMP_BASE/sp11-touchscreen-headers.XXXXXX")"
  KERNEL_HEADERS_EXTRACT_DIR="$(cd "$KERNEL_HEADERS_EXTRACT_DIR" && pwd -P)"
  chmod 0700 "$KERNEL_HEADERS_EXTRACT_DIR"
  common_extract_root="$KERNEL_HEADERS_EXTRACT_DIR/common-package"
  architecture_extract_root="$KERNEL_HEADERS_EXTRACT_DIR/architecture-package"
  merged_headers_root="$KERNEL_HEADERS_EXTRACT_DIR/merged"
  mkdir -p "$common_extract_root" "$architecture_extract_root" "$merged_headers_root/usr/src"
  chmod 0700 "$common_extract_root" "$architecture_extract_root" "$merged_headers_root"
  common_source_dir_name="linux-qcom-x1e-headers-${RELEASE%-qcom-x1e}"
  architecture_source_dir_name="linux-headers-$RELEASE"

  # Never overlay one untrusted package extraction on another. Validate and
  # select only each package's exact consumed usr/src tree, then move those two
  # directories into a newly created private root. The architecture package's
  # intentional absolute usr/lib/modules/.../build link is not consumed.
  dpkg-deb -x "$KERNEL_COMMON_HEADERS_DEB" "$common_extract_root"
  require_single_header_source_root \
    "$common_extract_root" "$common_source_dir_name" "common headers Deb"
  validate_extracted_header_root "$common_extract_root" "common headers Deb"
  dpkg-deb -x "$KERNEL_HEADERS_DEB" "$architecture_extract_root"
  require_single_header_source_root \
    "$architecture_extract_root" "$architecture_source_dir_name" "architecture headers Deb"
  if find "$architecture_extract_root/usr/src/$architecture_source_dir_name" \
      ! -type f ! -type d ! -type l -print -quit | grep -q .; then
    die "extracted architecture headers Deb contains a special consumed filesystem entry"
  fi
  mv "$common_extract_root/usr/src/$common_source_dir_name" \
    "$merged_headers_root/usr/src/$common_source_dir_name"
  mv "$architecture_extract_root/usr/src/$architecture_source_dir_name" \
    "$merged_headers_root/usr/src/$architecture_source_dir_name"
  [ "$(sha256sum "$KERNEL_COMMON_HEADERS_DEB" | awk '{print $1}')" = "$kernel_common_headers_deb_sha256" ] &&
    [ "$(sha256sum "$KERNEL_HEADERS_DEB" | awk '{print $1}')" = "$kernel_headers_deb_sha256" ] ||
    die "kernel header Deb changed while its pristine build tree was extracted"

  validate_extracted_header_root "$merged_headers_root" "kernel header packages"

  extracted_kdir="$merged_headers_root/usr/src/linux-headers-$RELEASE"
  [ -d "$extracted_kdir" ] && [ ! -L "$extracted_kdir" ] ||
    die "architecture headers Deb does not provide usr/src/linux-headers-$RELEASE"
  KDIR="$(cd "$extracted_kdir" && pwd -P)"
  case "$KDIR" in
    "$merged_headers_root"/*) ;;
    *) die "extracted kernel build tree resolves outside its pristine root" ;;
  esac
else
  kernel_common_headers_deb_name="not specified"
  kernel_headers_deb_name="not specified"
  kernel_common_headers_deb_sha256="not specified"
  kernel_headers_deb_sha256="not specified"
  kernel_headers_input_mode="local-kdir-unbound"
  KVER_DIR="/lib/modules/$RELEASE"
  if [ -n "$KERNEL_BUILD_DIR" ]; then
    [ -d "$KERNEL_BUILD_DIR" ] || die "kernel build directory not found: $KERNEL_BUILD_DIR"
    KDIR="$(cd "$KERNEL_BUILD_DIR" && pwd -P)"
  else
    KDIR="$KVER_DIR/build"
  fi
fi

[ -d "$KDIR" ] || die "no headers found at $KDIR; install linux-headers-$RELEASE"
[ -s "$KDIR/Module.symvers" ] || die "missing or empty $KDIR/Module.symvers"
[ -r "$KDIR/include/config/kernel.release" ] || die "missing $KDIR/include/config/kernel.release"
header_release="$(<"$KDIR/include/config/kernel.release")"
[ "$header_release" = "$RELEASE" ] || die "header tree is for $header_release, not $RELEASE"

config=""
if [ "$kernel_headers_input_mode" = "extracted-debs-v1" ]; then
  [ -r "$KDIR/.config" ] && config="$KDIR/.config"
else
  for candidate in "$KDIR/.config" "/boot/config-$RELEASE"; do
    if [ -r "$candidate" ]; then
      config="$candidate"
      break
    fi
  done
fi
[ -n "$config" ] || die "cannot find the exact kernel configuration for $RELEASE"
grep -qx 'CONFIG_MODULES=y' "$config" || die "CONFIG_MODULES is not enabled for $RELEASE"
grep -qx 'CONFIG_QCOM_GPI_DMA=m' "$config" || die "CONFIG_QCOM_GPI_DMA must be a replaceable module"
grep -qx 'CONFIG_SPI_QCOM_GENI=m' "$config" || die "CONFIG_SPI_QCOM_GENI must be a replaceable module"
grep -qx 'CONFIG_MODULE_SIG=y' "$config" || die "CONFIG_MODULE_SIG is not enabled for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_SHA512=y' "$config" || die "CONFIG_MODULE_SIG_SHA512 is not enabled for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_HASH="sha512"' "$config" || die "CONFIG_MODULE_SIG_HASH is not sha512 for $RELEASE"
grep -qx 'CONFIG_MODULE_SIG_KEY_TYPE_RSA=y' "$config" || die "CONFIG_MODULE_SIG_KEY_TYPE_RSA is not enabled for $RELEASE"
sign_file="$KDIR/scripts/sign-file"
[ -s "$sign_file" ] && [ -f "$sign_file" ] && [ ! -L "$sign_file" ] && [ -x "$sign_file" ] ||
  die "kernel header tree lacks a regular executable scripts/sign-file"

resolve_source_path
resolve_output_path

new_checkout="false"
if [ -e "$SOURCE_DIR" ] || [ -L "$SOURCE_DIR" ]; then
  validate_source_git_binding
  validate_source_local_git_config
else
  [ "$OFFLINE" != "true" ] || die "offline source checkout not found: $SOURCE_DIR"
  source_git clone --filter=blob:none --no-checkout "$GIT_URL" "$SOURCE_DIR"
  new_checkout="true"
  [ -d "$SOURCE_DIR" ] && [ ! -L "$SOURCE_DIR" ] &&
    [ "$(cd "$SOURCE_DIR" && pwd -P)" = "$SOURCE_DIR" ] ||
    die "new source checkout did not remain at its approved physical path"
  validate_source_git_binding
  validate_source_local_git_config
fi

if ! actual_origin="$(source_git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null)"; then
  die "could not resolve the source checkout origin: $SOURCE_DIR"
fi
[ "$actual_origin" = "$GIT_URL" ] || die "source origin is $actual_origin, expected $GIT_URL"
if ! source_status="$(source_git -C "$SOURCE_DIR" status --porcelain --untracked-files=all --ignored)"; then
  die "could not inspect the source checkout state: $SOURCE_DIR"
fi
if [ "$new_checkout" != "true" ] && [ -n "$source_status" ]; then
  die "source checkout has modified, untracked, or ignored content; use a pristine checkout: $SOURCE_DIR"
fi

if [ "$OFFLINE" = "true" ]; then
  source_commit="$(source_git -C "$SOURCE_DIR" rev-parse --verify "$GIT_REF^{commit}" 2>/dev/null || true)"
  [ -n "$source_commit" ] || die "source ref $GIT_REF is unavailable in offline checkout"
else
  source_git -C "$SOURCE_DIR" fetch --depth 1 origin "$GIT_REF"
  source_commit="$(source_git -C "$SOURCE_DIR" rev-parse --verify 'FETCH_HEAD^{commit}')"
fi
[ "$source_commit" = "$GIT_REF" ] || die "resolved source commit $source_commit does not match $GIT_REF"
validate_source_git_binding
validate_source_local_git_config
source_git -C "$SOURCE_DIR" checkout --detach "$source_commit"
validate_source_git_binding
validate_source_local_git_config
if ! source_status="$(source_git -C "$SOURCE_DIR" status --porcelain --untracked-files=all --ignored)"; then
  die "could not inspect the source checkout state after selecting $source_commit"
fi
if [ -n "$source_status" ]; then
  die "source checkout is not pristine after selecting $source_commit"
fi

module_source="$SOURCE_DIR/phase55/modules"
[ -d "$SOURCE_DIR/phase55" ] && [ ! -L "$SOURCE_DIR/phase55" ] &&
  [ -d "$module_source" ] && [ ! -L "$module_source" ] &&
  [ "$(cd "$module_source" && pwd -P)" = "$module_source" ] ||
  die "pinned module source is not a physical directory inside the managed checkout"
[ -f "$module_source/Makefile" ] && [ ! -L "$module_source/Makefile" ] ||
  die "pinned source lacks a regular $module_source/Makefile"
source_object_format="$(source_git -C "$SOURCE_DIR" rev-parse --show-object-format 2>/dev/null || true)"
case "$source_object_format" in
  sha1|sha256) ;;
  *) die "could not determine the source repository Git object format" ;;
esac
source_modules_tree="$(source_git -C "$SOURCE_DIR" rev-parse --verify "$source_commit:phase55/modules" 2>/dev/null || true)"
[[ "$source_modules_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] || \
  die "could not resolve the exact phase55/modules tree at $source_commit"
source_license_entry="$(source_git -C "$SOURCE_DIR" ls-tree "$source_commit" -- LICENSE)"
source_license_mode="$(printf '%s\n' "$source_license_entry" | awk '{print $1}')"
source_license_type="$(printf '%s\n' "$source_license_entry" | awk '{print $2}')"
source_license_blob="$(printf '%s\n' "$source_license_entry" | awk '{print $3}')"
[ "$source_license_mode" = "100644" ] && [ "$source_license_type" = "blob" ] && \
  [[ "$source_license_blob" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] || \
  die "could not bind the exact LICENSE blob at $source_commit"

source_subset_identity() {
  local path mode content_sha
  (
    cd "$SOURCE_DIR"
    source_git ls-tree -r --name-only "$source_commit" -- LICENSE phase55/modules |
      while IFS= read -r path; do
        case "$path" in
          LICENSE|phase55/modules/*) ;;
          *) die "source commit contains an unsafe required-source path: $path" ;;
        esac
        mode="$(source_git ls-tree "$source_commit" -- "$path" | awk '{print $1}')"
        if [ -L "$path" ]; then
          content_sha="$(readlink "$path" | sha256sum | awk '{print $1}')"
        elif [ -f "$path" ]; then
          content_sha="$(sha256sum "$path" | awk '{print $1}')"
        else
          die "required source path disappeared: $path"
        fi
        printf '%s  %s  %s\n' "$mode" "$content_sha" "$path"
      done
  ) | sha256sum | awk '{print $1}'
}
if ! source_subset_identity_before="$(source_subset_identity)"; then
  die "could not capture the exact pre-build source subset identity"
fi

kernel_config_sha256="$(sha256sum "$config" | awk '{print $1}')"
kernel_module_symvers_sha256="$(sha256sum "$KDIR/Module.symvers" | awk '{print $1}')"
module_cc="${CC:-gcc}"
module_ld="${LD:-ld}"
case "$module_cc$module_ld" in
  *[[:space:]]*) die "CC and LD must each name one executable without shell arguments" ;;
esac
require_tool "$module_cc"
require_tool "$module_ld"
module_compiler_identity="$($module_cc --version | sed -n '1p')"
module_linker_identity="$($module_ld --version | sed -n '1p')"
module_make_identity="$(make --version | sed -n '1p')"
[ -n "$module_compiler_identity" ] && [ -n "$module_linker_identity" ] && \
  [ -n "$module_make_identity" ] || die "could not record the module toolchain identity"

# Phase 91's Makefile guard names its original 7.1.3 validation kernel. We
# supply and independently verify the exact target release here; the guarded
# installer performs the runtime and initramfs checks before declaring success.
make -C "$module_source" \
  KDIR="$KDIR" \
  CC="$module_cc" \
  LD="$module_ld" \
  EXPECTED_KERNEL_RELEASE="$RELEASE" \
  ALLOW_UNTESTED_KERNEL=1

if ! source_head_after="$(source_git -C "$SOURCE_DIR" rev-parse --verify 'HEAD^{commit}')"; then
  die "could not re-resolve the source commit after the module build"
fi
[ "$source_head_after" = "$source_commit" ] || die "source HEAD changed during the module build"
validate_source_git_binding
validate_source_local_git_config
[ -d "$module_source" ] && [ ! -L "$module_source" ] &&
  [ "$(cd "$module_source" && pwd -P)" = "$module_source" ] ||
  die "module source path changed during the module build"
if ! source_status_after="$(source_git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)"; then
  die "could not inspect the source checkout after the module build"
fi
[ -z "$source_status_after" ] || die "tracked or untracked source input changed during the module build"
if ! source_subset_identity_after="$(source_subset_identity)"; then
  die "could not capture the exact post-build source subset identity"
fi
[ "$source_subset_identity_after" = "$source_subset_identity_before" ] ||
  die "required source input changed during the module build"
[ "$(sha256sum "$config" | awk '{print $1}')" = "$kernel_config_sha256" ] ||
  die "kernel configuration changed during the module build"
[ "$(sha256sum "$KDIR/Module.symvers" | awk '{print $1}')" = "$kernel_module_symvers_sha256" ] ||
  die "kernel Module.symvers changed during the module build"
if [ -n "$KERNEL_COMMON_HEADERS_DEB" ]; then
  [ "$(sha256sum "$KERNEL_COMMON_HEADERS_DEB" | awk '{print $1}')" = "$kernel_common_headers_deb_sha256" ] &&
    [ "$(sha256sum "$KERNEL_HEADERS_DEB" | awk '{print $1}')" = "$kernel_headers_deb_sha256" ] ||
    die "kernel header Deb changed during the module build"
fi

OUTPUT_STAGE_DIR="$(mktemp -d "$OUT_PARENT_ABS/.sp11-touchscreen-stage.XXXXXX")"
OUTPUT_STAGE_DIR="$(cd "$OUTPUT_STAGE_DIR" && pwd -P)"
chmod 0700 "$OUTPUT_STAGE_DIR"
module_signing_certificate_sha256="$(sha256sum "$SIGNING_VALIDATION_DIR/trusted-certificate.der" | awk '{print $1}')"
install -m 0644 "$SIGNING_VALIDATION_DIR/trusted-certificate.der" \
  "$OUTPUT_STAGE_DIR/sp11-module-signing-cert.x509"
[ "$(sha256sum "$OUTPUT_STAGE_DIR/sp11-module-signing-cert.x509" | awk '{print $1}')" = \
  "$module_signing_certificate_sha256" ] ||
  die "public module-signing certificate changed while entering the private stage"
IFS= read -r signing_pin < "$STAGED_MODULE_SIGNING_PIN_FILE" || [ -n "${signing_pin:-}" ]
signing_failed="false"
for module in gpi spi-geni-qcom mshw0485_touch; do
  built="$module_source/$module.ko"
  [ -s "$built" ] && [ -f "$built" ] && [ ! -L "$built" ] ||
    die "build did not produce a non-empty regular module: $built"
  built_sha256="$(sha256sum "$built" | awk '{print $1}')"
  if ! KBUILD_SIGN_PIN="$signing_pin" "$sign_file" sha512 \
      "$STAGED_MODULE_SIGNING_KEY" \
      "$OUTPUT_STAGE_DIR/sp11-module-signing-cert.x509" \
      "$built" "$OUTPUT_STAGE_DIR/$module.ko" >/dev/null 2>&1; then
    signing_failed="true"
    break
  fi
  [ "$(sha256sum "$built" | awk '{print $1}')" = "$built_sha256" ] ||
    die "$module.ko changed while it was signed"
  chmod 0644 "$OUTPUT_STAGE_DIR/$module.ko"
done
unset signing_pin
[ "$signing_failed" = "false" ] || die "controlled module signing failed"
[ "$(regular_file_metadata_identity "$MODULE_SIGNING_KEY")" = "$MODULE_SIGNING_KEY_IDENTITY" ] ||
  die "controlled module-signing private key identity changed during signing"
[ "$(regular_file_metadata_identity "$MODULE_SIGNING_CERTIFICATE")" = "$MODULE_SIGNING_CERTIFICATE_IDENTITY" ] &&
  [ "$(regular_file_metadata_identity "$MODULE_SIGNING_PIN_FILE")" = "$MODULE_SIGNING_PIN_IDENTITY" ] ||
  die "controlled module-signing public certificate or PIN-file identity changed during signing"
[ "$(sha256sum "$SIGNING_VALIDATION_DIR/trusted-certificate.der" | awk '{print $1}')" = \
  "$module_signing_certificate_sha256" ] ||
  die "validated public module-signing certificate changed during signing"

validate_module_identities "$OUTPUT_STAGE_DIR"
if ! signature_report="$(
  "$TRUSTED_PYTHON" -I "$signed_module_validator" \
    --certificate "$OUTPUT_STAGE_DIR/sp11-module-signing-cert.x509" \
    --module "$OUTPUT_STAGE_DIR/gpi.ko" \
    --module "$OUTPUT_STAGE_DIR/spi-geni-qcom.ko" \
    --module "$OUTPUT_STAGE_DIR/mshw0485_touch.ko"
)"; then
  die "controlled touchscreen module signature validation failed"
fi

manifest="$OUTPUT_STAGE_DIR/sp11-touchscreen-modules-manifest.txt"
{
  echo "# Surface Pro 11 Touchscreen Module Build Manifest"
  echo
  echo "Source URL: $GIT_URL"
  echo "Source ref: $GIT_REF"
  echo "Source commit: $source_commit"
  echo "Source archive contract: sp11-touchscreen-source-v1"
  echo "Source object format: $source_object_format"
  echo "Source modules path: phase55/modules"
  echo "Source modules tree ID: $source_modules_tree"
  echo "Source license path: LICENSE"
  echo "Source license mode: $source_license_mode"
  echo "Source license blob ID: $source_license_blob"
  echo "Target release: $RELEASE"
  echo "Kernel config SHA256: $kernel_config_sha256"
  echo "Kernel Module.symvers SHA256: $kernel_module_symvers_sha256"
  echo "Kernel headers input mode: $kernel_headers_input_mode"
  echo "Kernel common headers Deb: $kernel_common_headers_deb_name"
  echo "Kernel common headers Deb SHA256: $kernel_common_headers_deb_sha256"
  echo "Kernel architecture headers Deb: $kernel_headers_deb_name"
  echo "Kernel architecture headers Deb SHA256: $kernel_headers_deb_sha256"
  echo "Module compiler identity: $module_compiler_identity"
  echo "Module linker identity: $module_linker_identity"
  echo "Module make identity: $module_make_identity"
  printf '%s\n' "$signature_report"
  echo
  echo "## Modules"
  for module in gpi spi-geni-qcom mshw0485_touch; do
    file="$OUTPUT_STAGE_DIR/$module.ko"
    echo
    echo "- $module.ko"
    echo "  - Name: $(modinfo -F name "$file")"
    echo "  - Srcversion: $(modinfo -F srcversion "$file")"
    echo "  - Vermagic: $(modinfo -F vermagic "$file")"
    echo "  - SHA256: $(sha256sum "$file" | awk '{print $1}')"
  done
} > "$manifest"
chmod 0644 "$manifest"

validate_output_leaves "$OUTPUT_STAGE_DIR" true
validate_signed_bundle "$OUTPUT_STAGE_DIR"
if [ "$INSTALL" = "true" ]; then
  prepare_install_snapshot
fi
publish_output_stage

echo "Built and verified touchscreen modules for $RELEASE in $OUT_ABS/."
echo "Pinned source commit: $source_commit"

if [ "$INSTALL" = "true" ]; then
  installer="$repo_dir/scripts/install-sp11-touchscreen.sh"
  [ -x "$installer" ] || die "missing guarded installer: $installer"
  [ -d "$INSTALL_SNAPSHOT_DIR" ] && [ ! -L "$INSTALL_SNAPSHOT_DIR" ] &&
    [ "$(cd "$INSTALL_SNAPSHOT_DIR" && pwd -P)" = "$INSTALL_SNAPSHOT_DIR" ] ||
    die "private install snapshot changed before guarded installation"
  validate_output_leaves "$INSTALL_SNAPSHOT_DIR" true 400
  validate_module_identities "$INSTALL_SNAPSHOT_DIR"
  [ "$(file_mode "$INSTALL_SNAPSHOT_DIR")" = "500" ] ||
    die "private install snapshot directory mode changed before installation"
  install_args=(--modules-dir "$INSTALL_SNAPSHOT_DIR" --release "$RELEASE")
  if [ "$WINDOWS_SE_INIT" = "true" ]; then
    install_args+=(--windows-se-init)
  fi
  if [ "$(id -u)" -eq 0 ]; then
    "$installer" "${install_args[@]}"
  else
    require_tool sudo
    sudo "$installer" "${install_args[@]}"
  fi
fi
