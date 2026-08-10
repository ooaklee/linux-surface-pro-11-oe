#!/usr/bin/env bash
set -uo pipefail

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

RELEASE_DIR=""
TAG=""
REMOTE=""
ERROR_COUNT=0
CHECK_COUNT=0
TEMP_DIRS=()
RELEASE_ROOT_FD=52
RELEASE_ROOT_STATE=""
LOCAL_PREPARED_CANDIDATE="false"
DOWNLOADED_RELEASE="false"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SIGNED_MODULE_VALIDATOR="$REPO_DIR/scripts/validate-sp11-signed-modules.py"
KERNEL_MODULE_SIGNATURE_VALIDATOR="$REPO_DIR/scripts/validate-sp11-module-signatures.py"
KERNEL_MODULE_SIGNING_CERTIFICATE="$REPO_DIR/config/kernel-signing/sp11-module-signing-cert.pem"
KERNEL_MODULE_UNSIGNED_ALLOWLIST="$REPO_DIR/config/kernel-signing/sp11-module-signing-allowed-unsigned.txt"

usage() {
  cat <<EOF
Usage: $0 --dir DIR (--local-prepared-candidate | --downloaded-release)
          [--tag TAG] [--remote REMOTE]

Validates a local-prepared or downloaded Surface Pro 11 qcom-x1e kernel
release directory without changing it.  The authority mode is mandatory.

Options:
  --dir DIR        Flat directory containing the release assets (required).
  --tag TAG        Compare the manifest support commit with this Git tag.
  --remote REMOTE  Also compare with TAG on this Git remote name or URL.
                   Requires --tag.
  --local-prepared-candidate
                   Require the held local preparer commit marker (mode 0500).
                   Do not use for downloaded release directories.
  --downloaded-release
                   Validate transported release bytes without claiming local
                   preparer transaction or publication authority.
  -h, --help       Show this help.
EOF
}

error() {
  echo "ERROR: $*" >&2
  ERROR_COUNT=$((ERROR_COUNT + 1))
}

checked() {
  CHECK_COUNT=$((CHECK_COUNT + 1))
}

die() {
  error "$*"
  exit 1
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

committed_release_root_state() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

descriptor = os.open(
    sys.argv[1],
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
)
try:
    held = os.fstat(descriptor)
    mapped = os.stat(sys.argv[1], follow_symlinks=False)
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
    if (
        not stat.S_ISDIR(held.st_mode)
        or stat.S_IMODE(held.st_mode) != 0o500
        or stable(held) != stable(mapped)
    ):
        raise RuntimeError
    print(*stable(held))
finally:
    os.close(descriptor)
' "$1"
}

verify_committed_release_root() {
  /usr/bin/python3 -I -c '
import os
import stat
import sys

expected = tuple(int(value, 10) for value in sys.argv[3:12])
held = os.fstat(int(sys.argv[1], 10))
mapped = os.stat(sys.argv[2], follow_symlinks=False)
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
if (
    not stat.S_ISDIR(held.st_mode)
    or stat.S_IMODE(held.st_mode) != 0o500
    or stable(held) != expected
    or stable(mapped) != expected
):
    raise SystemExit(1)
' "$RELEASE_ROOT_FD" "$RELEASE_DIR" $RELEASE_ROOT_STATE
}

cleanup() {
  local path
  for path in "${TEMP_DIRS[@]-}"; do
    if [ -n "$path" ] && [ -d "$path" ]; then
      rm -rf -- "$path"
    fi
  done
}
trap cleanup EXIT HUP INT TERM

sha256_file() {
  local path="$1"
  if have_tool sha256sum; then
    sha256sum -- "$path" | awk '{print $1}'
  elif have_tool shasum; then
    shasum -a 256 -- "$path" | awk '{print $1}'
  else
    return 127
  fi
}

manifest_values() {
  local file="$1"
  local label="$2"
  awk -v prefix="$label: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' "$file"
}

single_manifest_value() {
  local file="$1"
  local label="$2"
  local values=()
  local value

  while IFS= read -r value; do
    values+=("$value")
  done < <(manifest_values "$file" "$label")

  if [ "${#values[@]}" -ne 1 ] || [ -z "${values[0]:-}" ]; then
    return 1
  fi
  printf '%s\n' "${values[0]}"
}

validate_controlled_kernel_module_report() {
  local transported_report temporary report_out scanner_stdout
  local package_arguments=()

  transported_report="$RELEASE_DIR/sp11-kernel-module-signatures.txt"
  for helper in \
    "$KERNEL_MODULE_SIGNATURE_VALIDATOR" \
    "$KERNEL_MODULE_SIGNING_CERTIFICATE" \
    "$KERNEL_MODULE_UNSIGNED_ALLOWLIST"; do
    if [ ! -f "$helper" ] || [ -L "$helper" ]; then
      error "controlled kernel module signature authority is unavailable: $(basename "$helper")"
      return
    fi
  done
  if [ ! -x /usr/bin/python3 ] || [ ! -x /usr/bin/cmp ] ||
     [ ! -x /usr/bin/mktemp ] || [ ! -x /bin/chmod ]; then
    error "trusted system Python, cmp, mktemp, and chmod are required for controlled kernel module signature validation."
    return
  fi
  if [ ! -f "$transported_report" ] || [ -L "$transported_report" ]; then
    error "schema-v2 release is missing its regular kernel module signature report."
    return
  fi
  if [ "${ROLE_COUNTS[modules]}" -ne 1 ]; then
    error "controlled kernel module signature validation requires the exact modules package."
    return
  fi
  package_arguments+=("${ROLE_FILES[modules]}")
  if [ "${ROLE_COUNTS[modules_extra]}" -eq 1 ]; then
    package_arguments+=("${ROLE_FILES[modules_extra]}")
  fi

  temporary="$(/usr/bin/mktemp -d 2>/dev/null || true)"
  if [ -z "$temporary" ] || [ ! -d "$temporary" ]; then
    error "could not create a private kernel module signature validation directory."
    return
  fi
  TEMP_DIRS+=("$temporary")
  /bin/chmod 0700 "$temporary" 2>/dev/null || {
    error "could not protect the kernel module signature validation directory."
    return
  }
  report_out="$temporary/sp11-kernel-module-signatures.txt"
  scanner_stdout="$temporary/scanner.stdout"
  if ! /usr/bin/python3 -I "$KERNEL_MODULE_SIGNATURE_VALIDATOR" \
      --controlled-certificate "$KERNEL_MODULE_SIGNING_CERTIFICATE" \
      --allowed-unsigned-file "$KERNEL_MODULE_UNSIGNED_ALLOWLIST" \
      --report-out "$report_out" \
      "${package_arguments[@]}" > "$scanner_stdout"; then
    error "release kernel module packages failed controlled cryptographic signature validation."
    return
  fi
  if [ -s "$scanner_stdout" ]; then
    error "controlled kernel module signature scanner emitted unexpected stdout."
    return
  fi
  if [ ! -f "$report_out" ] || [ -L "$report_out" ]; then
    error "controlled kernel module signature scanner did not publish its private report."
    return
  fi
  if ! /usr/bin/cmp -s -- "$report_out" "$transported_report"; then
    error "transported kernel module signature report differs from live package cryptographic verification."
    return
  fi
  checked
}

