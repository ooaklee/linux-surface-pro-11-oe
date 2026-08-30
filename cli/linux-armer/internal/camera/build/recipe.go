package build

import (
	"crypto/sha256"
	"encoding/hex"
)

// containerRecipe is the complete reviewed Ubuntu 26.04 ARM64 package policy.
const containerRecipe = `#!/usr/bin/env bash
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TZ=UTC

required_env=(
  BASE_VERSION DSC_SHA ORIG_SHA DEBIAN_SHA BASE_INPUT_SHA PATCH_INPUT_SHA
  YAML_INPUT_SHA BUILD_ID BUILD_JOBS SUPPORT_HEAD SUPPORT_HEAD_TIME
  BUILDER_IMAGE RECIPE_SHA256 HOST_UID HOST_GID MINIMUM_FREE_GIB
)
for name in "${required_env[@]}"; do
  test -n "${!name:-}" || { echo "missing environment: $name" >&2; exit 1; }
done

. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 26.04
test "$(dpkg --print-architecture)" = arm64
case "$(uname -m)" in aarch64|arm64) ;; *) exit 1 ;; esac
test "$BASE_VERSION" = 0.7.0-1ubuntu2
case "$BUILD_JOBS" in ''|*[!0-9]*) exit 1 ;; esac
test "$BUILD_JOBS" -ge 1
test "$BUILD_JOBS" -le 64
test -z "$(find /exchange/artifacts -mindepth 1 -maxdepth 1 -print -quit)"
test -z "$(find /exchange/metadata -mindepth 1 -maxdepth 1 -print -quit)"

apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl devscripts dpkg-dev equivs fakeroot \
  git quilt ubuntu-keyring util-linux

mount_options="$(findmnt -T /inputs -n -o OPTIONS)"
case ",$mount_options," in *,ro,*) ;; *) exit 1 ;; esac
test "$(find /inputs -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)" = 3
test -z "$(find /inputs -mindepth 1 -maxdepth 1 ! -type f -print -quit)"
printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$BASE_INPUT_SHA" /inputs/BASE.txt \
  "$PATCH_INPUT_SHA" /inputs/imx681.patch \
  "$YAML_INPUT_SHA" /inputs/imx681.yaml | sha256sum --strict --check -

available_kb="$(df -Pk /exchange | awk 'NR == 2 {print $4}')"
required_kb=$((MINIMUM_FREE_GIB * 1024 * 1024))
test -n "$available_kb"
test "$available_kb" -ge "$required_kb"

mkdir -p /work/assets /work/download /work/source /work/deps /work/verify
chmod 0700 /work /work/assets /work/download /work/source /work/deps /work/verify
install -m 0400 /inputs/imx681.patch /work/assets/imx681.patch
install -m 0400 /inputs/imx681.yaml /work/assets/imx681.yaml

upstream_version="${BASE_VERSION%%-*}"
source_url="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/libcamera/$BASE_VERSION"
dsc_name="libcamera_${BASE_VERSION}.dsc"
orig_name="libcamera_${upstream_version}.orig.tar.gz"
debian_name="libcamera_${BASE_VERSION}.debian.tar.xz"
cd /work/download
for name in "$dsc_name" "$orig_name" "$debian_name"; do
  curl --fail --location --proto '=https' --tlsv1.2 --retry 5 \
    --retry-all-errors --output "$name" "$source_url/$name"
  test -s "$name"
  test ! -L "$name"
done
printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$DSC_SHA" "$dsc_name" "$ORIG_SHA" "$orig_name" \
  "$DEBIAN_SHA" "$debian_name" | sha256sum --strict --check -

dsc_orig_sha="$(awk -v file="$orig_name" '
  /^Checksums-Sha256:$/ {active=1; next}
  active && $3 == file {print $1; found++; next}
  active && /^[^[:space:]]/ {active=0}
  END {if (found != 1) exit 1}
' "$dsc_name")"
dsc_debian_sha="$(awk -v file="$debian_name" '
  /^Checksums-Sha256:$/ {active=1; next}
  active && $3 == file {print $1; found++; next}
  active && /^[^[:space:]]/ {active=0}
  END {if (found != 1) exit 1}
' "$dsc_name")"
test "$dsc_orig_sha" = "$ORIG_SHA"
test "$dsc_debian_sha" = "$DEBIAN_SHA"

cd /work/deps
mk-build-deps --build-dep --install --remove \
  --tool 'apt-get -y --no-install-recommends' "/work/download/$dsc_name"
dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort | \
  sha256sum | awk '{print $1}' >/exchange/metadata/toolchain-sha256

source_dir="/work/source/libcamera-$upstream_version"
dpkg-source --extract "/work/download/$dsc_name" "$source_dir"
cd "$source_dir"
test "$(dpkg-parsechangelog -SVersion)" = "$BASE_VERSION"
mapfile -t distro_series < <(sed -E '/^[[:space:]]*(#|$)/d' debian/patches/series)
mapfile -t applied_series < .pc/applied-patches
test "${#distro_series[@]}" -gt 0
test "${#distro_series[@]}" = "${#applied_series[@]}"
for index in "${!distro_series[@]}"; do
  test "${distro_series[$index]}" = "${applied_series[$index]}"
done

export QUILT_PATCHES=debian/patches
quilt import -P sp11-imx681-simple-ipa.patch /work/assets/imx681.patch
quilt push
cmp /work/assets/imx681.yaml src/ipa/simple/data/imx681.yaml

package_version="${BASE_VERSION}+sp11.2.${BUILD_ID}"
export DEBFULLNAME='linux-armer camera builder'
export DEBEMAIL='linux-armer-camera-builder@localhost'
dch --force-distribution --newversion "$package_version" \
  --distribution resolute --urgency medium \
  'Add Surface Pro 11 IMX681 simple-IPA support.'
test "$(dpkg-parsechangelog -SVersion)" = "$package_version"
export DEB_BUILD_OPTIONS="parallel=$BUILD_JOBS"
dpkg-buildpackage -B -uc -us

package_parent="$(dirname "$source_dir")"
changes="$package_parent/libcamera_${package_version}_arm64.changes"
buildinfo="$package_parent/libcamera_${package_version}_arm64.buildinfo"
test -f "$changes" && test ! -L "$changes"
test -f "$buildinfo" && test ! -L "$buildinfo"
packages=(libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera)
package_files=()
for package in "${packages[@]}"; do
  file="$package_parent/${package}_${package_version}_arm64.deb"
  test -f "$file" && test ! -L "$file"
  test "$(find "$package_parent" -maxdepth 1 -type f -name "${package}_${package_version}_*.deb" -printf . | wc -c)" = 1
  test "$(dpkg-deb --field "$file" Package)" = "$package"
  test "$(dpkg-deb --field "$file" Source)" = libcamera
  test "$(dpkg-deb --field "$file" Version)" = "$package_version"
  test "$(dpkg-deb --field "$file" Architecture)" = arm64
  package_files+=("$file")
done

dpkg-deb --extract "${package_files[1]}" /work/verify
dpkg-deb --extract "${package_files[0]}" /work/verify
dpkg-deb --extract "${package_files[2]}" /work/verify
module=/work/verify/usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so
signature="$module.sign"
tuning=/work/verify/usr/share/libcamera/ipa/simple/imx681.yaml
verifier=/work/verify/usr/bin/ipa_verify
for file in "$module" "$signature" "$tuning" "$verifier"; do
  test -f "$file" && test ! -L "$file"
done
cmp /work/assets/imx681.yaml "$tuning"
verify_output="$(LD_LIBRARY_PATH=/work/verify/usr/lib/aarch64-linux-gnu "$verifier" "$module")"
test "$verify_output" = 'IPA module signature is valid'

copyright=debian/copyright
test -f "$copyright" && test ! -L "$copyright"
sha256sum "$copyright" | awk '{print $1}' >/exchange/metadata/copyright-sha256
stat -c '%s' "$copyright" >/exchange/metadata/copyright-size
printf '%s' "$package_version" >/exchange/metadata/package-version
printf '%s' "$source_url" >/exchange/metadata/source-url
printf '%s' "$SUPPORT_HEAD" >/exchange/metadata/support-head
printf '%s' "$SUPPORT_HEAD_TIME" >/exchange/metadata/support-head-time
printf '%s' "$verify_output" >/exchange/metadata/ipa-verification
printf '%s' "$RECIPE_SHA256" >/exchange/metadata/recipe-sha256

for file in "${package_files[@]}" "$changes" "$buildinfo"; do
  install -m 0644 "$file" "/exchange/artifacts/$(basename "$file")"
done
test "$(find /exchange/artifacts -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)" = 7
test -z "$(find /exchange/artifacts -mindepth 1 -maxdepth 1 ! -type f -print -quit)"
test "$(find /exchange/metadata -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)" = 9
test -z "$(find /exchange/metadata -mindepth 1 -maxdepth 1 ! -type f -print -quit)"
chmod 0644 /exchange/artifacts/*
chmod 0600 /exchange/metadata/*
chown "$HOST_UID:$HOST_GID" /exchange/artifacts/* /exchange/metadata/*
`

// recipeSHA256 returns the stable identity of the embedded build policy.
func recipeSHA256() string {
	digest := sha256.Sum256([]byte(containerRecipe))
	return hex.EncodeToString(digest[:])
}
