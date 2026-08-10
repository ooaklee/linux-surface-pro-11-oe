#!/usr/bin/env bash
set -uo pipefail

RELEASE_DIR=""
TAG=""
REMOTE=""
ERROR_COUNT=0
CHECK_COUNT=0
TEMP_DIRS=()

usage() {
  cat <<EOF
Usage: $0 --dir DIR [--tag TAG] [--remote REMOTE]

Validates a prepared or downloaded Surface Pro 11 qcom-x1e kernel release
directory without changing it.

Options:
  --dir DIR        Flat directory containing the release assets (required).
  --tag TAG        Compare the manifest support commit with this Git tag.
  --remote REMOTE  Also compare with TAG on this Git remote name or URL.
                   Requires --tag.
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
[ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR"
[ ! -L "$RELEASE_DIR" ] || die "release directory must not be a symlink: $RELEASE_DIR"

if ! RELEASE_DIR="$(cd "$RELEASE_DIR" 2>/dev/null && pwd -P)"; then
  die "could not resolve release directory: $RELEASE_DIR"
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
declare -A ROLE_COUNTS=([image]=0 [modules]=0 [headers]=0 [common_headers]=0)
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
    linux-image-*_arm64.deb)
      role="image"
      stem="${base%_arm64.deb}"
      version="${stem##*_}"
      package_part="${stem%_$version}"
      abi="${package_part#linux-image-}"
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

kernel_abi="${ROLE_ABIS[image]:-}"
package_version="${ROLE_VERSIONS[image]:-}"
if [ -n "$kernel_abi" ]; then
  case "$kernel_abi" in
    *-qcom-x1e) ;;
    *) error "kernel ABI is not a qcom-x1e ABI: $kernel_abi" ;;
  esac
fi
for role in modules headers common_headers; do
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
    for role in image modules headers common_headers; do
      [ "${ROLE_COUNTS[$role]}" -eq 1 ] || continue
      deb="${ROLE_FILES[$role]}"
      case "$role" in
        image) expected_package="linux-image-${ROLE_ABIS[$role]}"; expected_arch="arm64" ;;
        modules) expected_package="linux-modules-${ROLE_ABIS[$role]}"; expected_arch="arm64" ;;
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
    grep -Eq '^- patches/.+\.patch$' "$release_manifest" || \
      error "publishable release manifest does not record repository-relative patch assets."
    checked
  fi

  for deb in "${deb_files[@]}"; do
    base="$(basename "$deb")"
    sha="$(sha256_file "$deb" 2>/dev/null || true)"
    grep -Fq -- "- $base" "$release_manifest" || \
      error "release manifest does not list package $base."
    [ -z "$sha" ] || grep -Fiq -- "SHA256: $sha" "$release_manifest" || \
      error "release manifest does not record the actual SHA-256 for $base."
  done
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
    if local_target="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null)"; then
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
      if ! remote_output="$(git -C "$repo_dir" ls-remote --exit-code --tags "$REMOTE" \
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
        grep -Fq -- "- $module_file" "$touchscreen_manifest" || \
          error "touchscreen provenance does not list $module_file."
        [ -z "$module_sha" ] || grep -Fiq -- "SHA256: $module_sha" "$touchscreen_manifest" || \
          error "touchscreen provenance does not record the actual SHA-256 for $module_file."
        grep -Fq -- "$module_srcversion" "$touchscreen_manifest" || \
          error "touchscreen provenance does not record the srcversion for $module_file."
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
fi

echo "Validated directory: $RELEASE_DIR"
if [ -n "$kernel_abi" ]; then
  echo "Kernel ABI: $kernel_abi"
  echo "Package version: $package_version"
fi
echo "Successful checks: $CHECK_COUNT"

if [ "$ERROR_COUNT" -ne 0 ]; then
  echo "Release validation failed with $ERROR_COUNT error(s)." >&2
  exit 1
fi

echo "Release validation passed."