validate_schema_v2_touchscreen_bindings() {
  local repo_dir validator archive_validator identity_validator build_manifest apt_provenance build_inputs
  local kernel_archive_name touch_archive_name kernel_archive touch_archive
  local patched_tree touch_tree touch_license touch_commit touch_license_mode
  local binding_dir expected_payload actual_payload asset asset_name asset_sha

  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
  archive_validator="$repo_dir/scripts/validate-sp11-source-archive.py"
  identity_validator="$repo_dir/scripts/validate-sp11-payload-identity-list.sh"
  build_manifest="$RELEASE_DIR/sp11-kernel-build-manifest.txt"
  apt_provenance="$RELEASE_DIR/sp11-kernel-apt-provenance.txt"
  build_inputs="$RELEASE_DIR/sp11-kernel-build-inputs.txt"
  for helper in "$validator" "$archive_validator" "$identity_validator"; do
    if [ ! -f "$helper" ] || [ -L "$helper" ]; then
      error "schema-v2 release validator is missing: $(basename "$helper")"
      return
    fi
  done
  if ! have_tool python3; then
    error "python3 is required for complete schema-v2 release validation."
    return
  fi

  kernel_archive_name="$(single_manifest_value "$release_manifest" "Kernel source archive" 2>/dev/null || true)"
  touch_archive_name="$(single_manifest_value "$release_manifest" "Touchscreen source archive" 2>/dev/null || true)"
  case "$kernel_archive_name" in
    ""|.|..|*/*|*[!A-Za-z0-9._+-]*)
      error "schema-v2 release manifest has missing or unsafe source-archive names."
      return
      ;;
  esac
  case "$touch_archive_name" in
    ""|.|..|*/*|*[!A-Za-z0-9._+-]*)
      error "schema-v2 release manifest has missing or unsafe source-archive names."
      return
      ;;
  esac
  kernel_archive="$RELEASE_DIR/$kernel_archive_name"
  touch_archive="$RELEASE_DIR/$touch_archive_name"
  if [ ! -f "$kernel_archive" ] || [ -L "$kernel_archive" ] ||
     [ ! -f "$touch_archive" ] || [ -L "$touch_archive" ]; then
    error "schema-v2 release is missing a regular corresponding-source archive."
    return
  fi

  patched_tree="$(single_manifest_value "$release_manifest" "Kernel source tree ID" 2>/dev/null || true)"
  touch_commit="$(single_manifest_value "$release_manifest" "Touchscreen source commit" 2>/dev/null || true)"
  touch_tree="$(single_manifest_value "$release_manifest" "Touchscreen source modules tree ID" 2>/dev/null || true)"
  touch_license="$(single_manifest_value "$release_manifest" "Touchscreen source license blob ID" 2>/dev/null || true)"
  touch_license_mode="$(single_manifest_value "$touchscreen_manifest" "Source license mode" 2>/dev/null || true)"
  if ! [[ "$patched_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
     ! [[ "$touch_commit" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
     ! [[ "$touch_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
     ! [[ "$touch_license" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]] ||
     [ "$touch_license_mode" != "100644" ]; then
    error "schema-v2 release has incomplete source object identities."
    return
  fi

  binding_dir="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$binding_dir" ] || [ ! -d "$binding_dir" ]; then
    error "could not create a temporary schema-v2 binding directory."
    return
  fi
  TEMP_DIRS+=("$binding_dir")
  expected_payload="$binding_dir/expected-payload"
  actual_payload="$binding_dir/actual-payload"
  if ! python3 -I "$validator" \
      --repo-dir "$repo_dir" \
      --support-commit "$support_commit" \
      --release-name "$manifest_release" \
      --kernel-build-manifest "$build_manifest" \
      --kernel-release-manifest "$release_manifest" \
      --apt-provenance "$apt_provenance" \
      --build-inputs "$build_inputs" \
      --touchscreen-module-manifest "$touchscreen_manifest" \
      --kernel-source "$kernel_archive" \
      --touchscreen-source "$touch_archive" \
      --expected-payload-out "$expected_payload" >/dev/null; then
    error "schema-v2 release manifests and source assets failed complete cross-binding validation."
    return
  fi
  if ! python3 -I "$archive_validator" kernel \
      --archive "$kernel_archive" --expected-tree "$patched_tree" >/dev/null ||
     ! python3 -I "$archive_validator" touchscreen \
      --archive "$touch_archive" \
      --expected-modules-tree "$touch_tree" \
      --expected-license-blob "$touch_license" \
      --license-mode "$touch_license_mode" \
      --expected-archive-comment "$touch_commit" >/dev/null; then
    error "schema-v2 corresponding-source archives do not match their Git object identities."
    return
  fi

  : > "$actual_payload"
  for asset in "${deb_files[@]}" \
    "$RELEASE_DIR/gpi.ko" \
    "$RELEASE_DIR/spi-geni-qcom.ko" \
    "$RELEASE_DIR/mshw0485_touch.ko" \
    "$RELEASE_DIR/sp11-module-signing-cert.x509" \
    "$touchscreen_manifest"; do
    if [ ! -f "$asset" ] || [ -L "$asset" ]; then
      error "schema-v2 payload binding input is missing: $(basename "$asset")"
      return
    fi
    asset_name="$(basename "$asset")"
    asset_sha="$(sha256_file "$asset" 2>/dev/null || true)"
    if [[ ! "$asset_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
      error "could not hash schema-v2 payload binding input: $asset_name"
      return
    fi
    printf '%s  %s\n' "${asset_sha,,}" "$asset_name" >> "$actual_payload"
  done
  if ! "$identity_validator" --expected "$expected_payload" --actual "$actual_payload" \
      >/dev/null; then
    error "schema-v2 release binary payload differs from its bound manifests."
    return
  fi
  checked
}

validate_schema_v2_kernel_bindings() {
  local repo_dir validator archive_validator identity_validator build_manifest apt_provenance build_inputs
  local kernel_archive_name kernel_archive patched_tree binding_dir
  local expected_payload actual_payload asset asset_name asset_sha

  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  validator="$repo_dir/scripts/validate-sp11-image-release-manifests.py"
  archive_validator="$repo_dir/scripts/validate-sp11-source-archive.py"
  identity_validator="$repo_dir/scripts/validate-sp11-payload-identity-list.sh"
  build_manifest="$RELEASE_DIR/sp11-kernel-build-manifest.txt"
  apt_provenance="$RELEASE_DIR/sp11-kernel-apt-provenance.txt"
  build_inputs="$RELEASE_DIR/sp11-kernel-build-inputs.txt"
  for helper in "$validator" "$archive_validator" "$identity_validator"; do
    if [ ! -f "$helper" ] || [ -L "$helper" ]; then
      error "schema-v2 release validator is missing: $(basename "$helper")"
      return
    fi
  done
  if ! have_tool python3; then
    error "python3 is required for complete schema-v2 release validation."
    return
  fi

  kernel_archive_name="$(single_manifest_value \
    "$release_manifest" "Kernel source archive" 2>/dev/null || true)"
  case "$kernel_archive_name" in
    ""|.|..|*/*|*[!A-Za-z0-9._+-]*|*.tar.xz.*)
      error "schema-v2 release manifest has a missing or unsafe kernel source archive name."
      return
      ;;
    *.tar.xz) ;;
    *)
      error "schema-v2 release manifest kernel source archive must be a .tar.xz file."
      return
      ;;
  esac
  kernel_archive="$RELEASE_DIR/$kernel_archive_name"
  if [ ! -f "$kernel_archive" ] || [ -L "$kernel_archive" ]; then
    error "schema-v2 release is missing its regular kernel source archive."
    return
  fi
  patched_tree="$(single_manifest_value \
    "$release_manifest" "Kernel source tree ID" 2>/dev/null || true)"
  if ! [[ "$patched_tree" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
    error "schema-v2 release has an invalid kernel source tree identity."
    return
  fi

  binding_dir="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$binding_dir" ] || [ ! -d "$binding_dir" ]; then
    error "could not create a temporary schema-v2 binding directory."
    return
  fi
  TEMP_DIRS+=("$binding_dir")
  expected_payload="$binding_dir/expected-payload"
  actual_payload="$binding_dir/actual-payload"
  if ! python3 -I "$validator" \
      --kernel-release-only \
      --repo-dir "$repo_dir" \
      --support-commit "$support_commit" \
      --kernel-build-manifest "$build_manifest" \
      --kernel-release-manifest "$release_manifest" \
      --apt-provenance "$apt_provenance" \
      --build-inputs "$build_inputs" \
      --kernel-source "$kernel_archive" \
      --expected-payload-out "$expected_payload" >/dev/null; then
    error "schema-v2 kernel release manifest and source failed complete cross-binding validation."
    return
  fi
  if ! python3 -I "$archive_validator" kernel \
      --archive "$kernel_archive" --expected-tree "$patched_tree" >/dev/null; then
    error "schema-v2 kernel source archive does not match its Git tree identity."
    return
  fi

  : > "$actual_payload"
  for asset in "${deb_files[@]}"; do
    if [ ! -f "$asset" ] || [ -L "$asset" ]; then
      error "schema-v2 kernel payload binding input is missing: $(basename "$asset")"
      return
    fi
    asset_name="$(basename "$asset")"
    asset_sha="$(sha256_file "$asset" 2>/dev/null || true)"
    if [[ ! "$asset_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
      error "could not hash schema-v2 kernel payload binding input: $asset_name"
      return
    fi
    printf '%s  %s\n' "${asset_sha,,}" "$asset_name" >> "$actual_payload"
  done
  if ! "$identity_validator" --kernel-only \
      --expected "$expected_payload" --actual "$actual_payload" >/dev/null; then
    error "schema-v2 kernel release binary payload differs from its bound manifests."
    return
  fi
  checked
}

validate_schema_v2_asset_inventory() {
  local package_total package_index asset_name label value
  local values=()
  local -A allowed_assets=()

  for asset_name in \
    SHA256SUMS \
    RELEASE-NOTES.md \
    sp11-kernel-build-manifest.txt \
    sp11-kernel-apt-provenance.txt \
    sp11-kernel-build-inputs.txt \
    sp11-kernel-module-signatures.txt \
    sp11-kernel-release-manifest.txt \
    sp11-kernel-debs.txt; do
    allowed_assets["$asset_name"]=1
  done

  package_total="$(single_manifest_value "$release_manifest" "Package count" 2>/dev/null || true)"
  if [[ ! "$package_total" =~ ^[1-9][0-9]*$ ]]; then
    error "schema-v2 release manifest has an invalid Package count for exact asset validation."
  else
    package_index=1
    while [ "$package_index" -le "$package_total" ]; do
      asset_name="$(single_manifest_value \
        "$release_manifest" "Package $package_index file" 2>/dev/null || true)"
      case "$asset_name" in
        ""|.|..|*/*|*[!A-Za-z0-9._+-]*)
          error "schema-v2 release manifest has an unsafe package asset name at index $package_index."
          ;;
        *.deb) allowed_assets["$asset_name"]=1 ;;
        *) error "schema-v2 release manifest package asset is not a .deb at index $package_index." ;;
      esac
      package_index=$((package_index + 1))
    done
  fi

  for label in "Kernel source archive" "Touchscreen source archive"; do
    values=()
    while IFS= read -r value; do values+=("$value"); done \
      < <(manifest_values "$release_manifest" "$label")
    if [ "${#values[@]}" -gt 1 ]; then
      error "schema-v2 release manifest contains multiple '$label' fields."
      continue
    fi
    [ "${#values[@]}" -eq 1 ] || continue
    asset_name="${values[0]}"
    case "$asset_name" in
      ""|.|..|*/*|*[!A-Za-z0-9._+-]*)
        error "schema-v2 release manifest has an unsafe source archive name in '$label'."
        ;;
      *.tar.xz) allowed_assets["$asset_name"]=1 ;;
      *) error "schema-v2 release manifest source archive is not a .tar.xz in '$label'." ;;
    esac
  done

  if [ "$touchscreen_release" = "true" ]; then
    for asset_name in \
      gpi.ko \
      spi-geni-qcom.ko \
      mshw0485_touch.ko \
      sp11-module-signing-cert.x509 \
      sp11-touchscreen-modules-manifest.txt; do
      allowed_assets["$asset_name"]=1
    done
  fi

  for asset_name in "${!DIRECTORY_FILES[@]}"; do
    if [ -z "${allowed_assets[$asset_name]+x}" ]; then
      error "schema-v2 release contains an unexpected asset: $asset_name"
    fi
  done
  for asset_name in "${!allowed_assets[@]}"; do
    [ "$asset_name" = "RELEASE-NOTES.md" ] && continue
    if [ -z "${DIRECTORY_FILES[$asset_name]+x}" ]; then
      error "schema-v2 release is missing its expected asset: $asset_name"
    fi
  done
  checked
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      require_arg "$1" "${2:-}"
      RELEASE_DIR="$2"
      shift 2
      ;;
    --tag)
      require_arg "$1" "${2:-}"
      TAG="$2"
      shift 2
      ;;
    --remote)
      require_arg "$1" "${2:-}"
      REMOTE="$2"
      shift 2
      ;;
    --local-prepared-candidate)
      LOCAL_PREPARED_CANDIDATE="true"
      shift
      ;;
    --downloaded-release)
      DOWNLOADED_RELEASE="true"
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

[ -n "$RELEASE_DIR" ] || die "--dir is required."
[ -z "$REMOTE" ] || [ -n "$TAG" ] || die "--remote requires --tag."
if [ "$LOCAL_PREPARED_CANDIDATE" = "$DOWNLOADED_RELEASE" ]; then
  die "choose exactly one authority mode: --local-prepared-candidate or --downloaded-release"
fi
[ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR"
[ ! -L "$RELEASE_DIR" ] || die "release directory must not be a symlink: $RELEASE_DIR"

if ! RELEASE_DIR="$(cd "$RELEASE_DIR" 2>/dev/null && pwd -P)"; then
  die "could not resolve release directory: $RELEASE_DIR"
fi
if [ "$LOCAL_PREPARED_CANDIDATE" = "true" ]; then
  RELEASE_ROOT_STATE="$(committed_release_root_state "$RELEASE_DIR")" ||
    die "release directory is not an exact committed mode-0500 root"
  release_previous_directory="$(pwd -P)"
  cd "$RELEASE_DIR" || die "could not enter the committed release directory"
  exec 52< .
  cd "$release_previous_directory" || die "could not restore the validator directory"
  verify_committed_release_root ||
    die "committed release root mapping changed during acquisition"
fi

for tool in awk basename find grep sort; do
  have_tool "$tool" || error "missing required tool: $tool"
done
if ! have_tool sha256sum && ! have_tool shasum; then
  error "missing required checksum tool: sha256sum or shasum"
fi

declare -A CHECKSUM_HASHES=()
declare -A CHECKSUM_FILES=()
declare -A DIRECTORY_FILES=()
checksum_manifest="$RELEASE_DIR/SHA256SUMS"

if [ ! -f "$checksum_manifest" ] || [ -L "$checksum_manifest" ]; then
  error "missing regular, non-symlinked SHA256SUMS."
else
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    [ -n "$line" ] || continue

    if [[ ! "$line" =~ ^([0-9A-Fa-f]{64})[[:space:]]+\*?(.+)$ ]]; then
      error "SHA256SUMS:$line_number is not a valid SHA-256 entry."
      continue
    fi

    expected_hash="${BASH_REMATCH[1],,}"
    asset_name="${BASH_REMATCH[2]}"
    asset_name="${asset_name#./}"

    case "$asset_name" in
      ""|.|..|/*|*/*)
        error "SHA256SUMS:$line_number has unsafe or non-flat path: $asset_name"
        continue
        ;;
    esac

    if [ -n "${CHECKSUM_FILES[$asset_name]+x}" ]; then
      error "SHA256SUMS lists $asset_name more than once."
      continue
    fi
    CHECKSUM_FILES["$asset_name"]=1
    CHECKSUM_HASHES["$asset_name"]="$expected_hash"

    case "$asset_name" in
      SHA256SUMS)
        error "SHA256SUMS must not list itself."
        continue
        ;;
      RELEASE-NOTES.md)
        error "SHA256SUMS must not list local RELEASE-NOTES.md; release notes are not an uploaded asset."
        continue
        ;;
    esac

    asset_path="$RELEASE_DIR/$asset_name"
    if [ ! -f "$asset_path" ] || [ -L "$asset_path" ]; then
      error "checksum entry is missing a regular, non-symlinked asset: $asset_name"
      continue
    fi
    if ! actual_hash="$(sha256_file "$asset_path")"; then
      error "could not calculate SHA-256 for $asset_name."
      continue
    fi
    actual_hash="${actual_hash,,}"
    if [ "$actual_hash" != "$expected_hash" ]; then
      error "checksum mismatch for $asset_name: expected $expected_hash, got $actual_hash"
    else
      checked
    fi
  done < "$checksum_manifest"
fi

while IFS= read -r -d '' entry; do
  name="$(basename "$entry")"
  if [ -L "$entry" ]; then
    error "release directory contains a symlink: $name"
    continue
  fi
  if [ ! -f "$entry" ]; then
    error "release directory must be flat and contain files only; unexpected entry: $name"
    continue
  fi
  DIRECTORY_FILES["$name"]=1
  case "$name" in
    SHA256SUMS|RELEASE-NOTES.md) ;;
    *)
      if [ -z "${CHECKSUM_FILES[$name]+x}" ]; then
        error "upload asset is not represented in SHA256SUMS: $name"
      fi
      ;;
  esac
