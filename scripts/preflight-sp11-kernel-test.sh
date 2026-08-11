#!/usr/bin/env bash
set -euo pipefail

DEB_DIR=""
TARGET_ABI=""
FALLBACK_ABI=""
ROOT_DIR="/"
RUNNING_RELEASE=""
GRUB_CFG=""
DPKG_DEB_CMD="${SP11_PREFLIGHT_DPKG_DEB:-dpkg-deb}"
RUNNING_RELEASE_EXPLICIT="false"
GRUB_CFG_EXPLICIT="false"
DPKG_DEB_EXPLICIT="false"

if [ -n "${SP11_PREFLIGHT_DPKG_DEB:-}" ]; then
  DPKG_DEB_EXPLICIT="true"
fi

usage() {
  cat <<'EOF'
Usage: preflight-sp11-kernel-test.sh \
  --deb-dir DIR \
  --target-abi ABI \
  --fallback-abi ABI \
  [--root DIR] \
  [--running-release ABI] \
  [--grub-cfg FILE] \
  [--dpkg-deb COMMAND]

Performs a read-only safety check before testing a trusted, self-built,
distinct-ABI Surface Pro 11 qcom-x1e kernel bundle. The bundle directory must
be flat and contain exactly the image, modules, flavour headers, and common
headers .deb packages for the target ABI.

The fallback ABI must be running now and must have a non-empty kernel image,
initrd, module tree, and exactly one ABI-labelled non-recovery GRUB menu entry.
The target ABI must be different and must not already have installed boot
artifacts.

This helper never installs packages, updates initramfs, changes GRUB, refreshes
support files, or reboots the machine. It does not audit package payload paths
or simulate a package-manager transaction.

Options used by fixture tests and offline inspection:
  --root DIR              Alternate filesystem root; default /.
  --running-release ABI   Override uname -r; requires an alternate root.
  --grub-cfg FILE         Alternate GRUB path; requires an alternate root.
  --dpkg-deb COMMAND      Alternate command; requires an alternate root.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_arg() {
  if [ -z "${2:-}" ]; then
    echo "Missing value for $1." >&2
    usage >&2
    exit 2
  fi
}

validate_abi() {
  local label="$1"
  local abi="$2"

  case "$abi" in
    ""|*[!A-Za-z0-9._+~-]*)
      die "$label ABI contains unsupported characters: $abi"
      ;;
  esac

  case "$abi" in
    [A-Za-z0-9]*-qcom-x1e)
      ;;
    *)
      die "$label ABI must end in -qcom-x1e and start with an alphanumeric character: $abi"
      ;;
  esac
}

root_path() {
  local relative_path="$1"

  if [ "$ROOT_DIR" = "/" ]; then
    printf '/%s\n' "$relative_path"
  else
    printf '%s/%s\n' "${ROOT_DIR%/}" "$relative_path"
  fi
}

deb_field() {
  local deb="$1"
  local field="$2"
  local value=""

  if ! value="$("$DPKG_DEB_CMD" -f "$deb" "$field")"; then
    echo "Could not read $field from $(basename "$deb")." >&2
    return 1
  fi

  value="${value%$'\r'}"
  printf '%s\n' "$value"
}

