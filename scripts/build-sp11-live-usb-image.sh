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
umask 022

ISO=""
DTB="auto"
OUT="build/sp11-ubuntu-live.img"
PAYLOAD_DIR="payload/kernel-debs"
WORK_DIR="build/work"
IMAGE_EXTRA_MB=1536
VALIDATE="false"
VALIDATE_IMAGE=""
GRUB_MODE="menu"
DESKTOP="gnome"
ISO_SOURCE_URL=""
EXPECTED_ISO_SHA256=""
IMAGE_BUILD_MANIFEST=""
BUILD_STAGE=""
OUTPUT_TEMP=""
MANIFEST_TEMP=""
VALIDATION_STAGE=""
BUILD_IMAGE="ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03"
BUILD_PLATFORM="linux/arm64/v8"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
validation_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

cleanup() {
  if [ -n "$OUTPUT_TEMP" ]; then
    case "$OUTPUT_TEMP" in
      "${repo_dir:-}"/build/.*.image-output.*) rm -f -- "$OUTPUT_TEMP" ;;
      *) echo "Warning: refusing to remove unexpected image output temporary file: $OUTPUT_TEMP" >&2 ;;
    esac
  fi
  if [ -n "$MANIFEST_TEMP" ]; then
    case "$MANIFEST_TEMP" in
      "${repo_dir:-}"/build/.*.image-output.*) rm -f -- "$MANIFEST_TEMP" ;;
      *) echo "Warning: refusing to remove unexpected image manifest temporary file: $MANIFEST_TEMP" >&2 ;;
    esac
  fi
  if [ -n "$BUILD_STAGE" ]; then
    case "$BUILD_STAGE" in
      "${repo_dir:-}"/build/*/.sp11-image-build.*) rm -rf -- "$BUILD_STAGE" ;;
      *) echo "Warning: refusing to remove unexpected image build stage: $BUILD_STAGE" >&2 ;;
    esac
  fi
  if [ -n "$VALIDATION_STAGE" ]; then
    case "$VALIDATION_STAGE" in
      "$validation_parent"/sp11-image-validation.*) rm -rf -- "$VALIDATION_STAGE" ;;
      *) echo "Warning: refusing to remove unexpected image validation stage: $VALIDATION_STAGE" >&2 ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<EOF
Usage: $0 --iso ISO [options]
       $0 --validate-image IMAGE

Options:
  --iso PATH_OR_URL      Ubuntu ARM64+X1E concept ISO.
  --iso-source-url URL   Public HTTPS provenance URL for a local ISO. When
                         --iso is HTTPS, that URL is recorded automatically.
  --expected-iso-sha256 SHA256
                         Expected SHA-256 of the downloaded/local input ISO.
                         Required for a publishable image-build manifest.
  --dtb PATH_OR_AUTO     Surface Pro 11 Denali DTB, default auto.
  --out PATH             Output raw disk image, default $OUT.
  --build-manifest PATH  Image-build manifest output. Defaults beside --out.
  --payload DIR          Kernel payload directory, must be payload/kernel-debs.
  --work-dir DIR         Temporary build directory, default $WORK_DIR.
  --extra-mb MB          Free space on data partition, default $IMAGE_EXTRA_MB.
  --grub-mode MODE       GRUB config mode: menu or direct, default $GRUB_MODE.
  --desktop DESKTOP      Desktop flavor to ship in the live ISO:
                           gnome  Use the concept ISO as-is (default).
                           kde    Remaster the concept ISO's casper squashfs
                                  to install kubuntu-desktop. Experimental;
                                  needs network in the build container and
                                  roughly doubles build time and image size.
  --validate             Validate the finished image after building.
  --validate-image PATH  Validate an existing image and exit.

The builder uses Docker with an ARM64 Ubuntu container so macOS can create a
bootable ARM64 GRUB image without loop-mounting Linux filesystems locally.
When --dtb auto is used, the builder tries to extract an X1E Surface Pro 11
Denali DTB from the ISO's files or casper squashfs layers.
EOF
}

validate_image() {
  local image="$1"
  local expect_kernel_debs image_dir image_base strict_extractor

  if [ ! -s "$image" ] || [ ! -f "$image" ] || [ -L "$image" ]; then
    echo "Image must be a non-empty regular, non-symlinked file: $image" >&2
    exit 1
  fi

  expect_kernel_debs="${SP11_EXPECT_KERNEL_DEBS:-false}"
  image_dir="$(cd "$(dirname "$image")" && pwd)"
  image_base="$(basename "$image")"
  strict_extractor="$repo_dir/scripts/extract-sp11-image-bindings.sh"
  [ -f "$strict_extractor" ] && [ ! -L "$strict_extractor" ] || {
    echo "Missing regular strict image-binding extractor." >&2
    exit 1
  }
  VALIDATION_STAGE="$(mktemp -d "$validation_parent/sp11-image-validation.XXXXXX")"
  chmod 700 "$VALIDATION_STAGE"

  docker run --rm -i --platform "$BUILD_PLATFORM" \
    -e "SP11_EXPECT_KERNEL_DEBS=$expect_kernel_debs" \
    -v "$image_dir:/image:ro" \
    -v "$strict_extractor:/validator/extract-sp11-image-bindings.sh:ro" \
    -v "$VALIDATION_STAGE:/validation-output" \
    "$BUILD_IMAGE" \
    bash -s -- "$image_base" <<'EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  binutils \
  coreutils \
  file \
  gdisk \
  mtools \
  parted \
  sleuthkit \
  >/dev/null

image="/image/$1"
expect_kernel_debs="${SP11_EXPECT_KERNEL_DEBS:-false}"
layout="$(mktemp)"
dtb_copy="$(mktemp)"
boot_copy="$(mktemp)"
touchscreen_bundle="false"

bash /validator/extract-sp11-image-bindings.sh \
  --image "$image" --output-dir /validation-output
binding_output_count=0
for binding_output_name in \
  actual-payload-sha256 \
  embedded-support-manifest \
  actual-support-identities \
  actual-image-layout \
  actual-embedded-iso-sha256 \
  actual-embedded-dtb-sha256 \
  actual-esp-boot-size \
  actual-esp-boot-sha256 \
  actual-esp-readme-size \
  actual-esp-readme-sha256; do
  binding_output="/validation-output/$binding_output_name"
  [ -f "$binding_output" ] && [ ! -L "$binding_output" ] || {
    echo "Strict image validator produced an unsafe output: $binding_output_name" >&2
    exit 1
  }
  chmod 0644 "$binding_output"
  binding_output_count=$((binding_output_count + 1))
done
[ "$(find /validation-output -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" = \
  "$binding_output_count" ] || {
    echo 'Strict image validator produced an unexpected output.' >&2
    exit 1
  }

echo "== Image =="
ls -lh "$image"
du -h "$image"
sha256sum "$image"
file "$image"

echo
echo "== GPT =="
sgdisk -p "$image"
sgdisk -v "$image"
parted -sm "$image" unit s print | tee "$layout"

esp_start="$(awk -F: '$1 == "1" { gsub(/s$/, "", $2); print $2 }' "$layout")"
data_start="$(awk -F: '$1 == "2" { gsub(/s$/, "", $2); print $2 }' "$layout")"

if [ -z "$esp_start" ] || [ -z "$data_start" ]; then
  echo "Could not determine ESP/data partition offsets." >&2
  exit 1
fi

echo
echo "== ESP =="
mdir -i "$image@@$((esp_start * 512))" ::/
mdir -i "$image@@$((esp_start * 512))" ::/EFI/BOOT
mcopy -i "$image@@$((esp_start * 512))" ::/EFI/BOOT/BOOTAA64.EFI "$boot_copy"
strings "$boot_copy" |
  grep -E "sp11_grub_mode|USB-safe|casper iso-scan|ISO-native|insmod fdt|sp11-denali" |
  sed -n "1,120p"

echo
echo "== Data Partition =="
fls -o "$data_start" "$image"
dtb_inode="$(
  fls -o "$data_start" "$image" |
    awk '$3 == "dtb" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$dtb_inode" ]; then
  echo "Missing /dtb directory on SP11DATA." >&2
  exit 1
fi

fls -o "$data_start" "$image" "$dtb_inode"
dtb_file_inode="$(
  fls -o "$data_start" "$image" "$dtb_inode" |
    awk '$3 == "sp11-denali.dtb" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$dtb_file_inode" ]; then
  echo "Missing /dtb/sp11-denali.dtb on SP11DATA." >&2
  exit 1
fi

icat -o "$data_start" "$image" "$dtb_file_inode" > "$dtb_copy"
ls -lh "$dtb_copy"
sha256sum "$dtb_copy"
file "$dtb_copy"

payload_inode="$(
  fls -o "$data_start" "$image" |
    awk '$3 == "payload" { sub(/:/, "", $2); print $2; exit }'
)"
if [ -z "$payload_inode" ]; then
  if [ "$expect_kernel_debs" = "true" ]; then
    echo "Missing /payload on SP11DATA; expected kernel deb payload." >&2
    exit 1
  fi
elif [ -n "$payload_inode" ]; then
  echo
  echo "== Payload =="
  fls -o "$data_start" "$image" "$payload_inode"
  kernel_debs_inode="$(
    fls -o "$data_start" "$image" "$payload_inode" |
      awk '$3 == "kernel-debs" { sub(/:/, "", $2); print $2; exit }'
  )"
  if [ -z "$kernel_debs_inode" ]; then
    if [ "$expect_kernel_debs" = "true" ]; then
      echo "Missing /payload/kernel-debs on SP11DATA; expected kernel deb payload." >&2
      exit 1
    fi
  elif [ -n "$kernel_debs_inode" ]; then
    kernel_debs_listing="$(mktemp)"
    fls -o "$data_start" "$image" "$kernel_debs_inode" | tee "$kernel_debs_listing"
    if ! awk '$3 ~ /\.deb$/ { found = 1 } END { exit found ? 0 : 1 }' "$kernel_debs_listing"; then
      echo "Missing .deb files under /payload/kernel-debs on SP11DATA." >&2
      exit 1
    fi
    if awk '$3 ~ /sp11v3.*\.deb$/ { found = 1 } END { exit found ? 0 : 1 }' "$kernel_debs_listing"; then
      touchscreen_bundle="true"
      for payload_asset in \
        gpi.ko \
        spi-geni-qcom.ko \
        mshw0485_touch.ko \
        sp11-touchscreen-modules-manifest.txt \
        sp11-module-signing-cert.x509; do
        if ! awk -v module="$payload_asset" '$3 == module { found = 1 } END { exit found ? 0 : 1 }' \
          "$kernel_debs_listing"; then
          echo "Incomplete sp11v3 payload: missing /payload/kernel-debs/$payload_asset." >&2
          exit 1
        fi
      done
    fi
  fi
fi

echo
echo "== Support Helpers =="
support_listing="$(mktemp)"
fls -r -p -o "$data_start" "$image" > "$support_listing"
install_helper_inode="$(
  awk '$0 ~ /support\/scripts\/install-sp11-support\.sh$/ { sub(/:/, "", $2); print $2; exit }' "$support_listing"
)"
if [ -z "$install_helper_inode" ]; then
  echo "Missing /support/scripts/install-sp11-support.sh on SP11DATA." >&2
  exit 1
fi

if [ "$touchscreen_bundle" = "true" ]; then
  touchscreen_helper_inode="$(
    awk '$0 ~ /support\/scripts\/install-sp11-touchscreen\.sh$/ { sub(/:/, "", $2); print $2; exit }' "$support_listing"
  )"
  if [ -z "$touchscreen_helper_inode" ]; then
    echo "The sp11v3 payload is missing /support/scripts/install-sp11-touchscreen.sh." >&2
    exit 1
  fi
fi

install_helper_copy="$(mktemp)"
icat -o "$data_start" "$image" "$install_helper_inode" > "$install_helper_copy"
if ! bash -n "$install_helper_copy"; then
  echo "Support helper has invalid shell syntax." >&2
  exit 1
fi
if ! grep -F -q 'retire_managed_loose_dtb_artifact' "$install_helper_copy"; then
  echo "Support helper is missing installed loose-DTB retirement." >&2
  exit 1
fi
if ! grep -F -q -- '--retire-loose-dtb-only' "$install_helper_copy"; then
  echo "Support helper is missing pre-package loose-DTB retirement mode." >&2
  exit 1
fi
for managed_path in \
  /usr/local/sbin/sp11-grub-inject-dtb \
  /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb \
  /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb; do
  if ! grep -F -q "$managed_path" "$install_helper_copy"; then
    echo "Support helper is missing managed retirement path: $managed_path" >&2
    exit 1
  fi
done
if grep -F -q 'update-grub || true' "$install_helper_copy"; then
  echo "Support helper still suppresses update-grub failure." >&2
  exit 1
fi
if grep -E -q 'support/scripts/sp11-grub-inject-dtb\.sh$' "$support_listing"; then
  echo "Retired installed loose-DTB injector is still present on SP11DATA." >&2
  exit 1
fi
grep -F -n 'retire_managed_loose_dtb_artifact' "$install_helper_copy" | sed -n '1,4p'
EOF

  echo
  echo "== Exact GPT/ESP identity =="
  cat "$VALIDATION_STAGE/actual-image-layout"
  rm -rf -- "$VALIDATION_STAGE"
  VALIDATION_STAGE=""
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      ISO="$2"
      shift 2
      ;;
    --iso-source-url)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      ISO_SOURCE_URL="$2"
      shift 2
      ;;
    --expected-iso-sha256)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      EXPECTED_ISO_SHA256="$2"
      shift 2
      ;;
    --dtb)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      DTB="$2"
      shift 2
      ;;
    --out)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      OUT="$2"
      shift 2
      ;;
    --build-manifest)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      IMAGE_BUILD_MANIFEST="$2"
      shift 2
      ;;
    --payload)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      PAYLOAD_DIR="$2"
      shift 2
      ;;
    --work-dir)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      WORK_DIR="$2"
      shift 2
      ;;
    --extra-mb)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      IMAGE_EXTRA_MB="$2"
      shift 2
      ;;
    --grub-mode)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      GRUB_MODE="$2"
      shift 2
      ;;
    --desktop)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      DESKTOP="$2"
      shift 2
      ;;
    --validate)
      VALIDATE="true"
      shift
      ;;
    --validate-image)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      VALIDATE_IMAGE="$2"
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

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required for the image builder and validator." >&2
  exit 1
fi

if [ -n "$VALIDATE_IMAGE" ]; then
  validate_image "$VALIDATE_IMAGE"
  exit 0
fi

if [ -z "$ISO" ]; then
  usage >&2
  exit 2
fi

case "$GRUB_MODE" in
  menu|direct)
    ;;
  *)
    echo "Invalid --grub-mode: $GRUB_MODE (expected menu or direct)" >&2
    exit 2
    ;;
esac

case "$DESKTOP" in
  gnome|kde)
    ;;
  *)
    echo "Invalid --desktop: $DESKTOP (expected gnome or kde)" >&2
    exit 2
    ;;
esac

case "$IMAGE_EXTRA_MB" in
  ""|*[!0-9]*) echo "--extra-mb must be a positive integer." >&2; exit 2 ;;
esac
if [ "$IMAGE_EXTRA_MB" -lt 1 ] || [ "$IMAGE_EXTRA_MB" -gt 32768 ]; then
  echo "--extra-mb must be between 1 and 32768 MiB." >&2
  exit 2
fi

validate_public_iso_url() {
  local value="$1" authority path
  case "$value" in
    https://*) ;;
    *) echo "ISO provenance URL must use HTTPS: $value" >&2; exit 2 ;;
  esac
  if [ "${#value}" -gt 2048 ]; then
    echo "ISO provenance URL exceeds the supported length." >&2
    exit 2
  fi
  case "$value" in
    *[[:space:]]*|*\?*|*\#*|*@*|*\'*|*\"*|*\`*|*\$*|*\\*|*[!A-Za-z0-9._~:/%+-]*)
      echo "ISO provenance URL must not contain credentials, controls, unsupported characters, a query, or a fragment." >&2
      exit 2
      ;;
  esac
  authority="${value#https://}"
  authority="${authority%%/*}"
  case "$authority" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*)
      echo "ISO provenance URL has an unsafe host." >&2
      exit 2
      ;;
    localhost|localhost.*|*.localhost|*.local|*.internal|*.invalid|*.test|*.example|*.onion)
      echo "ISO provenance URL must name a public host." >&2
      exit 2
      ;;
  esac
  case "$authority" in
    *[!0-9.]*) ;;
    *)
      echo "ISO provenance URL must use a public DNS host, not a numeric address." >&2
      exit 2
      ;;
  esac
  case "$authority" in
    *.*) ;;
    *) echo "ISO provenance URL must name a public fully-qualified host." >&2; exit 2 ;;
  esac
  path="${value#https://$authority}"
  case "$path" in
    /?*) ;;
    *) echo "ISO provenance URL must include an image path." >&2; exit 2 ;;
  esac
}

file_size() {
  local value
  if value="$(stat -f '%z' "$1" 2>/dev/null)"; then
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  fi
  if value="$(stat -c '%s' "$1" 2>/dev/null)"; then
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  fi
  echo "Could not determine a numeric file size: $1" >&2
  return 1
}

validate_safe_relative_path() {
  local value="$1" label="$2" component old_ifs
  case "$value" in
    ""|/*|*//*|*[!A-Za-z0-9._+/-]*)
      echo "$label must be a safe repository-relative path: $value" >&2
      exit 2
      ;;
  esac
  old_ifs="$IFS"
  IFS=/
  set -- $value
  IFS="$old_ifs"
  for component in "$@"; do
    case "$component" in
      ""|.|..) echo "$label contains an unsafe component: $value" >&2; exit 2 ;;
    esac
  done
}

reject_symlink_components() {
  local relative="$1" label="$2" current="$repo_dir" component old_ifs
  old_ifs="$IFS"
  IFS=/
  set -- $relative
  IFS="$old_ifs"
  for component in "$@"; do
    current="$current/$component"
    if [ -L "$current" ]; then
      echo "$label must not contain a symlink component: $relative" >&2
      exit 1
    fi
  done
}

for tool in git python3 shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done

validate_safe_relative_path "$WORK_DIR" "--work-dir"
case "$WORK_DIR" in
  build/*)
    work_leaf="${WORK_DIR#build/}"
    case "$work_leaf" in */*) echo "--work-dir must be a direct child of build/: $WORK_DIR" >&2; exit 2 ;; esac
    ;;
  *) echo "--work-dir must be a dedicated child of build/: $WORK_DIR" >&2; exit 2 ;;
