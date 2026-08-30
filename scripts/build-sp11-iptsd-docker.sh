#!/usr/bin/env bash
set -euo pipefail

IMAGE="ubuntu:26.04"
OUT_DIR="build/iptsd-sp11"
LINUX_WORK_VOLUME="sp11-iptsd-v3-1-0-build"
JOBS="${SP11_IPTSD_JOBS:-8}"
COPY_TO_PAYLOAD="false"

usage() {
  cat <<EOF
Usage: $0 [options]

Builds the pinned upstream iptsd SP11 binaries in an ARM64 Docker volume.

  --image IMAGE          ARM64 build image, default $IMAGE.
  --out-dir DIR          Output directory, default $OUT_DIR.
  --linux-work-volume V  Case-sensitive Docker volume, default $LINUX_WORK_VOLUME.
  --jobs N               Parallel build jobs, default $JOBS.
  --copy-to-payload      Replace payload/iptsd-sp11 with the verified output.
  -h, --help             Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --linux-work-volume)
      LINUX_WORK_VOLUME="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --copy-to-payload)
      COPY_TO_PAYLOAD="true"
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

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--jobs must be a positive integer." >&2
  exit 2
fi
if ! [[ "$LINUX_WORK_VOLUME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "Unsafe Docker volume name: $LINUX_WORK_VOLUME" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required." >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
integration_dir="$repo_dir/userspace/iptsd-sp11"

# shellcheck disable=SC1091
source "$integration_dir/SOURCE.env"

mkdir -p "$OUT_DIR"
out_abs="$(cd "$OUT_DIR" && pwd)"
payload_abs="$repo_dir/payload/iptsd-sp11"
if [ "$out_abs" = "$payload_abs" ]; then
  echo "Use a build directory distinct from payload/iptsd-sp11." >&2
  exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull --platform linux/arm64 "$IMAGE"
fi
image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
image_digest="$(docker image inspect --format '{{join .RepoDigests ","}}' "$IMAGE")"

if ! docker volume inspect "$LINUX_WORK_VOLUME" >/dev/null 2>&1; then
  docker volume create "$LINUX_WORK_VOLUME" >/dev/null
fi

docker run --rm --platform linux/arm64 \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  -e "IPTSD_REPOSITORY=$IPTSD_REPOSITORY" \
  -e "IPTSD_COMMIT=$IPTSD_COMMIT" \
  -e "IPTSD_TREE=$IPTSD_TREE" \
  -e "IPTSD_VERSION=$IPTSD_VERSION" \
  -e "BUILD_IMAGE=$IMAGE" \
  -e "BUILD_IMAGE_ID=$image_id" \
  -e "BUILD_IMAGE_DIGEST=$image_digest" \
  -e "JOBS=$JOBS" \
  -v "$LINUX_WORK_VOLUME:/work" \
  -v "$out_abs:/out" \
  -v "$integration_dir:/integration:ro" \
  "$image_id" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  file \
  git \
  meson \
  ninja-build \
  pkg-config \
  python3 \
  unzip \
  xz-utils \
  zip \
  >/dev/null

rm -rf /work/source /work/build /out/stage
mkdir -p /work/source /out/stage/bin /out/stage/licenses /out/stage/sources

git clone --filter=blob:none --no-checkout "$IPTSD_REPOSITORY" /work/source >/dev/null 2>&1
git -C /work/source checkout --detach "$IPTSD_COMMIT" >/dev/null 2>&1
test "$(git -C /work/source rev-parse HEAD^{commit})" = "$IPTSD_COMMIT"
test "$(git -C /work/source rev-parse HEAD^{tree})" = "$IPTSD_TREE"

export SOURCE_DATE_EPOCH="$(git -C /work/source show -s --format=%ct HEAD)"
export CXXFLAGS="-ffile-prefix-map=/work/source=/usr/src/iptsd -ffile-prefix-map=/work/build=/usr/src/iptsd-build"

meson setup /work/build /work/source \
  --prefix=/usr/local \
  --bindir=libexec \
  --sysconfdir=/etc \
  --buildtype=release \
  -Doptimization=3 \
  -Dwerror=false \
  -Db_lto=false \
  -Ddebug_tools=[] \
  -Dservice_manager=[] \
  -Dsample_config=false \
  -Dforce_access_checks=true \
  --force-fallback-for=CLI11,eigen3,fmt,INIReader,Microsoft.GSL,spdlog
ninja -C /work/build -j "$JOBS" src/iptsd src/iptsd-check-device

install -m 0755 /work/build/src/iptsd /out/stage/bin/sp11-iptsd
install -m 0755 /work/build/src/iptsd-check-device \
  /out/stage/bin/sp11-iptsd-check-device
install -m 0644 /work/source/LICENSE /out/stage/licenses/LICENSE.iptsd
install -m 0644 /integration/LICENSE.integration \
  /out/stage/licenses/LICENSE.integration
install -m 0644 /work/source/subprojects/CLI11-2.6.1/LICENSE \
  /out/stage/licenses/LICENSE.CLI11
install -m 0644 /work/source/subprojects/GSL-4.2.0/LICENSE \
  /out/stage/licenses/LICENSE.Microsoft-GSL
install -m 0644 /work/source/subprojects/GSL-4.2.0/LICENSE.build \
  /out/stage/licenses/LICENSE.Microsoft-GSL.build
install -m 0644 /work/source/subprojects/eigen-5.0.1/LICENSE \
  /out/stage/licenses/LICENSE.Eigen
install -m 0644 /work/source/subprojects/eigen-5.0.1/LICENSE.build \
  /out/stage/licenses/LICENSE.Eigen.build
for notice in /work/source/subprojects/eigen-5.0.1/COPYING.*; do
  install -m 0644 "$notice" \
    "/out/stage/licenses/COPYING.Eigen.${notice##*.}"
done
install -m 0644 /work/source/subprojects/fmt-12.0.0/LICENSE \
  /out/stage/licenses/LICENSE.fmt
install -m 0644 /work/source/subprojects/fmt-12.0.0/LICENSE.build \
  /out/stage/licenses/LICENSE.fmt.build
install -m 0644 /work/source/subprojects/inih-r62/LICENSE.txt \
  /out/stage/licenses/LICENSE.inih
install -m 0644 /work/source/subprojects/spdlog-1.15.3/LICENSE \
  /out/stage/licenses/LICENSE.spdlog
install -m 0644 /work/source/subprojects/spdlog-1.15.3/LICENSE.build \
  /out/stage/licenses/LICENSE.spdlog.build
install -m 0644 /integration/SOURCE.env /out/stage/SOURCE.env

git -C /work/source archive --format=tar --prefix="iptsd-$IPTSD_COMMIT/" HEAD |
  gzip -n >"/out/stage/sources/iptsd-$IPTSD_COMMIT.tar.gz"
for wrap in cli11 eigen fmt inih microsoft-gsl spdlog; do
  cp "/work/source/subprojects/$wrap.wrap" /out/stage/sources/
done
cp /work/source/subprojects/packagecache/* /out/stage/sources/

gxx_version="$(g++ --version | head -n 1)"
meson_version="$(meson --version)"
ninja_version="$(ninja --version)"
cat > /out/stage/BUILD.env <<EOF
BUILD_IMAGE=$BUILD_IMAGE
BUILD_IMAGE_ID=$BUILD_IMAGE_ID
BUILD_IMAGE_DIGEST=$BUILD_IMAGE_DIGEST
BUILD_ARCH=aarch64
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
GXX_VERSION=$gxx_version
MESON_VERSION=$meson_version
NINJA_VERSION=$ninja_version
MESON_OPTIONS=--prefix=/usr/local --bindir=libexec --sysconfdir=/etc --buildtype=release -Doptimization=3 -Dwerror=false -Db_lto=false -Ddebug_tools=[] -Dservice_manager=[] -Dsample_config=false -Dforce_access_checks=true --force-fallback-for=CLI11,eigen3,fmt,INIReader,Microsoft.GSL,spdlog
EOF

dpkg-query -W -f="\${binary:Package}\t\${Version}\t\${Architecture}\n" |
  LC_ALL=C sort > /out/stage/SBOM.dpkg.tsv
{
  for source in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$source" ] || continue
    printf "### %s\n" "$source"
    sed -e "/^[[:space:]]*#/d" -e "/^[[:space:]]*$/d" "$source"
  done
} > /out/stage/APT.sources.txt

file /out/stage/bin/sp11-iptsd /out/stage/bin/sp11-iptsd-check-device |
  tee /out/stage/FILE.txt
# ldd prints the ASLR-selected load address for every object. Preserve the
# dependency names and resolved paths, but normalize those per-run addresses so
# the release manifest can be reproduced from the same source and toolchain.
ldd /out/stage/bin/sp11-iptsd |
  sed -E "s/\\(0x[[:xdigit:]]+\\)/(0xADDR)/g" > /out/stage/LDD.iptsd.txt
ldd /out/stage/bin/sp11-iptsd-check-device |
  sed -E "s/\\(0x[[:xdigit:]]+\\)/(0xADDR)/g" > /out/stage/LDD.check-device.txt

(
  cd /out/stage
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)

chown -R "$HOST_UID:$HOST_GID" /out/stage
'

payload_verified="false"
if [ -f "$integration_dir/PAYLOAD.sha256" ]; then
  "$repo_dir/scripts/validate-sp11-iptsd-payload.sh" \
    --payload "$out_abs/stage" --integration "$integration_dir"
  payload_verified="true"
else
  echo "No pinned PAYLOAD.sha256 exists yet; built a candidate stage only." >&2
fi

if [ "$COPY_TO_PAYLOAD" = "true" ]; then
  if [ "$payload_verified" != "true" ]; then
    echo "Refusing to publish a payload without a pinned release manifest." >&2
    exit 1
  fi
  rm -rf "$payload_abs"
  mkdir -p "$payload_abs"
  cp -R "$out_abs/stage/." "$payload_abs/"
  echo "Copied verified iptsd payload to $payload_abs"
fi

echo "Built iptsd $IPTSD_VERSION ($IPTSD_COMMIT) into $out_abs/stage"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$out_abs/stage/bin/sp11-iptsd" \
    "$out_abs/stage/bin/sp11-iptsd-check-device"
else
  shasum -a 256 "$out_abs/stage/bin/sp11-iptsd" \
    "$out_abs/stage/bin/sp11-iptsd-check-device"
fi