done < <(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -print0)

declare -A ROLE_FILES=()
declare -A ROLE_ABIS=()
declare -A ROLE_VERSIONS=()
declare -A ROLE_COUNTS=([image]=0 [modules]=0 [modules_extra]=0 [headers]=0 [common_headers]=0)
deb_files=()

record_package() {
  local role="$1"
  local path="$2"
  local abi="$3"
  local version="$4"
  local count=$((ROLE_COUNTS[$role] + 1))
  ROLE_COUNTS["$role"]="$count"
  if [ "$count" -eq 1 ]; then
    ROLE_FILES["$role"]="$path"
    ROLE_ABIS["$role"]="$abi"
    ROLE_VERSIONS["$role"]="$version"
  else
    error "duplicate $role package: $(basename "$path")"
  fi
}

while IFS= read -r -d '' deb; do
  deb_files+=("$deb")
  base="$(basename "$deb")"
  role=""
  abi=""
  version=""

  case "$base" in
    linux-qcom-x1e-headers-*_all.deb)
      role="common_headers"
      stem="${base%_all.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      common_release="${package_part#linux-qcom-x1e-headers-}"
      abi="$common_release-qcom-x1e"
      ;;
    linux-headers-*_arm64.deb)
      role="headers"
      stem="${base%_arm64.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      abi="${package_part#linux-headers-}"
      ;;
    linux-image-unsigned-*_arm64.deb|linux-image-*_arm64.deb)
      role="image"
      stem="${base%_arm64.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      case "$package_part" in
        linux-image-unsigned-*) abi="${package_part#linux-image-unsigned-}" ;;
        *) abi="${package_part#linux-image-}" ;;
      esac
      ;;
    linux-modules-extra-*_arm64.deb)
      role="modules_extra"
      stem="${base%_arm64.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      abi="${package_part#linux-modules-extra-}"
      ;;
    linux-modules-*_arm64.deb)
      role="modules"
      stem="${base%_arm64.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      abi="${package_part#linux-modules-}"
      ;;
    *)
      error "unexpected Debian package asset: $base"
      continue
      ;;
  esac

  if [ -z "$abi" ] || [ "$abi" = "-qcom-x1e" ] || [ -z "$version" ]; then
    error "could not parse ABI/version from $base"
    continue
  fi
  record_package "$role" "$deb" "$abi" "$version"