esac
validate_safe_relative_path "$OUT" "--out"
case "$OUT" in
  build/*.img)
    out_leaf="${OUT#build/}"
    case "$out_leaf" in */*) echo "--out must be a direct child of build/: $OUT" >&2; exit 2 ;; esac
    ;;
  *) echo "--out must be an .img file directly under build/: $OUT" >&2; exit 2 ;;
esac
if [ -z "$IMAGE_BUILD_MANIFEST" ]; then
  IMAGE_BUILD_MANIFEST="build/sp11-live-image-build-manifest.txt"
fi
validate_safe_relative_path "$IMAGE_BUILD_MANIFEST" "--build-manifest"
case "$IMAGE_BUILD_MANIFEST" in
  build/*.txt)
    manifest_leaf="${IMAGE_BUILD_MANIFEST#build/}"
    case "$manifest_leaf" in */*) echo "--build-manifest must be directly under build/: $IMAGE_BUILD_MANIFEST" >&2; exit 2 ;; esac
    ;;
  *) echo "--build-manifest must be a .txt file directly under build/: $IMAGE_BUILD_MANIFEST" >&2; exit 2 ;;
esac
[ "$IMAGE_BUILD_MANIFEST" != "$OUT" ] || {
  echo "--build-manifest must differ from --out." >&2
  exit 2
}
validate_safe_relative_path "$PAYLOAD_DIR" "--payload"
[ "$PAYLOAD_DIR" = "payload/kernel-debs" ] || {
  echo "--payload must be the dedicated repository payload/kernel-debs directory: $PAYLOAD_DIR" >&2
  exit 2
}