dependency_records() {
  local depends="$1"

  printf '%s\n' "$depends" | awk '
    BEGIN { RS = "[,|]" }
    {
      atom = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", atom)
      if (atom == "")
        next

      name = atom
      sub(/[[:space:]]*\(.*/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      sub(/:[A-Za-z0-9-]+$/, "", name)

      constraint = ""
      if (match(atom, /\([^)]*\)/)) {
        constraint = substr(atom, RSTART + 1, RLENGTH - 2)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", constraint)
      }

      print name "\t" constraint
    }
  '
}

dependency_has_package() {
  local depends="$1"
  local expected="$2"

  dependency_records "$depends" | awk -F '\t' -v expected="$expected" '
    $1 == expected { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

validate_local_dependencies() {
  local owner="$1"
  local depends="$2"
  local bundle_version="$3"
  local expected_image="$4"
  local expected_modules="$5"
  local expected_headers="$6"
  local expected_common_headers="$7"
  local dependency=""
  local constraint=""
  local is_local="false"

  while IFS=$'\t' read -r dependency constraint; do
    [ -n "$dependency" ] || continue
    is_local="false"

    case "$dependency" in
      "$expected_image"|"$expected_modules"|"$expected_headers"|"$expected_common_headers")
        is_local="true"
        ;;
      linux-image-*-qcom-x1e|linux-modules-*-qcom-x1e|linux-headers-*-qcom-x1e|linux-qcom-x1e-headers-*)
        die "$owner depends on a package outside the target ABI bundle: $dependency"
        ;;
    esac

    if [ "$is_local" = "true" ] && [ -n "$constraint" ] && [ "$constraint" != "= $bundle_version" ]; then
      die "$owner has a non-exact or mismatched local dependency constraint: $dependency ($constraint)"
    fi
  done < <(dependency_records "$depends")
}

count_grub_entries() {
  local abi="$1"
  local include_recovery="$2"
  local require_abi_in_title="$3"
  local require_initrd="$4"

  awk -v abi="$abi" -v kernel_needle="vmlinuz-$abi" \
    -v initrd_needle="initrd.img-$abi" \
    -v include_recovery="$include_recovery" \
    -v require_abi_in_title="$require_abi_in_title" \
    -v require_initrd="$require_initrd" '
    function finish_entry() {
      if (in_entry && kernel_matched && (!require_initrd || initrd_matched) &&
          (include_recovery || !recovery) &&
          (!require_abi_in_title || title_has_abi))
        count++
    }

    function has_path_token(line, needle, fields, count_fields, index_field, token) {
      count_fields = split(line, fields, /[[:space:]]+/)
      for (index_field = 1; index_field <= count_fields; index_field++) {
        token = fields[index_field]
        if (length(token) >= length(needle) &&
            substr(token, length(token) - length(needle) + 1) == needle)
          return 1
      }
      return 0
    }

    /^[[:space:]]*menuentry[[:space:]]/ {
      finish_entry()
      in_entry = 1
      kernel_matched = 0
      initrd_matched = 0
      recovery = index(tolower($0), "recovery") > 0
      title_has_abi = index($0, abi) > 0
      next
    }

    in_entry && /^[[:space:]]*linux(efi)?[[:space:]]/ {
      if (has_path_token($0, kernel_needle))
        kernel_matched = 1
    }

    in_entry && /^[[:space:]]*initrd(efi)?[[:space:]]/ {
      if (has_path_token($0, initrd_needle))
        initrd_matched = 1
    }

    END {
      finish_entry()
      print count + 0
    }
  ' "$GRUB_CFG"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --deb-dir)
      require_arg "$1" "${2:-}"
      DEB_DIR="$2"
      shift 2
      ;;
    --target-abi)
      require_arg "$1" "${2:-}"
      TARGET_ABI="$2"
      shift 2
      ;;
    --fallback-abi)
      require_arg "$1" "${2:-}"
      FALLBACK_ABI="$2"
      shift 2
      ;;
    --root)
      require_arg "$1" "${2:-}"
      ROOT_DIR="$2"
      shift 2
      ;;
    --running-release)
      require_arg "$1" "${2:-}"
      RUNNING_RELEASE="$2"
      RUNNING_RELEASE_EXPLICIT="true"
      shift 2
      ;;
    --grub-cfg)
      require_arg "$1" "${2:-}"
      GRUB_CFG="$2"
      GRUB_CFG_EXPLICIT="true"
      shift 2
      ;;
    --dpkg-deb)
      require_arg "$1" "${2:-}"
      DPKG_DEB_CMD="$2"
      DPKG_DEB_EXPLICIT="true"
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

[ -n "$DEB_DIR" ] || die "--deb-dir is required."
[ -n "$TARGET_ABI" ] || die "--target-abi is required."
[ -n "$FALLBACK_ABI" ] || die "--fallback-abi is required."

validate_abi "Target" "$TARGET_ABI"
validate_abi "Fallback" "$FALLBACK_ABI"

if [ "$TARGET_ABI" = "$FALLBACK_ABI" ]; then
  die "Target ABI must differ from fallback ABI: $TARGET_ABI"
fi

case "$ROOT_DIR" in
  /*)
    ;;
  *)
    die "--root must be an absolute path: $ROOT_DIR"
    ;;
esac

[ -d "$ROOT_DIR" ] || die "Filesystem root not found: $ROOT_DIR"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"

if [ "$ROOT_DIR" = "/" ]; then
  if [ "$RUNNING_RELEASE_EXPLICIT" = "true" ]; then
    die "--running-release is allowed only with an alternate --root fixture."
  fi
  if [ "$GRUB_CFG_EXPLICIT" = "true" ]; then
    die "--grub-cfg is allowed only with an alternate --root fixture."
  fi
  if [ "$DPKG_DEB_EXPLICIT" = "true" ]; then
    die "A dpkg-deb override is allowed only with an alternate --root fixture."
  fi
fi

[ ! -L "$DEB_DIR" ] || die "Bundle directory must not be a symlink: $DEB_DIR"
[ -d "$DEB_DIR" ] || die "Bundle directory not found: $DEB_DIR"
DEB_DIR="$(cd "$DEB_DIR" && pwd -P)"

case "$DPKG_DEB_CMD" in
  */*)
    [ -x "$DPKG_DEB_CMD" ] || die "dpkg-deb command is not executable: $DPKG_DEB_CMD"
    ;;
  *)
    command -v "$DPKG_DEB_CMD" >/dev/null 2>&1 || die "Missing required command: $DPKG_DEB_CMD"
    ;;
