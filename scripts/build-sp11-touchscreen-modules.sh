#!/usr/bin/env bash
set -euo pipefail

# Builds the out-of-tree Surface Pro 11 touchscreen modules (gpi,
# spi-geni-qcom, mshw0485_touch) from the geocausa Phase 91 baseline against
# the current kernel's headers, and installs them as higher-priority
# /lib/modules/<release>/updates/ overrides.
#
# The kernel must have been built with the v3 touchscreen DTS patch applied
# (patches/sp11-qcom-x1e-7.2-rc5-v3), and linux-headers for the running
# kernel must be installed on this machine.

GIT_URL="https://github.com/geocausa/SP11X1e-touchscreen.git"
GIT_BRANCH="main"
SOURCE_DIR="build/SP11X1e-touchscreen"
OUT_DIR=".sp11-kmod-v3"
INSTALL="false"
RELEASE="$(uname -r)"
KVER_DIR="/lib/modules/${RELEASE}"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --source-dir DIR  Directory to clone the geocausa tree into (default $SOURCE_DIR).
  --out-dir DIR     Where to drop the built modules (default $OUT_DIR).
  --install         Also install into $KVER_DIR/updates/ and run depmod.
  --release VER     Target kernel release (default \$(uname -r)).
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source-dir) SOURCE_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --install) INSTALL="true"; shift ;;
    --release) RELEASE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

KVER_DIR="/lib/modules/${RELEASE}"
KDIR="${KVER_DIR}/build"

if [ ! -d "${KDIR}" ]; then
  echo "error: no headers found at ${KDIR}. Install linux-headers-${RELEASE} first." >&2
  exit 1
fi

if [ ! -d "${SOURCE_DIR}" ]; then
  mkdir -p "${SOURCE_DIR}"
  git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_URL}" "${SOURCE_DIR}"
else
  git -C "${SOURCE_DIR}" fetch --depth 1 origin "${GIT_BRANCH}"
  git -C "${SOURCE_DIR}" checkout "${GIT_BRANCH}"
  git -C "${SOURCE_DIR}" pull --ff-only origin "${GIT_BRANCH}"
fi

# The Phase 91 DMA baseline builds from phase55/modules. The kernel release
# guard there is tuned for the geocausa baseline kernel; the SP11 v3 build is
# a deliberately different release, so allow it explicitly.
make -C "${SOURCE_DIR}/phase55/modules" \
  KDIR="${KDIR}" \
  EXPECTED_KERNEL_RELEASE="${RELEASE}" \
  ALLOW_UNTESTED_KERNEL=1

mkdir -p "${OUT_DIR}"
for mod in gpi spi-geni-qcom mshw0485_touch; do
  cp "${SOURCE_DIR}/phase55/modules/${mod}.ko" "${OUT_DIR}/"
done
echo "Built modules in ${OUT_DIR}/:"
ls -la "${OUT_DIR}/"

if [ "$INSTALL" = "true" ]; then
  if [ "$(id -u)" != "0" ]; then
    echo "error: --install requires root." >&2
    exit 1
  fi
  UPDATES="${KVER_DIR}/updates"
  mkdir -p "${UPDATES}/drivers/dma/qcom" "${UPDATES}/drivers/spi" \
    "${UPDATES}/drivers/input/touchscreen"
  cp "${OUT_DIR}/gpi.ko" "${UPDATES}/drivers/dma/qcom/"
  cp "${OUT_DIR}/spi-geni-qcom.ko" "${UPDATES}/drivers/spi/"
  cp "${OUT_DIR}/mshw0485_touch.ko" "${UPDATES}/drivers/input/touchscreen/"
  depmod -a "${RELEASE}"
  echo "Installed updates modules for ${RELEASE}. Reboot to load them."
fi