reject_symlink_components "build" "build root"
reject_symlink_components "$WORK_DIR" "--work-dir"
reject_symlink_components "$OUT" "--out"
reject_symlink_components "$IMAGE_BUILD_MANIFEST" "--build-manifest"
reject_symlink_components "$PAYLOAD_DIR" "--payload"
mkdir -p "$repo_dir/build" "$repo_dir/$WORK_DIR"
[ -d "$repo_dir/$WORK_DIR" ] && [ ! -L "$repo_dir/$WORK_DIR" ] || {
  echo "--work-dir must resolve to a regular directory." >&2
  exit 1
}
work_root_abs="$(cd "$repo_dir/$WORK_DIR" && pwd -P)"
case "$work_root_abs" in
  "$repo_dir"/build/*) ;;
  *) echo "--work-dir resolved outside the repository build root." >&2; exit 1 ;;
esac
BUILD_STAGE="$(mktemp -d "$work_root_abs/.sp11-image-build.XXXXXX")"
chmod 700 "$BUILD_STAGE"
work_abs="$BUILD_STAGE"
out_abs="$repo_dir/$OUT"
manifest_abs="$repo_dir/$IMAGE_BUILD_MANIFEST"

if [ -e "$out_abs" ] && { [ -L "$out_abs" ] || [ ! -f "$out_abs" ]; }; then
  echo "--out must not replace a symlink or non-regular file: $OUT" >&2
  exit 1
fi
if [ -e "$manifest_abs" ] && { [ -L "$manifest_abs" ] || [ ! -f "$manifest_abs" ]; }; then
  echo "--build-manifest must not replace a symlink or non-regular file: $IMAGE_BUILD_MANIFEST" >&2
  exit 1
fi

payload_abs="$repo_dir/$PAYLOAD_DIR"
if [ -e "$payload_abs" ]; then
  [ -d "$payload_abs" ] && [ ! -L "$payload_abs" ] || {
    echo "--payload must resolve to a regular directory: $PAYLOAD_DIR" >&2
    exit 1
  }
  payload_abs="$(cd "$payload_abs" && pwd -P)"
  case "$payload_abs" in
    "$repo_dir/payload"|"$repo_dir/payload"/*) ;;
    *) echo "--payload resolved outside the repository payload root." >&2; exit 1 ;;
  esac
fi

iso_name="ubuntu-x1e.iso"
dtb_name="sp11-denali.dtb"

if [[ "$ISO" =~ ^https:// ]]; then
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required for an HTTPS --iso URL." >&2
    exit 1
  }
  [ -z "$ISO_SOURCE_URL" ] || [ "$ISO_SOURCE_URL" = "$ISO" ] || {
    echo "--iso-source-url must match an HTTPS --iso URL." >&2
    exit 2
  }
  ISO_SOURCE_URL="$ISO"
  validate_public_iso_url "$ISO_SOURCE_URL"
  echo "Downloading ISO..."
  curl --fail --location --proto '=https' --proto-redir '=https' \
    "$ISO" -o "$work_abs/$iso_name"
else
  case "$ISO" in http://*) echo "Plain-HTTP ISO downloads are not supported." >&2; exit 2 ;; esac
  if [ ! -s "$ISO" ] || [ ! -f "$ISO" ] || [ -L "$ISO" ]; then
    echo "Local ISO must be a non-empty regular, non-symlinked file: $ISO" >&2
    exit 1
  fi
  iso_input_dir="$(cd "$(dirname "$ISO")" && pwd -P)"
  iso_input="$iso_input_dir/$(basename "$ISO")"
  cp "$iso_input" "$work_abs/$iso_name"
  if [ -n "$ISO_SOURCE_URL" ]; then
    validate_public_iso_url "$ISO_SOURCE_URL"
  fi
fi
chmod 644 "$work_abs/$iso_name"
input_iso_sha="$(shasum -a 256 "$work_abs/$iso_name" | awk '{print $1}')"
if [ -n "$EXPECTED_ISO_SHA256" ]; then
  EXPECTED_ISO_SHA256="$(printf '%s' "$EXPECTED_ISO_SHA256" | tr '[:upper:]' '[:lower:]')"
  case "$EXPECTED_ISO_SHA256" in
    ""|*[!0-9a-f]*)
      echo "--expected-iso-sha256 must be exactly 64 hexadecimal characters." >&2
      exit 2
      ;;
  esac
  [ "${#EXPECTED_ISO_SHA256}" -eq 64 ] || {
    echo "--expected-iso-sha256 must be exactly 64 hexadecimal characters." >&2
    exit 2
  }
  [ "$input_iso_sha" = "$EXPECTED_ISO_SHA256" ] || {
    echo "Input ISO SHA-256 does not match --expected-iso-sha256." >&2
    exit 1
  }
fi

if [ "$DTB" != "auto" ]; then
  if [ ! -s "$DTB" ] || [ ! -f "$DTB" ] || [ -L "$DTB" ]; then
    echo "Explicit DTB must be a non-empty regular, non-symlinked file: $DTB" >&2
    exit 1
  fi
  dtb_input_dir="$(cd "$(dirname "$DTB")" && pwd -P)"
  dtb_input="$dtb_input_dir/$(basename "$DTB")"
  cp "$dtb_input" "$work_abs/$dtb_name"
  chmod 644 "$work_abs/$dtb_name"
  printf 'kernel-output:denali-oled-dtb\n' > "$work_abs/dtb-source.txt"
fi

if [ -d "$payload_abs" ]; then
  mkdir -p "$work_abs/payload/kernel-debs"
  if find "$payload_abs" -mindepth 1 ! -type f -print -quit | grep -q .; then
    echo "The kernel payload must contain only flat regular files." >&2
    exit 1
  fi
  payload_file_count=0
  while IFS= read -r payload_file; do
    payload_name="$(basename "$payload_file")"
    case "$payload_name" in
      ""|*[!A-Za-z0-9._+-]*) echo "Kernel payload has an unsafe filename: $payload_name" >&2; exit 1 ;;
    esac
    [ ! -L "$payload_file" ] || {
      echo "Kernel payload contains a symlink: $payload_name" >&2
      exit 1
    }
    cp "$payload_file" "$work_abs/payload/kernel-debs/$payload_name"
    chmod 644 "$work_abs/payload/kernel-debs/$payload_name"
    payload_file_count=$((payload_file_count + 1))
  done < <(find "$payload_abs" -mindepth 1 -maxdepth 1 -type f | LC_ALL=C sort)
  [ "$payload_file_count" -gt 0 ] || {
    echo "The kernel payload directory is empty." >&2
    exit 1
  }
fi

mkdir -p "$work_abs/support"
support_manifest_helper="$repo_dir/scripts/sp11-support-tree-manifest.py"
[ -f "$support_manifest_helper" ] && [ ! -L "$support_manifest_helper" ] || {
  echo "Missing regular committed-support manifest helper." >&2
  exit 1
}
support_commit="$(git -c "safe.directory=$repo_dir" -C "$repo_dir" \
  rev-parse --verify 'HEAD^{commit}')"
python3 "$support_manifest_helper" \
  --repo-dir "$repo_dir" \
  --commit "$support_commit" \
  --output "$work_abs/support/.sp11-support-tree-v1"
git -c "safe.directory=$repo_dir" -C "$repo_dir" archive --format=tar \
  "$support_commit" -- README.md docs patches scripts tools |
  tar -x -C "$work_abs/support"
python3 "$support_manifest_helper" \
  --repo-dir "$repo_dir" \
  --commit "$support_commit" \
  --normalize-directory "$work_abs/support"

write_grub_common() {
  cat <<'EOF'
insmod part_gpt
insmod fat
insmod ext2
insmod fdt
insmod loopback
insmod iso9660
insmod search
insmod search_fs_file
insmod search_label
insmod linux

set iso_path=/iso/ubuntu-x1e.iso
set dtb_path=/dtb/sp11-denali.dtb
set sp11_args="clk_ignore_unused pd_ignore_unused arm64.nopauth systemd.tpm2_wait=0"
set usb_safe_args="modprobe.blacklist=qcom_q6v5_pas"
EOF
}

write_grub_usb_safe_casper_boot() {
  cat <<'EOF'
search --label SP11DATA --set=data
set root=($data)
loopback loop ${iso_path}
linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} ${usb_safe_args} --- quiet splash console=tty0
devicetree ${dtb_path}
initrd (loop)/casper/initrd
EOF
}

if [ "$GRUB_MODE" = "direct" ]; then
{
  echo "# sp11_grub_mode=direct"
  echo
  write_grub_common
  echo
  echo 'echo "Surface Pro 11 direct boot: USB-safe casper iso-scan"'
  echo 'echo "Searching for SP11DATA..."'
  write_grub_usb_safe_casper_boot
  echo "boot"
} > "$work_abs/grub.cfg"
else
{
cat <<'EOF'
# sp11_grub_mode=menu
set timeout=10
set default=0

EOF
write_grub_common
cat <<'EOF'

menuentry "Ubuntu for Surface Pro 11 (USB-safe, casper iso-scan)" {
EOF
write_grub_usb_safe_casper_boot
cat <<'EOF'
}

menuentry "Ubuntu for Surface Pro 11 (USB-safe text/debug, casper iso-scan)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} ${usb_safe_args} debug systemd.unit=multi-user.target plymouth.enable=0 --- console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 (USB-safe, ISO-native fallback)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz ${sp11_args} ${usb_safe_args} --- quiet splash console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}

menuentry "Ubuntu for Surface Pro 11 (normal aDSP allowed, casper iso-scan)" {
    search --label SP11DATA --set=data
    set root=($data)
    loopback loop ${iso_path}
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=${iso_path} ${sp11_args} --- quiet splash console=tty0
    devicetree ${dtb_path}
    initrd (loop)/casper/initrd
}
EOF
} > "$work_abs/grub.cfg"
fi

cat > "$work_abs/build-inside.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
umask 022

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  coreutils \
  dosfstools \
  e2fsprogs \
  gdisk \
  grub-efi-arm64-bin \
  libarchive-tools \
  mtools \
  parted \
  squashfs-tools \
  xz-utils

cd /work
dtb_name="sp11-denali.dtb"

rm -rf esp data out
mkdir -p esp/EFI/BOOT data/iso data/dtb data/payload data/support out

# Optionally remaster the concept ISO to ship KDE Plasma instead of GNOME.
# There is no official Kubuntu ARM64 ISO, so we unsquashfs the casper
# filesystem layer, install kubuntu-desktop in a chroot, repack it, and
# rebuild the ISO with xorriso. This is experimental and roughly doubles
# build time and image size because the Plasma stack is large.
if [ "${SP11_DESKTOP:-gnome}" = "kde" ]; then
  echo "== Remastering concept ISO for KDE Plasma =="
  apt-get install -y --no-install-recommends \
    xorriso \
    >/dev/null

  remaster_dir=""
  chroot_dir=""
  iso_mount=""
  new_iso="/work/ubuntu-x1e-kde.iso"

  cleanup_kde_remaster() {
    set +e
    if [ -n "$chroot_dir" ] && [ -d "$chroot_dir/rootfs" ]; then
      umount "$chroot_dir/rootfs/run" 2>/dev/null || true
      umount "$chroot_dir/rootfs/dev" 2>/dev/null || true
      umount "$chroot_dir/rootfs/sys" 2>/dev/null || true
      umount "$chroot_dir/rootfs/proc" 2>/dev/null || true
    fi
    if [ -n "$iso_mount" ] && [ -d "$iso_mount" ]; then
      umount "$iso_mount" 2>/dev/null || true
      rmdir "$iso_mount" 2>/dev/null || true
    fi
    [ -n "$chroot_dir" ] && rm -rf "$chroot_dir"
    [ -n "$remaster_dir" ] && rm -rf "$remaster_dir"
    rm -f "$new_iso"
  }
  trap cleanup_kde_remaster EXIT

  remaster_dir="$(mktemp -d)"
  chroot_dir="$(mktemp -d)"
  iso_mount="$(mktemp -d)"

  # Mount the original ISO read-only to copy its full structure.
  mount -o loop,ro ubuntu-x1e.iso "$iso_mount"
  cp -a "$iso_mount/." "$remaster_dir/iso-tree"
  umount "$iso_mount"
  rmdir "$iso_mount"

  # Find the writable casper squashfs layer. The concept ISO ships a
  # layered set; the largest writable layer is the one we patch.
  layer=""
  layer_size=0
  for candidate in "$remaster_dir"/iso-tree/casper/*.squashfs; do
    [ -f "$candidate" ] || continue
    candidate_size="$(stat -c '%s' "$candidate")"
    if [ "$candidate_size" -gt "$layer_size" ]; then
      layer="$candidate"
      layer_size="$candidate_size"
    fi
  done
  if [ -z "$layer" ]; then
    echo "No casper squashfs layer found in ISO; cannot remaster for KDE." >&2
    exit 1
  fi
  echo "Remastering writable layer: $(basename "$layer")"

  unsquashfs -q -d "$chroot_dir/rootfs" "$layer"

  # Bind-mount the host kernel virtual filesystems for chroot.
  mount --bind /proc "$chroot_dir/rootfs/proc"
  mount --bind /sys "$chroot_dir/rootfs/sys"
  mount --bind /dev "$chroot_dir/rootfs/dev"
  mount --bind /run "$chroot_dir/rootfs/run" 2>/dev/null || true
  rm -f "$chroot_dir/rootfs/etc/resolv.conf"
  cp /etc/resolv.conf "$chroot_dir/rootfs/etc/resolv.conf"

  # Pre-seed SDDM so the kubuntu-desktop postinst does not block on a
  # debconf prompt and does not default to gdm3.
  echo "sddm shared/default-x-display-manager select sddm" | \
    chroot "$chroot_dir/rootfs" debconf-set-selections
  echo "sddm sddm/daemon_name string sddm" | \
    chroot "$chroot_dir/rootfs" debconf-set-selections

  chroot "$chroot_dir/rootfs" apt-get update
  DEBIAN_FRONTEND=noninteractive chroot "$chroot_dir/rootfs" \
    env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends kubuntu-desktop sddm

  # Switch the default display manager to SDDM inside the squashfs.
  if [ -x "$chroot_dir/rootfs/usr/bin/sddm" ]; then
    echo /usr/bin/sddm > "$chroot_dir/rootfs/etc/X11/default-display-manager"
    ln -sf /lib/systemd/system/sddm.service \
      "$chroot_dir/rootfs/etc/systemd/system/display-manager.service" 2>/dev/null || true
  fi

  chroot "$chroot_dir/rootfs" apt-get clean
  umount "$chroot_dir/rootfs/run" 2>/dev/null || true
  umount "$chroot_dir/rootfs/dev" 2>/dev/null || true
  umount "$chroot_dir/rootfs/sys" 2>/dev/null || true
  umount "$chroot_dir/rootfs/proc" 2>/dev/null || true

  # Repack the squashfs, preserving the original filename.
  rm -f "$layer"
  mksquashfs "$chroot_dir/rootfs" "$layer" -comp xz -noappend

  rm -rf "$chroot_dir"
  chroot_dir=""

  # Rebuild the ISO. The concept ISO is a standard isohybrid-ish layout;
  # xorriso -as mkisofs preserves the casper/efi/boot structure.
  xorriso -as mkisofs \
    -r -V "SP11 Ubuntu KDE" \
    -J -joliet-long \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -o "$new_iso" \
    "$remaster_dir/iso-tree"

  rm -rf "$remaster_dir"
  remaster_dir=""
  mv -f "$new_iso" ubuntu-x1e.iso
  trap - EXIT
  echo "== KDE remaster complete; using remastered ISO =="
fi

cp ubuntu-x1e.iso data/iso/ubuntu-x1e.iso

iso_members="$(mktemp)"
bsdtar -tf ubuntu-x1e.iso > "$iso_members"

for required in casper/vmlinuz casper/initrd; do
  if ! grep -qx "$required" "$iso_members"; then
    echo "ISO missing expected path: $required" >&2
    exit 1
  fi
done

dtb_candidates=(
  "x1e80100-microsoft-denali-oled.dtb"
  "x1e80100-microsoft-denali.dtb"
  "x1e80100-microsoft-denali-oled-el2.dtb"
)

extract_dtb_from_iso_member() {
  local name member
  for name in "${dtb_candidates[@]}"; do
    member="$(
      awk -F/ -v name="$name" '$NF == name { print; exit }' "$iso_members"
    )"
    if [ -n "$member" ]; then
      bsdtar -xOf ubuntu-x1e.iso "$member" > "data/dtb/$dtb_name"
      printf 'iso-member:%s\n' "$member" > /work/dtb-source.txt
      echo "Extracted Denali DTB from ISO member: $member"
      return 0
    fi
  done
  return 1
}

extract_dtb_from_squashfs_layers() {
  local layer name found inner_path tmp_layer tmp_root
  tmp_layer="$(mktemp)"
  tmp_root="$(mktemp -d)"

  for layer in $(grep -E '^casper/.*\.squashfs$' "$iso_members"); do
    echo "Searching DTB in $layer..."
    bsdtar -xOf ubuntu-x1e.iso "$layer" > "$tmp_layer"

    for name in "${dtb_candidates[@]}"; do
      found="$(
        unsquashfs -ll "$tmp_layer" 2>/dev/null |
          awk -F/ -v name="$name" '$NF == name { print $0; exit }' |
          awk '{ print $NF }'
      )"
      if [ -n "$found" ]; then
        inner_path="${found#squashfs-root/}"
        rm -rf "$tmp_root"
        mkdir -p "$tmp_root"
        unsquashfs -q -d "$tmp_root" "$tmp_layer" "$inner_path" >/dev/null
        cp "$tmp_root/$inner_path" "data/dtb/$dtb_name"
        printf 'squashfs:%s:%s\n' "$layer" "$inner_path" > /work/dtb-source.txt
        echo "Extracted Denali DTB from $layer: $inner_path"
        rm -f "$tmp_layer"
        rm -rf "$tmp_root"
        return 0
      fi
    done
  done

  rm -f "$tmp_layer"
  rm -rf "$tmp_root"
  return 1
}

if [ -f "$dtb_name" ]; then
  cp "$dtb_name" "data/dtb/$dtb_name"
elif ! extract_dtb_from_iso_member && ! extract_dtb_from_squashfs_layers; then
  echo "STATUS: DTB not found in ISO files or casper squashfs layers." >&2
  echo "Searched for: ${dtb_candidates[*]}" >&2
  echo "Re-run with --dtb /path/to/surface-pro-11-denali.dtb." >&2
  exit 1
fi

if [ -d payload ]; then
  cp -a payload/. data/payload/
fi
cp -a support/. data/support/

grub-mkstandalone \
  -O arm64-efi \
  -o esp/EFI/BOOT/BOOTAA64.EFI \
  --modules="part_gpt fat ext2 fdt loopback iso9660 search search_fs_file search_label linux normal configfile all_video gfxterm" \
  "boot/grub/grub.cfg=grub.cfg"

printf 'This USB boots Ubuntu for Surface Pro 11. See /support and /payload on SP11DATA.\n' > esp/README.txt

esp_mib=512
iso_mib=$(( ($(stat -c '%s' ubuntu-x1e.iso) + 1048575) / 1048576 ))
payload_mib=0
if [ -d payload ]; then
  payload_kib=$(du -sk payload | awk '{print $1}')
  payload_mib=$(( (payload_kib + 1023) / 1024 ))
fi
support_kib=$(du -sk support | awk '{print $1}')
support_mib=$(( (support_kib + 1023) / 1024 ))
extra_mib="${IMAGE_EXTRA_MB:-1536}"
data_mib=$(( iso_mib + payload_mib + support_mib + extra_mib ))
total_mib=$(( esp_mib + data_mib + 64 ))
total_sectors=$((total_mib * 2048))
data_partition_end=$((total_sectors - 2049))

truncate -s "${esp_mib}M" esp.img
mformat -i esp.img -F -v SP11EFI ::
mmd -i esp.img ::/EFI ::/EFI/BOOT
mcopy -i esp.img esp/EFI/BOOT/BOOTAA64.EFI ::/EFI/BOOT/
mcopy -i esp.img esp/README.txt ::/

truncate -s "${data_mib}M" data.ext4
mke2fs -q -t ext4 -L SP11DATA -d data data.ext4

out_img="out/sp11-ubuntu-live.img"
truncate -s "${total_mib}M" "$out_img"
sgdisk -o \
  -n 1:2048:+${esp_mib}M -t 1:EF00 -c 1:SP11EFI \
  -n 2:0:"$data_partition_end" -t 2:8300 -c 2:SP11DATA \
  "$out_img"

parted -sm "$out_img" unit s print > layout.txt
esp_start=$(awk -F: '$1 == "1" { gsub(/s$/, "", $2); print $2 }' layout.txt)
data_start=$(awk -F: '$1 == "2" { gsub(/s$/, "", $2); print $2 }' layout.txt)

dd if=esp.img of="$out_img" bs=4M seek="$((esp_start * 512))" oflag=seek_bytes conv=notrunc status=none
dd if=data.ext4 of="$out_img" bs=64M seek="$((data_start * 512))" oflag=seek_bytes conv=notrunc status=none

sgdisk -v "$out_img"
ls -lh "$out_img"
EOF
chmod +x "$work_abs/build-inside.sh"

docker run --rm --platform "$BUILD_PLATFORM" \
  -e IMAGE_EXTRA_MB="$IMAGE_EXTRA_MB" \
  -e SP11_DESKTOP="$DESKTOP" \
  -v "$work_abs:/work" \
  "$BUILD_IMAGE" \
  /work/build-inside.sh

stage_image="$work_abs/out/sp11-ubuntu-live.img"
embedded_iso="$work_abs/data/iso/$iso_name"
embedded_dtb="$work_abs/data/dtb/$dtb_name"
embedded_support_manifest="$work_abs/data/support/.sp11-support-tree-v1"
embedded_esp_boot="$work_abs/esp/EFI/BOOT/BOOTAA64.EFI"
embedded_esp_readme="$work_abs/esp/README.txt"
image_layout="$work_abs/layout.txt"
for embedded_file in \
  "$stage_image" "$embedded_iso" "$embedded_dtb" "$embedded_support_manifest" \
  "$embedded_esp_boot" "$embedded_esp_readme" "$image_layout"; do
  [ -s "$embedded_file" ] && [ -f "$embedded_file" ] && [ ! -L "$embedded_file" ] || {
    echo "Image build did not produce a required regular embedded artifact: $embedded_file" >&2
    exit 1
  }
done
[ -s "$work_abs/dtb-source.txt" ] && [ -f "$work_abs/dtb-source.txt" ] &&
  [ ! -L "$work_abs/dtb-source.txt" ] || {
  echo "Image build did not record the DTB source." >&2
  exit 1
}
dtb_source="$(sed -n '1p' "$work_abs/dtb-source.txt")"
case "$dtb_source" in
  ""|*[!A-Za-z0-9._+:/-]*) echo "Image build recorded an unsafe DTB source." >&2; exit 1 ;;
esac
embedded_iso_sha="$(shasum -a 256 "$embedded_iso" | awk '{print $1}')"
embedded_dtb_sha="$(shasum -a 256 "$embedded_dtb" | awk '{print $1}')"
support_manifest_sha="$(shasum -a 256 "$embedded_support_manifest" | awk '{print $1}')"
esp_boot_size="$(file_size "$embedded_esp_boot")"
esp_boot_sha="$(shasum -a 256 "$embedded_esp_boot" | awk '{print $1}')"
esp_readme_size="$(file_size "$embedded_esp_readme")"
esp_readme_sha="$(shasum -a 256 "$embedded_esp_readme" | awk '{print $1}')"
output_image_sha="$(shasum -a 256 "$stage_image" | awk '{print $1}')"
output_image_size="$(file_size "$stage_image")"
partition_table="$(awk -F: 'NR == 2 { print $6 }' "$image_layout")"
logical_sector_size="$(awk -F: 'NR == 2 { print $4 }' "$image_layout")"
partition_count="$(awk -F: '$1 ~ /^[0-9]+$/ { count++ } END { print count + 0 }' "$image_layout")"
layout_partition_value() {
  local number="$1" field="$2" value
  value="$(awk -F: -v number="$number" -v field="$field" \
    '$1 == number { print $field }' "$image_layout")"
  case "$field" in 2|3|4) value="${value%s}" ;; esac
  case "$field" in 7) value="${value%;}"; value="$(printf '%s' "$value" | tr -d '[:space:]')" ;; esac
  printf '%s\n' "$value"
}
esp_start="$(layout_partition_value 1 2)"
esp_end="$(layout_partition_value 1 3)"
esp_sectors="$(layout_partition_value 1 4)"
esp_name="$(layout_partition_value 1 6)"
esp_flags="$(layout_partition_value 1 7)"
data_start="$(layout_partition_value 2 2)"
data_end="$(layout_partition_value 2 3)"
data_sectors="$(layout_partition_value 2 4)"
data_name="$(layout_partition_value 2 6)"
data_flags="$(layout_partition_value 2 7)"
[ -n "$data_flags" ] || data_flags="none"
expected_data_end=$((output_image_size / 512 - 2049))
expected_data_sectors=$((expected_data_end - 1050624 + 1))
[ "$partition_table" = "gpt" ] && [ "$logical_sector_size" = "512" ] &&
  [ "$partition_count" = "2" ] &&
  [ "$esp_start" = "2048" ] && [ "$esp_end" = "1050623" ] &&
  [ "$esp_sectors" = "1048576" ] && [ "$esp_name" = "SP11EFI" ] &&
  [ "$esp_flags" = "boot,esp" ] && [ "$data_start" = "1050624" ] &&
  [ "$data_end" = "$expected_data_end" ] && [ "$data_sectors" = "$expected_data_sectors" ] &&
  [ "$data_name" = "SP11DATA" ] && [ "$data_flags" = "none" ] || {
  echo "Image build produced unexpected GPT geometry or metadata." >&2
  exit 1
}
[ "$esp_boot_size" -gt 0 ] || {
  echo "Image build produced an empty EFI boot application." >&2
  exit 1
}
[ "$esp_readme_size" = "81" ] &&
  [ "$esp_readme_sha" = "6163777e9eeca7cfb031dab492007471ed514ae99baea73c7da7de9ab51d0443" ] || {
  echo "Image build produced unexpected ESP README bytes." >&2
  exit 1
}

cat > "$work_abs/sp11-live-image-build-manifest.txt" <<EOF
Schema: sp11-live-image-build-v1
Build completed: true
Input ISO URL: ${ISO_SOURCE_URL:-unavailable}
Expected ISO SHA256: ${EXPECTED_ISO_SHA256:-unavailable}
Input ISO SHA256: $input_iso_sha
Embedded ISO path: iso/$iso_name
Embedded ISO SHA256: $embedded_iso_sha
DTB source: $dtb_source
Embedded DTB path: dtb/$dtb_name
Embedded DTB SHA256: $embedded_dtb_sha
Desktop: $DESKTOP
GRUB mode: $GRUB_MODE
Partition table: gpt
Logical sector size: 512
Partition count: 2
Partition 1 start sector: $esp_start
Partition 1 end sector: $esp_end
Partition 1 sector count: $esp_sectors
Partition 1 type GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
Partition 1 name: $esp_name
Partition 1 flags: $esp_flags
Partition 1 filesystem: fat32
Partition 1 filesystem label: SP11EFI
Partition 2 start sector: $data_start
Partition 2 end sector: $data_end
Partition 2 sector count: $data_sectors
Partition 2 type GUID: 0FC63DAF-8483-4772-8E79-3D69D8477DE4
Partition 2 name: $data_name
Partition 2 flags: $data_flags
Partition 2 filesystem: ext4
Partition 2 filesystem label: SP11DATA
ESP boot path: EFI/BOOT/BOOTAA64.EFI
ESP boot size: $esp_boot_size
ESP boot SHA256: $esp_boot_sha
ESP README path: README.txt
ESP README size: $esp_readme_size
ESP README SHA256: $esp_readme_sha
Builder image: $BUILD_IMAGE
Builder platform: $BUILD_PLATFORM
Support commit: $support_commit
Support manifest: .sp11-support-tree-v1
Support manifest SHA256: $support_manifest_sha
Output image file: $(basename "$out_abs")
Output image size: $output_image_size
Output image SHA256: $output_image_sha
EOF

if [ "$VALIDATE" = "true" ]; then
  if [ -z "${SP11_EXPECT_KERNEL_DEBS:-}" ] &&
    [ -d "$payload_abs" ] &&
    find "$payload_abs" -maxdepth 1 -type f -name '*.deb' | grep -q .; then
    export SP11_EXPECT_KERNEL_DEBS="true"
  fi
  validate_image "$stage_image"
fi

OUTPUT_TEMP="$(mktemp "$repo_dir/build/.${out_leaf}.image-output.XXXXXX")"
rm -f -- "$OUTPUT_TEMP"
mv "$stage_image" "$OUTPUT_TEMP"
[ "$(shasum -a 256 "$OUTPUT_TEMP" | awk '{print $1}')" = "$output_image_sha" ] || {
  echo "Image bytes changed while staging the atomic output." >&2
  exit 1
}
mv -f "$OUTPUT_TEMP" "$out_abs"
OUTPUT_TEMP=""

MANIFEST_TEMP="$(mktemp "$repo_dir/build/.${manifest_leaf}.image-output.XXXXXX")"
rm -f -- "$MANIFEST_TEMP"
mv "$work_abs/sp11-live-image-build-manifest.txt" "$MANIFEST_TEMP"
mv -f "$MANIFEST_TEMP" "$manifest_abs"
MANIFEST_TEMP=""
echo "Wrote $out_abs"
echo "Wrote $manifest_abs"