esac

if [ -z "$RUNNING_RELEASE" ]; then
  RUNNING_RELEASE="$(uname -r)"
  running_release_source="uname -r"
else
  running_release_source="the alternate-root fixture override"
fi

if [ "$RUNNING_RELEASE" != "$FALLBACK_ABI" ]; then
  die "Running ABI must exactly match fallback ABI (running: $RUNNING_RELEASE; fallback: $FALLBACK_ABI)."
fi

if [ "$TARGET_ABI" = "$RUNNING_RELEASE" ]; then
  die "Target ABI must not be the running ABI: $TARGET_ABI"
fi

if [ -z "$GRUB_CFG" ]; then
  GRUB_CFG="$(root_path boot/grub/grub.cfg)"
fi

debs=()
deb_count=0
shopt -s nullglob dotglob
for entry in "$DEB_DIR"/*; do
  if [ -L "$entry" ]; then
    die "Bundle directory contains a symlink and is not isolated: $(basename "$entry")"
  fi
  if [ ! -f "$entry" ]; then
    die "Bundle directory must be flat and contain only regular files: $(basename "$entry")"
  fi

  case "$(basename "$entry")" in
    *.ko|*.ko.xz|*.ko.zst)
      die "Bundle directory contains a stale top-level kernel module: $(basename "$entry")"
      ;;
    *.deb)
      debs[$deb_count]="$entry"
      deb_count=$((deb_count + 1))
      ;;
  esac
done
shopt -u dotglob

if [ "$deb_count" -ne 4 ]; then
  die "Bundle directory must contain exactly four top-level .deb files; found $deb_count."
fi

abi_base="${TARGET_ABI%-qcom-x1e}"
expected_image="linux-image-$TARGET_ABI"
expected_modules="linux-modules-$TARGET_ABI"
expected_headers="linux-headers-$TARGET_ABI"
expected_common_headers="linux-qcom-x1e-headers-$abi_base"

image_file=""
modules_file=""
headers_file=""
common_headers_file=""
image_depends=""
modules_depends=""
headers_depends=""
common_headers_depends=""
bundle_version=""

for deb in "${debs[@]}"; do
  package="$(deb_field "$deb" Package)" || exit 1
  version="$(deb_field "$deb" Version)" || exit 1
  architecture="$(deb_field "$deb" Architecture)" || exit 1
  depends="$(deb_field "$deb" Depends)" || exit 1

  [ -n "$package" ] || die "Package metadata is empty in $(basename "$deb")."
  [ -n "$version" ] || die "Version metadata is empty in $(basename "$deb")."
  [ -n "$architecture" ] || die "Architecture metadata is empty in $(basename "$deb")."

  if [ -z "$bundle_version" ]; then
    bundle_version="$version"
  elif [ "$version" != "$bundle_version" ]; then
    die "Bundle contains mixed package versions ($bundle_version and $version)."
  fi

  case "$package" in
    "$expected_image")
      [ -z "$image_file" ] || die "Bundle contains duplicate image packages for $TARGET_ABI."
      [ "$architecture" = "arm64" ] || die "$package must have architecture arm64; found $architecture."
      image_file="$deb"
      image_depends="$depends"
      ;;
    "$expected_modules")
      [ -z "$modules_file" ] || die "Bundle contains duplicate modules packages for $TARGET_ABI."
      [ "$architecture" = "arm64" ] || die "$package must have architecture arm64; found $architecture."
      modules_file="$deb"
      modules_depends="$depends"
      ;;
    "$expected_headers")
      [ -z "$headers_file" ] || die "Bundle contains duplicate flavour header packages for $TARGET_ABI."
      [ "$architecture" = "arm64" ] || die "$package must have architecture arm64; found $architecture."
      headers_file="$deb"
      headers_depends="$depends"
      ;;
    "$expected_common_headers")
      [ -z "$common_headers_file" ] || die "Bundle contains duplicate common header packages for $TARGET_ABI."
      [ "$architecture" = "all" ] || die "$package must have architecture all; found $architecture."
      common_headers_file="$deb"
      common_headers_depends="$depends"
      ;;
    *)
      die "Bundle contains an unexpected package for target ABI $TARGET_ABI: $package"
      ;;
  esac
done

[ -n "$image_file" ] || die "Bundle is missing $expected_image."
[ -n "$modules_file" ] || die "Bundle is missing $expected_modules."
[ -n "$headers_file" ] || die "Bundle is missing $expected_headers."
[ -n "$common_headers_file" ] || die "Bundle is missing $expected_common_headers."

if ! dependency_has_package "$image_depends" "$expected_modules"; then
  die "$expected_image must depend on $expected_modules."
fi
if ! dependency_has_package "$headers_depends" "$expected_common_headers"; then
  die "$expected_headers must depend on $expected_common_headers."
fi

validate_local_dependencies "$expected_image" "$image_depends" "$bundle_version" \
  "$expected_image" "$expected_modules" "$expected_headers" "$expected_common_headers"
validate_local_dependencies "$expected_modules" "$modules_depends" "$bundle_version" \
  "$expected_image" "$expected_modules" "$expected_headers" "$expected_common_headers"
validate_local_dependencies "$expected_headers" "$headers_depends" "$bundle_version" \
  "$expected_image" "$expected_modules" "$expected_headers" "$expected_common_headers"
validate_local_dependencies "$expected_common_headers" "$common_headers_depends" "$bundle_version" \
  "$expected_image" "$expected_modules" "$expected_headers" "$expected_common_headers"

fallback_image="$(root_path "boot/vmlinuz-$FALLBACK_ABI")"
fallback_initrd="$(root_path "boot/initrd.img-$FALLBACK_ABI")"

[ ! -L "$fallback_image" ] && [ -f "$fallback_image" ] && [ -s "$fallback_image" ] && [ -r "$fallback_image" ] || \
  die "Fallback kernel image is missing, empty, unreadable, or a symlink: $fallback_image"
[ ! -L "$fallback_initrd" ] && [ -f "$fallback_initrd" ] && [ -s "$fallback_initrd" ] && [ -r "$fallback_initrd" ] || \
  die "Fallback initrd is missing, empty, unreadable, or a symlink: $fallback_initrd"

fallback_modules=""
fallback_module_dir_seen="false"
first_module_file=""
for module_dir in "$(root_path "lib/modules/$FALLBACK_ABI")" "$(root_path "usr/lib/modules/$FALLBACK_ABI")"; do
  if [ -d "$module_dir" ]; then
    fallback_module_dir_seen="true"
    if ! first_module_file="$(find "$module_dir" -type f \
      \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
      -size +0c -print -quit)"; then
      die "Could not inspect fallback module tree: $module_dir"
    fi
    modules_dep="$module_dir/modules.dep"
    if [ -n "$first_module_file" ] && [ ! -L "$modules_dep" ] && \
      [ -f "$modules_dep" ] && [ -s "$modules_dep" ] && [ -r "$modules_dep" ]; then
      fallback_modules="$module_dir"
      break
    fi
  fi
done

if [ "$fallback_module_dir_seen" != "true" ]; then
  die "Fallback module tree is missing for $FALLBACK_ABI."
fi
[ -n "$fallback_modules" ] || \
  die "Fallback module tree lacks a loadable module or non-empty modules.dep for $FALLBACK_ABI."

[ ! -L "$GRUB_CFG" ] && [ -f "$GRUB_CFG" ] && [ -s "$GRUB_CFG" ] && [ -r "$GRUB_CFG" ] || \
  die "GRUB configuration is missing, empty, unreadable, or a symlink: $GRUB_CFG"

fallback_entry_count="$(count_grub_entries "$FALLBACK_ABI" 0 1 1)"
if [ "$fallback_entry_count" -ne 1 ]; then
  die "Expected exactly one non-recovery, ABI-labelled GRUB entry for fallback ABI $FALLBACK_ABI; found $fallback_entry_count."
fi

target_image="$(root_path "boot/vmlinuz-$TARGET_ABI")"
target_initrd="$(root_path "boot/initrd.img-$TARGET_ABI")"
if [ -e "$target_image" ] || [ -L "$target_image" ] || [ -e "$target_initrd" ] || [ -L "$target_initrd" ]; then
  die "Target ABI already has boot artifacts; choose a fresh ABI: $TARGET_ABI"
fi
for target_module_dir in "$(root_path "lib/modules/$TARGET_ABI")" "$(root_path "usr/lib/modules/$TARGET_ABI")"; do
  if [ -e "$target_module_dir" ] || [ -L "$target_module_dir" ]; then
    die "Target ABI already has a module tree; choose a fresh ABI: $TARGET_ABI"
  fi
done

target_entry_count="$(count_grub_entries "$TARGET_ABI" 1 0 0)"
if [ "$target_entry_count" -ne 0 ]; then
  die "Target ABI already has GRUB entries; choose a fresh ABI: $TARGET_ABI"
fi

cat <<EOF
SP11 distinct-ABI kernel test preflight passed.
  Bundle version: $bundle_version
  Target ABI:     $TARGET_ABI
  Fallback ABI:   $FALLBACK_ABI (matches $running_release_source)
  GRUB fallback:  one non-recovery, ABI-labelled entry

No packages were installed and no boot or support files were changed.
EOF
