#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode="${1:-}"
[ "$#" -gt 0 ] && shift

baseline=""
archives_dir=""
index_cache_dir=""
retained_lists_dir=""
work_dir=""
kernel_work_dir=""
output=""
apt_etc_dir=""
apt_lists_dir=""
archive_keyring=""
ca_bundle=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sp11-immutable-apt.sh bootstrap --baseline FILE --archives-dir DIR --index-cache-dir DIR --retained-lists-dir DIR --work-dir DIR --kernel-work-dir DIR
  sp11-immutable-apt.sh finalize  --baseline FILE --archives-dir DIR --index-cache-dir DIR --retained-lists-dir DIR --work-dir DIR --kernel-work-dir DIR --output FILE
EOF
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() {
  case "$(uname -s)" in
    Darwin) stat -f '%z' "$1" ;;
    *) stat -c '%s' -- "$1" ;;
  esac
}

required_arg() {
  [ -n "${2:-}" ] || die "missing value for $1"
}

canonical_directory() {
  local path="$1" label="$2" physical
  case "$path" in
    /*) ;;
    *) die "$label must be an absolute path" ;;
  esac
  [ -d "$path" ] && [ ! -L "$path" ] || die "$label must be a real directory"
  physical="$(cd "$path" && pwd -P)"
  [ "$physical" = "$path" ] || die "$label contains a symlink or non-canonical component"
  printf '%s\n' "$physical"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline)
      required_arg "$1" "${2:-}"
      baseline="$2"
      shift 2
      ;;
    --archives-dir)
      required_arg "$1" "${2:-}"
      archives_dir="$2"
      shift 2
      ;;
    --index-cache-dir)
      required_arg "$1" "${2:-}"
      index_cache_dir="$2"
      shift 2
      ;;
    --retained-lists-dir)
      required_arg "$1" "${2:-}"
      retained_lists_dir="$2"
      shift 2
      ;;
    --work-dir)
      required_arg "$1" "${2:-}"
      work_dir="$2"
      shift 2
      ;;
    --kernel-work-dir)
      required_arg "$1" "${2:-}"
      kernel_work_dir="$2"
      shift 2
      ;;
    --output)
      required_arg "$1" "${2:-}"
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$mode" in
  bootstrap|finalize) ;;
  *) usage >&2; exit 2 ;;
esac

[ -f "$baseline" ] && [ ! -L "$baseline" ] || die "baseline must be a regular file"
[ -n "$archives_dir" ] || die "--archives-dir is required"
[ -n "$index_cache_dir" ] || die "--index-cache-dir is required"
[ -n "$retained_lists_dir" ] || die "--retained-lists-dir is required"
[ -n "$work_dir" ] || die "--work-dir is required"
[ -n "$kernel_work_dir" ] || die "--kernel-work-dir is required"
work_dir="$(canonical_directory "$work_dir" "work directory")"
archives_dir="$(canonical_directory "$archives_dir" "APT archives directory")"
index_cache_dir="$(canonical_directory "$index_cache_dir" "APT index cache directory")"
retained_lists_dir="$(canonical_directory "$retained_lists_dir" "retained APT lists directory")"
kernel_work_dir="$(canonical_directory "$kernel_work_dir" "kernel work directory")"
[ "$archives_dir" = "$work_dir/apt-archives" ] ||
  die "APT archives directory must be the exact work-dir/apt-archives child"
[ "$index_cache_dir" = "$work_dir/apt-indexes" ] ||
  die "APT index cache directory must be the exact work-dir/apt-indexes child"
[ "$retained_lists_dir" = "$work_dir/apt-lists" ] ||
  die "retained APT lists directory must be the exact work-dir/apt-lists child"

for rejected_override in SP11_APT_ETC_DIR SP11_APT_LISTS_DIR SP11_APT_KEYRING; do
  if declare -p "$rejected_override" >/dev/null 2>&1; then
    die "$rejected_override is not a supported path override"
  fi
done
if declare -p APT_CONFIG >/dev/null 2>&1; then
  die "APT_CONFIG is not permitted for immutable APT acquisition"
fi

if [ -n "${SP11_APT_FIXTURE_ROOT:-}" ]; then
  fixture_root="${SP11_APT_FIXTURE_ROOT}"
  fixture_root="$(canonical_directory "$fixture_root" "APT fixture root")"
  temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root%/}"
  [ -d "$temp_root" ] || die "temporary root is not a directory"
  temp_root="$(cd "$temp_root" && pwd -P)"
  slash_tmp="$(cd /tmp && pwd -P)"
  fixture_parent="$(dirname "$fixture_root")"
  fixture_leaf="$(basename "$fixture_root")"
  case "$fixture_leaf" in
    sp11-apt-fixture.*) ;;
    *) die "APT fixture root must use the sp11-apt-fixture.* prefix" ;;
  esac
  if [ "$fixture_parent" != "$temp_root" ] && [ "$fixture_parent" != "$slash_tmp" ]; then
    die "APT fixture root must be one immediate child of the canonical temporary root"
  fi
  [ "${SP11_APT_ALLOW_NON_ROOT_FIXTURE:-false}" = "true" ] ||
    die "fixture mode requires SP11_APT_ALLOW_NON_ROOT_FIXTURE=true"
  [ "$work_dir" = "$fixture_root/work" ] ||
    die "fixture work directory must be the exact fixture-root/work child"
  [ "$kernel_work_dir" = "$fixture_root/kernel-work" ] ||
    die "fixture kernel work directory must be the exact fixture-root/kernel-work child"
  apt_etc_dir="$fixture_root/etc/apt"
  apt_lists_dir="$fixture_root/var/lib/apt/lists"
  archive_keyring="$fixture_root/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  ca_bundle="$fixture_root/etc/ssl/certs/ca-certificates.crt"
else
  [ -z "${SP11_APT_HELPER:-}" ] || die "SP11_APT_HELPER is fixture-only"
  apt_etc_dir="/etc/apt"
  apt_lists_dir="/var/lib/apt/lists"
  archive_keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  ca_bundle="/etc/ssl/certs/ca-certificates.crt"
fi

apt_etc_dir="$(canonical_directory "$apt_etc_dir" "APT configuration root")"
apt_lists_dir="$(canonical_directory "$apt_lists_dir" "APT lists directory")"
archive_keyring_parent="$(canonical_directory "$(dirname "$archive_keyring")" "APT keyring directory")"
[ "$archive_keyring_parent/$(basename "$archive_keyring")" = "$archive_keyring" ] ||
  die "APT keyring path is not canonical"

# shellcheck disable=SC1090
. "$baseline"

for variable in \
  SP11_APT_SNAPSHOT_ID SP11_APT_SNAPSHOT_URI SP11_APT_SNAPSHOT_SUITES \
  SP11_APT_SNAPSHOT_COMPONENTS SP11_APT_SNAPSHOT_ARCHITECTURE \
  SP11_APT_ARCHIVE_KEYRING_SHA256 SP11_APT_ARCHIVE_SIGNING_FINGERPRINT \
  SP11_APT_INRELEASE_RESOLUTE_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256 \
  SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256 \
  SP11_APT_AUTHENTICATED_INDEX_COUNT \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256 \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_1_PATH \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_2_PATH \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_3_PATH \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_4_PATH \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_5_PATH \
  SP11_APT_DECOMPRESSED_EMPTY_INDEX_6_PATH \
  SP11_APT_PYTHON_PACKAGE_SPEC \
  SP11_APT_BOOTSTRAP_PACKAGE_COUNT; do
  [ -n "${!variable:-}" ] || die "baseline variable is empty or missing: $variable"
done
[ "$SP11_APT_SNAPSHOT_URI" = "https://snapshot.ubuntu.com/ubuntu/$SP11_APT_SNAPSHOT_ID/" ] ||
  die "snapshot URI and ID are inconsistent"
[ "$SP11_APT_SNAPSHOT_SUITES" = "resolute resolute-updates resolute-backports resolute-security" ] ||
  die "snapshot suite set or order changed"
[ "$SP11_APT_SNAPSHOT_COMPONENTS" = "main universe restricted multiverse" ] ||
  die "snapshot component set or order changed"
[ "$SP11_APT_SNAPSHOT_ARCHITECTURE" = "arm64" ] || die "snapshot architecture must be arm64"
[ "$SP11_APT_AUTHENTICATED_INDEX_COUNT" = "32" ] || die "authenticated index count must be 32"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_COUNT" = "6" ] ||
  die "decompressed-empty index count must be six"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_SIZE" = "20" ] ||
  die "decompressed-empty index gzip size must be 20"
[ "$SP11_APT_DECOMPRESSED_EMPTY_INDEX_SHA256" = \
  "9ceffb7310338057cfe71a4ae1e2c98d2c485d81cdef906532a801f457a38d64" ] ||
  die "decompressed-empty index gzip hash changed"
reviewed_empty_index_paths=(
  "resolute-backports/main/binary-arm64/Packages.gz"
  "resolute-backports/main/source/Sources.gz"
  "resolute-backports/restricted/binary-arm64/Packages.gz"
  "resolute-backports/restricted/source/Sources.gz"
  "resolute-backports/multiverse/binary-arm64/Packages.gz"
  "resolute-backports/multiverse/source/Sources.gz"
)
for empty_index in "${!reviewed_empty_index_paths[@]}"; do
  variable="SP11_APT_DECOMPRESSED_EMPTY_INDEX_$((empty_index + 1))_PATH"
  [ "${!variable}" = "${reviewed_empty_index_paths[$empty_index]}" ] ||
    die "$variable does not match the reviewed empty-index sequence"
done
[[ "$SP11_APT_PYTHON_PACKAGE_SPEC" =~ ^python3=[0-9A-Za-z.+:~_-]+$ ]] ||
  die "snapshot Python package must pin one exact python3 version"
[ "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" = "4" ] || die "bootstrap package count must be four"

expected_inrelease_sha() {
  case "$1" in
    resolute) printf '%s\n' "$SP11_APT_INRELEASE_RESOLUTE_SHA256" ;;
    resolute-updates) printf '%s\n' "$SP11_APT_INRELEASE_RESOLUTE_UPDATES_SHA256" ;;
    resolute-backports) printf '%s\n' "$SP11_APT_INRELEASE_RESOLUTE_BACKPORTS_SHA256" ;;
    resolute-security) printf '%s\n' "$SP11_APT_INRELEASE_RESOLUTE_SECURITY_SHA256" ;;
    *) return 1 ;;
  esac
}

verify_snapshot_metadata() {
  local suite file expected_sha actual_sha status count

  [ -f "$archive_keyring" ] && [ ! -L "$archive_keyring" ] ||
    die "Ubuntu archive keyring is missing or unsafe"
  [ "$(sha256_file "$archive_keyring")" = "$SP11_APT_ARCHIVE_KEYRING_SHA256" ] ||
    die "Ubuntu archive keyring does not match the baseline"

  count=0
  for suite in $SP11_APT_SNAPSHOT_SUITES; do
    file="$apt_lists_dir/snapshot.ubuntu.com_ubuntu_${SP11_APT_SNAPSHOT_ID}_dists_${suite}_InRelease"
    [ -f "$file" ] && [ ! -L "$file" ] || die "missing regular InRelease for $suite"
    expected_sha="$(expected_inrelease_sha "$suite")" || die "unsupported suite: $suite"
    actual_sha="$(sha256_file "$file")"
    [ "$actual_sha" = "$expected_sha" ] || die "InRelease hash mismatch for $suite"
    status="$(gpgv --status-fd=1 --keyring "$archive_keyring" "$file" 2>/dev/null)" ||
      die "InRelease signature verification failed for $suite"
    printf '%s\n' "$status" |
      grep -Fq "[GNUPG:] VALIDSIG $SP11_APT_ARCHIVE_SIGNING_FINGERPRINT " ||
      die "InRelease signing fingerprint mismatch for $suite"
    grep -Fxq 'Origin: Ubuntu' "$file" || die "unexpected InRelease origin for $suite"
    grep -Fxq "Suite: $suite" "$file" || die "unexpected InRelease suite for $suite"
    grep -Fxq 'Codename: resolute' "$file" || die "unexpected InRelease codename for $suite"
    grep -Eq '(^|[[:space:]])arm64([[:space:]]|$)' < <(grep '^Architectures:' "$file") ||
      die "InRelease does not advertise arm64 for $suite"
    grep -Fxq 'Acquire-By-Hash: yes' "$file" ||
      die "InRelease does not advertise by-hash for $suite"
    if grep -q '^Valid-Until:' "$file"; then
      die "reviewed snapshot unexpectedly gained a Valid-Until field for $suite"
    fi
    count=$((count + 1))
  done
  [ "$count" -eq 4 ] || die "expected exactly four InRelease files"
}

write_apt_configuration() {
  local sources_dir source_tmp config_dir config_tmp source_file
  sources_dir="$apt_etc_dir/sources.list.d"
  config_dir="$apt_etc_dir/apt.conf.d"
  canonical_directory "$sources_dir" "APT sources directory" >/dev/null
  canonical_directory "$config_dir" "APT configuration directory" >/dev/null

  if [ -e "$apt_etc_dir/sources.list" ]; then
    [ -f "$apt_etc_dir/sources.list" ] && [ ! -L "$apt_etc_dir/sources.list" ] ||
      die "unsafe legacy APT sources path"
    rm -f -- "$apt_etc_dir/sources.list"
  fi
  while IFS= read -r source_file; do
    [ -f "$source_file" ] && [ ! -L "$source_file" ] ||
      die "unsafe existing APT source entry: $source_file"
    rm -f -- "$source_file"
  done < <(find "$sources_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)

  source_tmp="$(mktemp "$sources_dir/.sp11-snapshot.XXXXXX")"
  {
    printf 'Types: deb deb-src\n'
    printf 'URIs: %s\n' "$SP11_APT_SNAPSHOT_URI"
    printf 'Suites: %s\n' "$SP11_APT_SNAPSHOT_SUITES"
    printf 'Components: %s\n' "$SP11_APT_SNAPSHOT_COMPONENTS"
    printf 'Architectures: %s\n' "$SP11_APT_SNAPSHOT_ARCHITECTURE"
    printf 'Signed-By: %s\n' "$archive_keyring"
    printf 'InRelease-Path: InRelease\n'
    printf 'By-Hash: force\n'
    printf 'PDiffs: no\n'
    printf 'Check-Valid-Until: yes\n'
  } > "$source_tmp"
  chmod 0644 "$source_tmp"
  mv -f -- "$source_tmp" "$sources_dir/sp11-immutable-snapshot.sources"

  config_tmp="$(mktemp "$config_dir/.sp11-snapshot.XXXXXX")"
  {
    printf 'Dir::Etc::sourcelist "%s/sources.list";\n' "$apt_etc_dir"
    printf 'Dir::Etc::sourceparts "%s/sources.list.d";\n' "$apt_etc_dir"
    printf 'Dir::Cache::archives "%s/";\n' "$archives_dir"
    printf 'APT::Update::Error-Mode "any";\n'
    printf 'Acquire::AllowInsecureRepositories "false";\n'
    printf 'Acquire::AllowDowngradeToInsecureRepositories "false";\n'
    printf 'Acquire::https::Verify-Peer "true";\n'
    printf 'Acquire::https::Verify-Host "true";\n'
    printf 'Acquire::By-Hash "force";\n'
    printf 'Acquire::PDiffs "false";\n'
    printf 'Acquire::Languages "none";\n'
    printf 'Acquire::GzipIndexes "true";\n'
    printf 'Acquire::CompressionTypes::Order { "gz"; };\n'
    printf 'Acquire::IndexTargets::deb::Contents-deb::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::Contents-udeb::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::CNF::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11-icons-hidpi::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";\n'
    printf 'Acquire::IndexTargets::deb::DEP-11-icons-large-hidpi::DefaultEnabled "false";\n'
    printf 'Binary::apt-get::APT::Keep-Downloaded-Packages "true";\n'
    printf 'APT::Keep-Downloaded-Packages "true";\n'
  } > "$config_tmp"
  chmod 0644 "$config_tmp"
  mv -f -- "$config_tmp" "$config_dir/99sp11-immutable-snapshot"
}

clear_apt_lists() {
  local entry
  canonical_directory "$apt_lists_dir" "APT lists directory" >/dev/null
  while IFS= read -r entry; do
    case "$entry" in
      "$apt_lists_dir"/*) ;;
      *) die "refusing unexpected APT list path" ;;
    esac
    [ ! -L "$entry" ] || die "refusing symlinked APT list entry: $entry"
    [ -f "$entry" ] || [ -d "$entry" ] || die "refusing special APT list entry: $entry"
    rm -rf -- "$entry"
  done < <(find "$apt_lists_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
  mkdir -p "$apt_lists_dir/partial"
}

capture_package_inventory() {
  local destination="$1" temporary
  temporary="$(mktemp "$work_dir/.sp11-package-inventory.XXXXXX")"
  if ! LC_ALL=C dpkg-query -W \
    -f='${db:Status-Abbrev} ${Package}:${Architecture}=${Version}\n' 2>/dev/null |
    awk '$1 == "ii" { print $2 }' |
    LC_ALL=C sort > "$temporary"; then
    rm -f -- "$temporary"
    die "could not capture installed package inventory"
  fi
  [ -s "$temporary" ] || { rm -f -- "$temporary"; die "installed package inventory is empty"; }
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

verify_bootstrap_debs() {
  local index spec package version expected_sha matches deb actual_sha
  local seen=0 total=0 spec_variable sha_variable

  while IFS= read -r deb; do
    [ -n "$deb" ] || continue
    total=$((total + 1))
  done < <(find "$archives_dir" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print | LC_ALL=C sort)
  [ "$total" -eq "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ] ||
    die "bootstrap cache must contain exactly four Debs; found $total"

  index=1
  while [ "$index" -le "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ]; do
    spec_variable="SP11_APT_BOOTSTRAP_PACKAGE_${index}_SPEC"
    sha_variable="SP11_APT_BOOTSTRAP_PACKAGE_${index}_SHA256"
    spec="${!spec_variable}"
    expected_sha="${!sha_variable}"
    package="${spec%%=*}"
    version="${spec#*=}"
    matches=0
    while IFS= read -r deb; do
      [ -n "$deb" ] || continue
      [ "$(dpkg-deb -f "$deb" Package)" = "$package" ] || continue
      [ "$(dpkg-deb -f "$deb" Version)" = "$version" ] || continue
      actual_sha="$(sha256_file "$deb")"
      [ "$actual_sha" = "$expected_sha" ] || die "bootstrap package hash mismatch: $package"
      matches=$((matches + 1))
      seen=$((seen + 1))
    done < <(find "$archives_dir" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print | LC_ALL=C sort)
    [ "$matches" -eq 1 ] || die "expected one cached bootstrap package for $spec"
    index=$((index + 1))
  done
  [ "$seen" -eq "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ] ||
    die "bootstrap cache contains an unexpected package set"
}

snapshot_apt_lists() {
  local entry target
  if find "$retained_lists_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    die "retained APT lists directory must start empty"
  fi
  while IFS= read -r entry; do
    [ ! -L "$entry" ] || die "refusing symlinked APT list target during retention"
    target="$retained_lists_dir/$(basename "$entry")"
    if [ -f "$entry" ]; then
      cp -- "$entry" "$target"
      [ -f "$target" ] && [ ! -L "$target" ] || die "could not retain APT list target"
    elif [ -d "$entry" ]; then
      case "$(basename "$entry")" in
        partial|auxfiles) ;;
        *) die "unexpected APT list directory during retention: $entry" ;;
      esac
      if find "$entry" -mindepth 1 -print | grep -q .; then
        die "APT list directory is not empty during retention: $entry"
      fi
      mkdir "$target"
    else
      die "refusing special APT list target during retention: $entry"
    fi
  done < <(find "$apt_lists_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
}

bootstrap() {
  local state_tmp index spec_variable spec bootstrap_specs=() pre_inventory
  local python_package python_version installed_python_version

  if [ "$(id -u)" -ne 0 ] && [ "${SP11_APT_ALLOW_NON_ROOT_FIXTURE:-false}" != "true" ]; then
    die "bootstrap must run as root inside the disposable build container"
  fi
  for tool in apt-get dpkg-deb dpkg-query find gpgv grep mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required bootstrap tool: $tool"
  done
  if find "$archives_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    die "release APT archive directory must start empty"
  fi
  if find "$index_cache_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    die "release APT index cache must start empty"
  fi
  if find "$retained_lists_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    die "retained APT lists directory must start empty"
  fi
  mkdir "$archives_dir/partial"
  pre_inventory="$work_dir/sp11-apt-installed-pre.txt"
  [ ! -e "$pre_inventory" ] || die "pre-install package inventory already exists"
  capture_package_inventory "$pre_inventory"
  write_apt_configuration
  clear_apt_lists

  # The digest-pinned minimal Ubuntu image has no populated CA bundle. This
  # exception is restricted to the signed bootstrap; all metadata identities
  # are checked before the exact CA packages are installed.
  apt-get --error-on=any -o Acquire::https::Verify-Peer=false update
  verify_snapshot_metadata

  index=1
  while [ "$index" -le "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ]; do
    spec_variable="SP11_APT_BOOTSTRAP_PACKAGE_${index}_SPEC"
    spec="${!spec_variable}"
    bootstrap_specs+=("$spec")
    index=$((index + 1))
  done
  apt-get -y --download-only --no-install-recommends \
    -o Acquire::https::Verify-Peer=false install "${bootstrap_specs[@]}"
  verify_bootstrap_debs
  apt-get -y --no-download --no-install-recommends install "${bootstrap_specs[@]}"
  index=1
  while [ "$index" -le "$SP11_APT_BOOTSTRAP_PACKAGE_COUNT" ]; do
    spec_variable="SP11_APT_BOOTSTRAP_PACKAGE_${index}_SPEC"
    spec="${!spec_variable}"
    [ "$(dpkg-query -W -f='${Version}' "${spec%%=*}")" = "${spec#*=}" ] ||
      die "installed bootstrap version mismatch: ${spec%%=*}"
    index=$((index + 1))
  done
  [ -f "$ca_bundle" ] && [ ! -L "$ca_bundle" ] && [ -s "$ca_bundle" ] ||
    die "CA bootstrap did not produce a populated, regular CA bundle"

  clear_apt_lists
  apt-get --error-on=any update
  verify_snapshot_metadata
  apt-get -y --no-install-recommends install "$SP11_APT_PYTHON_PACKAGE_SPEC"
  python_package="${SP11_APT_PYTHON_PACKAGE_SPEC%%=*}"
  python_version="${SP11_APT_PYTHON_PACKAGE_SPEC#*=}"
  if ! installed_python_version="$(
    dpkg-query -W -f='${Version}' "$python_package" 2>/dev/null
  )"; then
    die "authenticated snapshot Python package was not installed: $python_package"
  fi
  [ "$installed_python_version" = "$python_version" ] ||
    die "authenticated snapshot Python package version does not match the baseline"
  command -v python3 >/dev/null 2>&1 ||
    die "authenticated snapshot Python installation did not provide python3"
  python3 "$repo_dir/scripts/write-sp11-apt-provenance.py" acquire-indexes \
    --baseline "$baseline" \
    --lists-dir "$apt_lists_dir" \
    --index-cache-dir "$index_cache_dir"

  state_tmp="$(mktemp "$work_dir/.sp11-apt-bootstrap-state.XXXXXX")"
  {
    printf 'APT bootstrap state schema: sp11-immutable-apt-bootstrap-v1\n'
    printf 'Snapshot ID: %s\n' "$SP11_APT_SNAPSHOT_ID"
    printf 'Strict HTTPS recheck: true\n'
    printf 'Pre-install inventory path: sp11-apt-installed-pre.txt\n'
    printf 'Pre-install inventory size: %s\n' "$(file_size "$pre_inventory")"
    printf 'Pre-install inventory SHA256: %s\n' "$(sha256_file "$pre_inventory")"
  } > "$state_tmp"
  chmod 0644 "$state_tmp"
  mv -f -- "$state_tmp" "$work_dir/sp11-apt-bootstrap-state.txt"
}

finalize() {
  local state="$work_dir/sp11-apt-bootstrap-state.txt" pre_inventory post_inventory
  [ -n "$output" ] || die "finalize requires --output"
  [ "$output" = "$work_dir/artifacts/sp11-kernel-apt-provenance.txt" ] ||
    die "APT provenance output must be the exact work-dir artifacts path"
  [ -d "$work_dir/artifacts" ] && [ ! -L "$work_dir/artifacts" ] ||
    die "APT provenance artifact directory is unsafe"
  [ ! -e "$output" ] || die "APT provenance output already exists"
  [ -f "$state" ] && [ ! -L "$state" ] || die "immutable APT bootstrap state is missing"
  [ "$(wc -l < "$state" | tr -d ' ')" = "6" ] || die "invalid immutable APT bootstrap state field count"
  grep -Fxq 'APT bootstrap state schema: sp11-immutable-apt-bootstrap-v1' "$state" ||
    die "invalid immutable APT bootstrap state"
  grep -Fxq "Snapshot ID: $SP11_APT_SNAPSHOT_ID" "$state" || die "bootstrap snapshot ID changed"
  grep -Fxq 'Strict HTTPS recheck: true' "$state" ||
    die "strict HTTPS bootstrap recheck was not completed"
  grep -Fxq 'Pre-install inventory path: sp11-apt-installed-pre.txt' "$state" ||
    die "invalid pre-install inventory path"
  pre_inventory="$work_dir/sp11-apt-installed-pre.txt"
  [ -f "$pre_inventory" ] && [ ! -L "$pre_inventory" ] || die "pre-install inventory is missing"
  grep -Fxq "Pre-install inventory size: $(file_size "$pre_inventory")" "$state" ||
    die "pre-install inventory size changed"
  grep -Fxq "Pre-install inventory SHA256: $(sha256_file "$pre_inventory")" "$state" ||
    die "pre-install inventory hash changed"
  verify_snapshot_metadata
  command -v python3 >/dev/null 2>&1 || die "python3 is required to finalize APT provenance"
  post_inventory="$work_dir/sp11-apt-installed-post.txt"
  [ ! -e "$post_inventory" ] || die "post-install package inventory already exists"
  capture_package_inventory "$post_inventory"
  snapshot_apt_lists
  python3 "$repo_dir/scripts/write-sp11-apt-provenance.py" write \
    --baseline "$baseline" \
    --archives-dir "$archives_dir" \
    --lists-dir "$retained_lists_dir" \
    --index-cache-dir "$index_cache_dir" \
    --local-build-deps-dir "$work_dir/artifacts" \
    --pre-inventory "$pre_inventory" \
    --post-inventory "$post_inventory" \
    --output "$output"
}

case "$mode" in
  bootstrap) bootstrap ;;
  finalize) finalize ;;
esac
