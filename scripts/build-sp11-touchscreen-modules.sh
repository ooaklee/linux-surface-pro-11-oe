#!/usr/bin/env bash
set -euo pipefail

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
INSTALL="false"
OFFLINE="false"
ALLOW_UNSUPPORTED_RELEASE="false"
WINDOWS_SE_INIT="false"

usage() {
  cat <<EOF
Usage: $0 [options]

Builds the pinned geocausa Phase 91 gpi, spi-geni-qcom, and
mshw0485_touch modules for a Surface Pro 11 touchscreen kernel.

Options:
  --release VER       Target kernel release. By default, use the running v3
                      release or the sole installed sp11v3 release.
  --source-dir DIR    Managed geocausa checkout, default $SOURCE_DIR.
  --source-url URL    Source repository, default $GIT_URL.
  --source-ref REF    Immutable source commit, default $GIT_REF.
  --out-dir DIR       Module output directory, default $OUT_DIR.
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
if [[ ! "$GIT_REF" =~ ^[0-9A-Fa-f]{40}([0-9A-Fa-f]{24})?$ ]]; then
  die "--source-ref must be an immutable 40- or 64-character hexadecimal commit"
fi
GIT_REF="${GIT_REF,,}"

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

KVER_DIR="/lib/modules/$RELEASE"
KDIR="$KVER_DIR/build"
[ -d "$KDIR" ] || die "no headers found at $KDIR; install linux-headers-$RELEASE"
[ -s "$KDIR/Module.symvers" ] || die "missing or empty $KDIR/Module.symvers"
[ -r "$KDIR/include/config/kernel.release" ] || die "missing $KDIR/include/config/kernel.release"
header_release="$(<"$KDIR/include/config/kernel.release")"
[ "$header_release" = "$RELEASE" ] || die "header tree is for $header_release, not $RELEASE"

config=""
for candidate in "$KDIR/.config" "/boot/config-$RELEASE"; do
  if [ -r "$candidate" ]; then
    config="$candidate"
    break
  fi
done
[ -n "$config" ] || die "cannot find the exact kernel configuration for $RELEASE"
grep -qx 'CONFIG_MODULES=y' "$config" || die "CONFIG_MODULES is not enabled for $RELEASE"
grep -qx 'CONFIG_QCOM_GPI_DMA=m' "$config" || die "CONFIG_QCOM_GPI_DMA must be a replaceable module"
grep -qx 'CONFIG_SPI_QCOM_GENI=m' "$config" || die "CONFIG_SPI_QCOM_GENI must be a replaceable module"
if grep -qx 'CONFIG_MODULE_SIG_FORCE=y' "$config"; then
  die "CONFIG_MODULE_SIG_FORCE rejects these unsigned experimental modules"
fi

require_tool git
require_tool install
require_tool make
require_tool modinfo
require_tool sha256sum

if [ -e "$SOURCE_DIR" ] && [ ! -d "$SOURCE_DIR/.git" ]; then
  die "source directory exists but is not a git checkout: $SOURCE_DIR"
fi

new_checkout="false"
if [ ! -d "$SOURCE_DIR/.git" ]; then
  [ "$OFFLINE" != "true" ] || die "offline source checkout not found: $SOURCE_DIR"
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone --filter=blob:none --no-checkout "$GIT_URL" "$SOURCE_DIR"
  new_checkout="true"
fi

actual_origin="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
[ "$actual_origin" = "$GIT_URL" ] || die "source origin is $actual_origin, expected $GIT_URL"
if [ "$new_checkout" != "true" ] && \
  [ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]; then
  die "source checkout has local changes; use a clean checkout: $SOURCE_DIR"
fi

if [ "$OFFLINE" = "true" ]; then
  source_commit="$(git -C "$SOURCE_DIR" rev-parse --verify "$GIT_REF^{commit}" 2>/dev/null || true)"
  [ -n "$source_commit" ] || die "source ref $GIT_REF is unavailable in offline checkout"
else
  git -C "$SOURCE_DIR" fetch --depth 1 origin "$GIT_REF"
  source_commit="$(git -C "$SOURCE_DIR" rev-parse --verify 'FETCH_HEAD^{commit}')"
fi
git -C "$SOURCE_DIR" checkout --detach "$source_commit"
if [ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]; then
  die "source checkout is not clean after selecting $source_commit"
fi

module_source="$SOURCE_DIR/phase55/modules"
[ -f "$module_source/Makefile" ] || die "pinned source lacks $module_source/Makefile"

# Phase 91's Makefile guard names its original 7.1.3 validation kernel. We
# supply and independently verify the exact target release here; the guarded
# installer performs the runtime and initramfs checks before declaring success.
make -C "$module_source" \
  KDIR="$KDIR" \
  EXPECTED_KERNEL_RELEASE="$RELEASE" \
  ALLOW_UNTESTED_KERNEL=1

mkdir -p "$OUT_DIR"
for module in gpi spi-geni-qcom mshw0485_touch; do
  built="$module_source/$module.ko"
  [ -s "$built" ] || die "build did not produce $built"
  actual_name="$(modinfo -F name "$built")"
  case "$module:$actual_name" in
    gpi:gpi|spi-geni-qcom:spi_geni_qcom|mshw0485_touch:mshw0485_touch) ;;
    *) die "$module.ko has unexpected module name $actual_name" ;;
  esac
  actual_release="$(modinfo -F vermagic "$built" | awk '{print $1}')"
  [ "$actual_release" = "$RELEASE" ] || die "$module.ko was built for $actual_release, not $RELEASE"
  [ -n "$(modinfo -F srcversion "$built")" ] || die "$module.ko has no srcversion"
  install -m 0644 "$built" "$OUT_DIR/$module.ko"
done

modinfo -p "$OUT_DIR/spi-geni-qcom.ko" | grep -q '^sp11_windows_se_init:' || \
  die "spi-geni-qcom.ko lacks the expected SP11 controller parameter"
modinfo -F alias "$OUT_DIR/mshw0485_touch.ko" | grep -q 'microsoft,mshw0485' || \
  die "mshw0485_touch.ko lacks the Surface Pro 11 device-tree alias"

manifest="$OUT_DIR/sp11-touchscreen-modules-manifest.txt"
{
  echo "# Surface Pro 11 Touchscreen Module Build Manifest"
  echo
  echo "Source URL: $GIT_URL"
  echo "Source ref: $GIT_REF"
  echo "Source commit: $source_commit"
  echo "Target release: $RELEASE"
  echo "Windows SE init default: disabled"
  echo
  echo "## Modules"
  for module in gpi spi-geni-qcom mshw0485_touch; do
    file="$OUT_DIR/$module.ko"
    echo
    echo "- $module.ko"
    echo "  - Name: $(modinfo -F name "$file")"
    echo "  - Srcversion: $(modinfo -F srcversion "$file")"
    echo "  - Vermagic: $(modinfo -F vermagic "$file")"
    echo "  - SHA256: $(sha256sum "$file" | awk '{print $1}')"
  done
} > "$manifest"

echo "Built and verified touchscreen modules for $RELEASE in $OUT_DIR/."
echo "Pinned source commit: $source_commit"

if [ "$INSTALL" = "true" ]; then
  installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-sp11-touchscreen.sh"
  [ -x "$installer" ] || die "missing guarded installer: $installer"
  install_args=(--modules-dir "$OUT_DIR" --release "$RELEASE")
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