done < <(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print0)

for role in image modules headers; do
  if [ "${ROLE_COUNTS[$role]}" -ne 1 ]; then
    error "expected exactly one $role qcom-x1e package, found ${ROLE_COUNTS[$role]}."
  fi
done
if [ "${ROLE_COUNTS[common_headers]}" -gt 1 ]; then
  error "expected at most one common qcom-x1e headers package, found ${ROLE_COUNTS[common_headers]}."
fi
if [ "${ROLE_COUNTS[modules_extra]}" -gt 1 ]; then
  error "expected at most one optional modules-extra package, found ${ROLE_COUNTS[modules_extra]}."
fi

kernel_abi="${ROLE_ABIS[image]:-}"
package_version="${ROLE_VERSIONS[image]:-}"
if [ -n "$kernel_abi" ]; then
  case "$kernel_abi" in
    *-qcom-x1e) ;;
    *) error "kernel ABI is not a qcom-x1e ABI: $kernel_abi" ;;
  esac
fi
for role in modules modules_extra headers common_headers; do
  [ "${ROLE_COUNTS[$role]}" -eq 1 ] || continue
  if [ -n "$kernel_abi" ] && [ "${ROLE_ABIS[$role]}" != "$kernel_abi" ]; then
    error "$role package ABI ${ROLE_ABIS[$role]} does not match $kernel_abi."
  fi
  if [ -n "$package_version" ] && [ "${ROLE_VERSIONS[$role]}" != "$package_version" ]; then
    error "$role package version ${ROLE_VERSIONS[$role]} does not match $package_version."
  fi
done

if [ "${#deb_files[@]}" -gt 0 ]; then
  if ! have_tool dpkg-deb; then
    error "missing required tool for Debian package validation: dpkg-deb"
  else
    for role in image modules modules_extra headers common_headers; do
      [ "${ROLE_COUNTS[$role]}" -eq 1 ] || continue
      deb="${ROLE_FILES[$role]}"
      case "$role" in
        image)
          actual_package="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
          case "$actual_package" in
            linux-image-${ROLE_ABIS[$role]}|linux-image-unsigned-${ROLE_ABIS[$role]})
              expected_package="$actual_package"
              ;;
            *) expected_package="linux-image-${ROLE_ABIS[$role]}" ;;
          esac
          expected_arch="arm64"
          ;;
        modules) expected_package="linux-modules-${ROLE_ABIS[$role]}"; expected_arch="arm64" ;;
        modules_extra) expected_package="linux-modules-extra-${ROLE_ABIS[$role]}"; expected_arch="arm64" ;;
        headers) expected_package="linux-headers-${ROLE_ABIS[$role]}"; expected_arch="arm64" ;;
        common_headers)
          expected_package="linux-qcom-x1e-headers-${ROLE_ABIS[$role]%-qcom-x1e}"
          expected_arch="all"
          ;;
      esac
      actual_package="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
      actual_version="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
      actual_arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
      [ "$actual_package" = "$expected_package" ] || \
        error "$(basename "$deb") contains package '$actual_package', expected '$expected_package'."
      [ "$actual_version" = "${ROLE_VERSIONS[$role]}" ] || \
        error "$(basename "$deb") contains version '$actual_version', expected '${ROLE_VERSIONS[$role]}'."
      [ "$actual_arch" = "$expected_arch" ] || \
        error "$(basename "$deb") has architecture '$actual_arch', expected '$expected_arch'."
    done

    if [ "${ROLE_COUNTS[headers]}" -eq 1 ]; then
      header_depends="$(dpkg-deb -f "${ROLE_FILES[headers]}" Depends 2>/dev/null || true)"
      if [[ "$header_depends" =~ (linux-qcom-x1e-headers-[A-Za-z0-9.+:~_-]+) ]]; then
        required_common="${BASH_REMATCH[1]}"
        if [ "${ROLE_COUNTS[common_headers]}" -ne 1 ]; then
          error "flavour headers require $required_common, but its common headers package is missing."
        else
          actual_common="$(dpkg-deb -f "${ROLE_FILES[common_headers]}" Package 2>/dev/null || true)"
          [ "$actual_common" = "$required_common" ] || \
            error "flavour headers require $required_common, but release contains $actual_common."
        fi
      fi
    fi
  fi
fi

release_manifest="$RELEASE_DIR/sp11-kernel-release-manifest.txt"
support_commit=""
manifest_release=""
schema_v2="false"
kernel_release_schema_v1="false"
if [ ! -f "$release_manifest" ] || [ -L "$release_manifest" ]; then
  error "missing regular, non-symlinked sp11-kernel-release-manifest.txt."
else
  if ! support_commit="$(single_manifest_value "$release_manifest" "Support repo commit")"; then
    error "sp11-kernel-release-manifest.txt must contain exactly one nonempty 'Support repo commit:' field."
    support_commit=""
  fi
  if ! manifest_release="$(single_manifest_value "$release_manifest" "Release")"; then
    error "sp11-kernel-release-manifest.txt must contain exactly one nonempty 'Release:' field."
    manifest_release=""
  fi
  schema_values=()
  while IFS= read -r value; do schema_values+=("$value"); done \
    < <(manifest_values "$release_manifest" "Build provenance schema")
  if [ "${#schema_values[@]}" -eq 0 ]; then
    schema_v2="false"
  elif [ "${#schema_values[@]}" -eq 1 ] &&
       [ "${schema_values[0]}" = "sp11-kernel-build-v2" ]; then
    schema_v2="true"
  else
    schema_v2="invalid"
    error "release manifest has an unsupported or ambiguous Build provenance schema declaration."
  fi
  release_schema_values=()
  while IFS= read -r value; do release_schema_values+=("$value"); done \
    < <(manifest_values "$release_manifest" "Kernel release schema")
  if [ "${#release_schema_values[@]}" -eq 0 ]; then
    kernel_release_schema_v1="false"
  elif [ "${#release_schema_values[@]}" -eq 1 ] &&
       [ "${release_schema_values[0]}" = "sp11-kernel-release-v1" ]; then
    kernel_release_schema_v1="true"
  else
    kernel_release_schema_v1="invalid"
    error "release manifest has an unsupported or ambiguous Kernel release schema declaration."
  fi
  if [[ ! "$support_commit" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
    error "release manifest Support repo commit must be an immutable 40- or 64-hex commit."
  else
    support_commit="${support_commit,,}"
  fi
  if ! dirty_value="$(single_manifest_value "$release_manifest" "Support repo dirty")"; then
    error "sp11-kernel-release-manifest.txt must contain exactly one nonempty 'Support repo dirty:' field."
    dirty_value=""
  fi
  if [ -n "$dirty_value" ] && [ "$dirty_value" != "false" ]; then
    error "release manifest records a dirty support repository: $dirty_value"
  fi

  if ! grep -Fq "No source assets included." "$release_manifest"; then
    manifest_source_mode="$(single_manifest_value "$release_manifest" "Source mode" 2>/dev/null || true)"
    manifest_source_url="$(single_manifest_value "$release_manifest" "Source URL" 2>/dev/null || true)"
    manifest_source_ref="$(single_manifest_value "$release_manifest" "Source branch" 2>/dev/null || true)"
    manifest_source_head="$(single_manifest_value "$release_manifest" "Source HEAD" 2>/dev/null || true)"
    manifest_docker_image="$(single_manifest_value "$release_manifest" "Docker image" 2>/dev/null || true)"
    manifest_build_target="$(single_manifest_value "$release_manifest" "Build target" 2>/dev/null || true)"
    manifest_jobs="$(single_manifest_value "$release_manifest" "Jobs" 2>/dev/null || true)"
    manifest_rules_runner="$(single_manifest_value "$release_manifest" "Rules runner" 2>/dev/null || true)"

    for provenance_value in \
      "$manifest_source_mode" "$manifest_source_url" "$manifest_source_ref" \
      "$manifest_docker_image" "$manifest_build_target" "$manifest_jobs" \
      "$manifest_rules_runner"; do
      if [ -z "$provenance_value" ] || [ "$provenance_value" = "unknown" ]; then
        error "publishable release manifest has missing or unknown build provenance."
        break
      fi
    done

    case "$manifest_source_mode" in
      git)
        if [[ ! "$manifest_source_head" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
          error "git release manifest Source HEAD must be an immutable 40- or 64-hex commit."
        fi
        ;;
      apt)
        manifest_apt_source_spec="$(single_manifest_value "$release_manifest" "Apt source spec" 2>/dev/null || true)"
        if [ -z "$manifest_apt_source_spec" ] || [ "$manifest_apt_source_spec" = "unknown" ]; then
          error "apt release manifest must record an exact Apt source spec."
        fi
        ;;
      *)
        error "release manifest Source mode must be git or apt, got '${manifest_source_mode:-missing}'."
        ;;
    esac

    [[ "$manifest_jobs" =~ ^[1-9][0-9]*$ ]] || \
      error "release manifest Jobs must be a positive integer."
    if [ "$schema_v2" = "true" ]; then
      build_manifest="$RELEASE_DIR/sp11-kernel-build-manifest.txt"
      apt_provenance="$RELEASE_DIR/sp11-kernel-apt-provenance.txt"
      build_inputs="$RELEASE_DIR/sp11-kernel-build-inputs.txt"
      build_inputs_validator="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/sp11-kernel-build-inputs.py"
      kernel_baseline="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/config/kernel-baselines/7.2-rc5-jg-0.env"
      if [ "$kernel_release_schema_v1" != "true" ]; then
        error "schema-v2 release is missing its exact sp11-kernel-release-v1 outer attestation."
      elif [ ! -f "$build_manifest" ] || [ -L "$build_manifest" ] ||
           [ ! -f "$apt_provenance" ] || [ -L "$apt_provenance" ] ||
           [ ! -f "$build_inputs" ] || [ -L "$build_inputs" ]; then
        error "schema-v2 release is missing its exact regular immutable build-input trio."
      elif ! have_tool python3; then
        error "python3 is required for strict schema-v2 build-manifest validation."
      elif [ ! -f "$build_inputs_validator" ] || [ -L "$build_inputs_validator" ]; then
        error "strict immutable build-input validator is missing."
      elif [ ! -f "$kernel_baseline" ] || [ -L "$kernel_baseline" ]; then
        error "reviewed immutable kernel baseline is missing."
      elif ! python3 -I "$build_inputs_validator" validate-attached \
          --baseline "$kernel_baseline" \
          --support-head "$support_commit" \
          --build-manifest "$build_manifest" \
          --apt-provenance "$apt_provenance" \
          --output "$build_inputs" >/dev/null; then
        error "attached immutable kernel build-input trio failed strict validation."
      else
        checked
      fi
    elif [ "$schema_v2" = "false" ]; then
      grep -Eq '^- patches/.+\.patch$' "$release_manifest" || \
        error "publishable legacy release manifest does not record repository-relative patch assets."
    fi
    checked
  fi

  package_count="$(single_manifest_value "$release_manifest" "Package count" 2>/dev/null || true)"
  for deb in "${deb_files[@]}"; do
    base="$(basename "$deb")"
    sha="$(sha256_file "$deb" 2>/dev/null || true)"
    if [ "$schema_v2" = "true" ]; then
      package_indexes=()
      while IFS= read -r package_index; do
        package_indexes+=("$package_index")
      done < <(awk -v target="$base" '
        $0 ~ /^Package [1-9][0-9]* file: / {
          label = $0
          sub(/^Package /, "", label)
          sub(/ file: .*/, "", label)
          value = $0
          sub(/^Package [1-9][0-9]* file: /, "", value)
          if (value == target) print label
        }
      ' "$release_manifest")
      if [ "${#package_indexes[@]}" -ne 1 ]; then
        error "schema-v2 release manifest does not list package $base exactly once."
      elif [ -n "$sha" ] &&
           [ "$(single_manifest_value "$release_manifest" "Package ${package_indexes[0]} SHA256" 2>/dev/null || true)" != "$sha" ]; then
        error "schema-v2 release manifest does not record the actual SHA-256 for $base."
      fi
    elif [ "$schema_v2" = "false" ]; then
      grep -Fq -- "- $base" "$release_manifest" || \
        error "release manifest does not list package $base."
      [ -z "$sha" ] || grep -Fiq -- "SHA256: $sha" "$release_manifest" || \
        error "release manifest does not record the actual SHA-256 for $base."
    fi
  done
  if [ "$schema_v2" = "true" ] &&
     { [[ ! "$package_count" =~ ^[1-9][0-9]*$ ]] || [ "$package_count" -ne "${#deb_files[@]}" ]; }; then
    error "schema-v2 release manifest package count does not match its assets."
  fi
fi

debs_manifest="$RELEASE_DIR/sp11-kernel-debs.txt"
if [ ! -f "$debs_manifest" ] || [ -L "$debs_manifest" ]; then
  error "missing regular, non-symlinked sp11-kernel-debs.txt."
else
  declare -A LISTED_DEBS=()
  while IFS= read -r listed || [ -n "$listed" ]; do
    listed="${listed%$'\r'}"
    [ -n "$listed" ] || continue
    case "$listed" in
      */*|.*)
        error "sp11-kernel-debs.txt contains an unsafe package name: $listed"
        continue
        ;;
    esac
    if [ -n "${LISTED_DEBS[$listed]+x}" ]; then
      error "sp11-kernel-debs.txt lists $listed more than once."
    fi
    LISTED_DEBS["$listed"]=1
  done < "$debs_manifest"

  for deb in "${deb_files[@]}"; do
    base="$(basename "$deb")"
    [ -n "${LISTED_DEBS[$base]+x}" ] || error "sp11-kernel-debs.txt omits $base."
  done
  for listed in "${!LISTED_DEBS[@]}"; do
    [ -f "$RELEASE_DIR/$listed" ] || error "sp11-kernel-debs.txt names a missing package: $listed"
    case "$listed" in
      *.deb) ;;
      *) error "sp11-kernel-debs.txt contains a non-.deb entry: $listed" ;;
    esac
  done
  if [ "${#LISTED_DEBS[@]}" -ne "${#deb_files[@]}" ]; then
    error "sp11-kernel-debs.txt asset count (${#LISTED_DEBS[@]}) does not match the directory (${#deb_files[@]})."
  fi
fi

if [ -n "$TAG" ]; then
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if ! have_tool git; then
    error "missing required tool for tag validation: git"
  else
    if [ -n "$manifest_release" ] && [ "$manifest_release" != "$TAG" ]; then
      error "release manifest names '$manifest_release', but --tag is '$TAG'."
    fi

    local_target=""
    if local_target="$(git -c "safe.directory=$repo_dir" -C "$repo_dir" \
        rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null)"; then
      local_target="${local_target,,}"
      if [ -n "$support_commit" ] && [ "$support_commit" != "$local_target" ]; then
        error "release manifest support commit $support_commit does not match local tag $TAG target $local_target."
      else
        checked
      fi
    else
      error "local tag not found: $TAG"
    fi

    if [ -n "$REMOTE" ]; then
      remote_output=""
      if ! remote_output="$(git -c "safe.directory=$repo_dir" -C "$repo_dir" \
        ls-remote --exit-code --tags "$REMOTE" \
        "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null)"; then
        error "could not resolve remote tag $TAG from $REMOTE."
      else
        remote_target="$(printf '%s\n' "$remote_output" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')"
        if [ -z "$remote_target" ]; then
          remote_target="$(printf '%s\n' "$remote_output" | awk 'NF >= 2 {print $1; exit}')"
        fi
        remote_target="${remote_target,,}"
        if [[ ! "$remote_target" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
          error "remote tag $TAG did not resolve to a 40- or 64-hex target."
        elif [ -n "$support_commit" ] && [ "$support_commit" != "$remote_target" ]; then
          error "release manifest support commit $support_commit does not match remote tag $TAG target $remote_target."
        else
          checked
        fi
      fi
    fi
  fi
fi

touchscreen_release="false"
case "$kernel_abi" in
  *sp11v3*) touchscreen_release="true" ;;
esac

touch_modules=(gpi.ko spi-geni-qcom.ko mshw0485_touch.ko)
present_ko_files=()
while IFS= read -r -d '' ko; do
  present_ko_files+=("$(basename "$ko")")
done < <(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.ko' -print0)

if [ "$touchscreen_release" = "true" ]; then
  for expected in "${touch_modules[@]}"; do
    if [ ! -f "$RELEASE_DIR/$expected" ] || [ -L "$RELEASE_DIR/$expected" ]; then
      error "sp11v3 release is missing touchscreen module: $expected"
    fi
  done
  for actual in "${present_ko_files[@]}"; do
    case "$actual" in
      gpi.ko|spi-geni-qcom.ko|mshw0485_touch.ko) ;;
      *) error "sp11v3 release contains unexpected kernel module: $actual" ;;
    esac
  done
  if [ "${#present_ko_files[@]}" -ne 3 ]; then
    error "sp11v3 release must contain exactly three touchscreen .ko files; found ${#present_ko_files[@]}."
  fi

  touchscreen_certificate="$RELEASE_DIR/sp11-module-signing-cert.x509"
  if [ ! -f "$touchscreen_certificate" ] || [ -L "$touchscreen_certificate" ]; then
    error "sp11v3 release is missing the regular public module-signing certificate asset."
  fi

  touchscreen_manifest="$RELEASE_DIR/sp11-touchscreen-modules-manifest.txt"
  touchscreen_source_commit=""
  if [ ! -f "$touchscreen_manifest" ] || [ -L "$touchscreen_manifest" ]; then
    error "sp11v3 release is missing sp11-touchscreen-modules-manifest.txt provenance."
  else
    if ! manifest_touch_abi="$(single_manifest_value "$touchscreen_manifest" "Kernel ABI")"; then
      if ! manifest_touch_abi="$(single_manifest_value "$touchscreen_manifest" "Target release")"; then
        error "touchscreen provenance must contain exactly one Kernel ABI or Target release field."
        manifest_touch_abi=""
      fi
    fi
    [ "$manifest_touch_abi" = "$kernel_abi" ] || \
      error "touchscreen provenance ABI '$manifest_touch_abi' does not match '$kernel_abi'."

    commit_values=()
    value=""
    while IFS= read -r value; do commit_values+=("$value"); done \
      < <(manifest_values "$touchscreen_manifest" "Touchscreen source commit")
    if [ "${#commit_values[@]}" -eq 0 ]; then
      while IFS= read -r value; do commit_values+=("$value"); done \
        < <(manifest_values "$touchscreen_manifest" "Source commit")
    fi
    if [ "${#commit_values[@]}" -ne 1 ] ||
       [[ ! "${commit_values[0]:-}" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
      error "touchscreen provenance must contain exactly one immutable 40- or 64-hex source commit."
    else
      touchscreen_source_commit="${commit_values[0],,}"
    fi

    ref_values=()
    while IFS= read -r value; do ref_values+=("$value"); done \
      < <(manifest_values "$touchscreen_manifest" "Source ref")
    if [ "${#ref_values[@]}" -gt 1 ]; then
      error "touchscreen provenance contains multiple Source ref fields."
    elif [ "${#ref_values[@]}" -eq 1 ]; then
      if [[ ! "${ref_values[0]}" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
        error "touchscreen provenance Source ref must be an immutable 40- or 64-hex commit."
      elif [ -n "$touchscreen_source_commit" ] && [ "${ref_values[0],,}" != "$touchscreen_source_commit" ]; then
        error "touchscreen provenance Source ref and Source commit differ."
      fi
    fi
  fi

  if [ ! -x /usr/bin/python3 ]; then
    error "trusted /usr/bin/python3 is required for controlled touchscreen module signature validation."
  elif [ ! -f "$SIGNED_MODULE_VALIDATOR" ] || [ -L "$SIGNED_MODULE_VALIDATOR" ]; then
    error "controlled touchscreen module signature validator is unavailable."
  elif [ -f "$touchscreen_certificate" ] && [ ! -L "$touchscreen_certificate" ] &&
       [ -f "$RELEASE_DIR/gpi.ko" ] && [ ! -L "$RELEASE_DIR/gpi.ko" ] &&
       [ -f "$RELEASE_DIR/spi-geni-qcom.ko" ] && [ ! -L "$RELEASE_DIR/spi-geni-qcom.ko" ] &&
       [ -f "$RELEASE_DIR/mshw0485_touch.ko" ] && [ ! -L "$RELEASE_DIR/mshw0485_touch.ko" ]; then
    signed_module_arguments=(
      --certificate "$touchscreen_certificate"
      --module "$RELEASE_DIR/gpi.ko"
      --module "$RELEASE_DIR/spi-geni-qcom.ko"
      --module "$RELEASE_DIR/mshw0485_touch.ko"
    )
    if [ "$schema_v2" = "true" ] && [ -f "$touchscreen_manifest" ] &&
       [ ! -L "$touchscreen_manifest" ]; then
      signed_module_arguments+=(
        --manifest "$touchscreen_manifest"
        --manifest-format release
      )
    fi
    if /usr/bin/python3 -I "$SIGNED_MODULE_VALIDATOR" \
        "${signed_module_arguments[@]}" >/dev/null; then
      checked
    else
      error "controlled touchscreen module signatures or certificate are invalid."
    fi
  fi

  if [ "$schema_v2" = "true" ] && [ -f "${touchscreen_manifest:-}" ] &&
     [ ! -L "$touchscreen_manifest" ]; then
    validate_schema_v2_touchscreen_bindings
  fi

  if ! have_tool modinfo; then
    error "missing required tool for touchscreen module validation: modinfo"
  else
    declare -A EXPECTED_MODULE_NAMES=(
      [gpi.ko]=gpi
      [spi-geni-qcom.ko]=spi_geni_qcom
      [mshw0485_touch.ko]=mshw0485_touch
    )
    common_vermagic_abi=""
    for module_file in "${touch_modules[@]}"; do
      module_path="$RELEASE_DIR/$module_file"
      [ -f "$module_path" ] && [ ! -L "$module_path" ] || continue
      module_name="$(modinfo -F name "$module_path" 2>/dev/null || true)"
      module_vermagic="$(modinfo -F vermagic "$module_path" 2>/dev/null || true)"
      module_vermagic_abi="${module_vermagic%% *}"
      module_srcversion="$(modinfo -F srcversion "$module_path" 2>/dev/null || true)"

      [ "$module_name" = "${EXPECTED_MODULE_NAMES[$module_file]}" ] || \
        error "$module_file has module name '$module_name', expected '${EXPECTED_MODULE_NAMES[$module_file]}'."
      [ "$module_vermagic_abi" = "$kernel_abi" ] || \
        error "$module_file vermagic targets '$module_vermagic_abi', expected '$kernel_abi'."
      if [ -z "$common_vermagic_abi" ]; then
        common_vermagic_abi="$module_vermagic_abi"
      elif [ "$module_vermagic_abi" != "$common_vermagic_abi" ]; then
        error "touchscreen modules do not share a common first-word vermagic."
      fi
      [[ "$module_srcversion" =~ ^[0-9A-Fa-f]+$ ]] || \
        error "$module_file has an empty or invalid srcversion."

      if [ -f "${touchscreen_manifest:-}" ]; then
        module_sha="$(sha256_file "$module_path" 2>/dev/null || true)"
        if single_manifest_value "$touchscreen_manifest" "Module $module_file SHA256" >/dev/null 2>&1; then
          [ "$(single_manifest_value "$touchscreen_manifest" "Module $module_file name" 2>/dev/null || true)" = \
            "${EXPECTED_MODULE_NAMES[$module_file]}" ] ||
            error "flat touchscreen provenance records the wrong name for $module_file."
          [ -z "$module_sha" ] ||
            [ "$(single_manifest_value "$touchscreen_manifest" "Module $module_file SHA256" 2>/dev/null || true)" = "$module_sha" ] ||
            error "flat touchscreen provenance does not record the actual SHA-256 for $module_file."
          [ "$(single_manifest_value "$touchscreen_manifest" "Module $module_file srcversion" 2>/dev/null || true)" = "$module_srcversion" ] ||
            error "flat touchscreen provenance does not record the srcversion for $module_file."
        else
          grep -Fq -- "- $module_file" "$touchscreen_manifest" || \
            error "touchscreen provenance does not list $module_file."
          [ -z "$module_sha" ] || grep -Fiq -- "SHA256: $module_sha" "$touchscreen_manifest" || \
            error "touchscreen provenance does not record the actual SHA-256 for $module_file."
          grep -Fq -- "$module_srcversion" "$touchscreen_manifest" || \
            error "touchscreen provenance does not record the srcversion for $module_file."
        fi
      fi
    done

    modinfo -p "$RELEASE_DIR/spi-geni-qcom.ko" 2>/dev/null | \
      grep -q '^sp11_windows_se_init:' || \
      error "spi-geni-qcom.ko lacks the required sp11_windows_se_init parameter."
    modinfo -F alias "$RELEASE_DIR/mshw0485_touch.ko" 2>/dev/null | \
      grep -q 'microsoft,mshw0485' || \
      error "mshw0485_touch.ko lacks the microsoft,mshw0485 device-tree alias."
  fi

  if [ "${ROLE_COUNTS[modules]}" -eq 1 ]; then
    if ! have_tool dpkg-deb || ! have_tool fdtget || ! have_tool tar; then
      error "dpkg-deb, tar, and fdtget are required to inspect the packaged sp11v3 Denali OLED DTB."
    else
      temp_dir="$(mktemp -d 2>/dev/null || true)"
      if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
        error "could not create a temporary directory for DTB inspection."
      else
        TEMP_DIRS+=("$temp_dir")
        image_root="$temp_dir/modules"
        mkdir -p "$image_root"
        archive_listing=""
        if ! archive_listing="$(dpkg-deb --fsys-tarfile "${ROLE_FILES[modules]}" 2>/dev/null | tar -tf - 2>/dev/null)"; then
          error "could not list $(basename "${ROLE_FILES[modules]}") for DTB inspection."
        else
          archive_dtb_paths=()
          expected_dtb_prefix="./usr/lib/firmware/$kernel_abi/device-tree/qcom/"
          while IFS= read -r archive_path; do
            case "$archive_path" in
              "${expected_dtb_prefix}x1e80100-microsoft-denali-oled.dtb"|\
              "${expected_dtb_prefix}x1e80100-microsoft-denali-oled-el2.dtb")
                archive_dtb_paths+=("$archive_path")
                ;;
            esac
          done <<<"$archive_listing"

          if [ "${#archive_dtb_paths[@]}" -gt 0 ]; then
            if ! dpkg-deb --fsys-tarfile "${ROLE_FILES[modules]}" 2>/dev/null | \
              tar -x -C "$image_root" -- "${archive_dtb_paths[@]}" 2>/dev/null; then
              error "could not extract Denali OLED DTBs from $(basename "${ROLE_FILES[modules]}")."
            fi
          fi

          denali_dtbs=()
          while IFS= read -r -d '' dtb; do denali_dtbs+=("$dtb"); done \
            < <(find "$image_root" -type f \
              \( -name 'x1e80100-microsoft-denali-oled.dtb' \
                 -o -name 'x1e80100-microsoft-denali-oled-el2.dtb' \) -print0)
          primary_count=0
          for dtb in "${denali_dtbs[@]}"; do
            [ "$(basename "$dtb")" = "x1e80100-microsoft-denali-oled.dtb" ] && \
              primary_count=$((primary_count + 1))
          done
          [ "$primary_count" -eq 1 ] || \
            error "modules package must contain exactly one x1e80100-microsoft-denali-oled.dtb; found $primary_count."

          for dtb in "${denali_dtbs[@]}"; do
            dtb_name="$(basename "$dtb")"
            root_compatible="$(fdtget "$dtb" / compatible 2>/dev/null || true)"
            spi_path="/soc@0/geniqup@ac0000/spi@a88000"
            touch_path="$spi_path/touchscreen@0"
            spi_status="$(fdtget "$dtb" "$spi_path" status 2>/dev/null || true)"
            spi_compatible="$(fdtget "$dtb" "$spi_path" compatible 2>/dev/null || true)"
            touch_compatible="$(fdtget "$dtb" "$touch_path" compatible 2>/dev/null || true)"

            [[ " $root_compatible " == *" microsoft,denali-oled "* ]] || \
              error "$dtb_name is not a Microsoft Denali OLED device tree."
            [ "$spi_status" = "okay" ] || \
              error "$dtb_name does not enable $spi_path (status='$spi_status')."
            [[ " $spi_compatible " == *" qcom,geni-spi "* ]] || \
              error "$dtb_name lacks the qcom,geni-spi controller at $spi_path."
            fdtget "$dtb" "$spi_path" qcom,biosref-qspi >/dev/null 2>&1 || \
              error "$dtb_name lacks qcom,biosref-qspi at $spi_path."
            fdtget "$dtb" "$spi_path" qcom,enable-gsi-dma >/dev/null 2>&1 || \
              error "$dtb_name lacks qcom,enable-gsi-dma at $spi_path."
            [[ " $touch_compatible " == *" microsoft,mshw0485 "* ]] || \
              error "$dtb_name lacks the microsoft,mshw0485 touchscreen node."
          done
          [ "${#denali_dtbs[@]}" -gt 0 ] && checked
        fi
      fi
    fi
  fi
else
  if [ "${#present_ko_files[@]}" -gt 0 ]; then
    error "non-sp11v3 release contains unexpected touchscreen kernel modules: ${present_ko_files[*]}"
  fi
  if [ -e "$RELEASE_DIR/sp11-touchscreen-modules-manifest.txt" ]; then
    error "non-sp11v3 release contains an unexpected touchscreen provenance manifest."
  fi
  if [ -e "$RELEASE_DIR/sp11-module-signing-cert.x509" ]; then
    error "non-sp11v3 release contains an unexpected touchscreen module-signing certificate."
  fi
fi

if [ "$schema_v2" = "true" ] && [ "$touchscreen_release" != "true" ]; then
  validate_schema_v2_kernel_bindings
fi
if [ "$schema_v2" = "true" ]; then
  validate_controlled_kernel_module_report
  validate_schema_v2_asset_inventory
fi

if [ "$LOCAL_PREPARED_CANDIDATE" = "true" ] && ! verify_committed_release_root; then
  error "committed release root changed during validation"
fi

if [ "$ERROR_COUNT" -ne 0 ]; then
  echo "Release validation failed with $ERROR_COUNT error(s)." >&2
  exit 1
fi

echo "Validated directory: $RELEASE_DIR"
if [ -n "$kernel_abi" ]; then
  echo "Kernel ABI: $kernel_abi"
  echo "Package version: $package_version"
fi
echo "Successful checks: $CHECK_COUNT"
if [ "$DOWNLOADED_RELEASE" = "true" ]; then
  echo "Validation authority: downloaded-content-only; no local commit or publication authority."
fi
echo "Release validation passed."
