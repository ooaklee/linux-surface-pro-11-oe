# SP11 IMX681 libcamera integration

This bundle teaches libcamera 0.7's simple IPA about the standalone IMX681
sensor metadata, reciprocal Sony analogue-gain control, and model-named tuning
data. Apply it only after the v14 kernel passes the raw-capture gates in
ADR-0065.

The standalone kernel control code `x` uses Sony's reciprocal mapping
`gain = 1024 / (1024 - x)` for `x=0..960`.
`AnalogueGainLinear{ 0, 1024, -1, 1024 }` expresses that relationship to
libcamera. The patch also records the measured 1000 nm unit cell, two-frame
exposure/gain/blanking delays, and a measured RAW10 black pedestal of 64
(4096 on libcamera's 16-bit scale).

Turbine's three source commits compile against libcamera v0.7.1. The combined
Ubuntu quilt patch dry-applies after the exact `0.7.0-1ubuntu2` distro series;
the canonical builder must still compile, sign, and verify a fresh coherent
package set after the kernel raw gate passes. Earlier built artifacts encode
the superseded CCS gain equation and must not be installed with the standalone
kernel. `BASE.txt` records the source hashes and current validation state.

The sensor model reported by the standalone driver is `imx681`. The tuning
filename must therefore be `imx681.yaml`, not `smiapp.yaml`. The patch adds
that file to the simple IPA's Meson install set. The standalone YAML beside
the patch is an audit copy and must stay byte-identical to the copy carried by
the patch.

## Deliberate limits

- The black pedestal of 64 is hardware evidence from turbineBMW's working
  standalone profile; confirm it with covered-lens raw frames on this unit.
- No CCM is enabled. Add one only after a controlled colour-chart measurement;
  an identity matrix or another unit's seed values are not calibration.
- The patch does not change the global AGC target or Adjust defaults.
- It does not add a privacy-LED daemon. V4L2 core owns the DT privacy LED.
- It does not relax PipeWire service hardening.

## Preferred native ARM64 Docker build

Commit the four build inputs together before invoking the repository builder:

```text
scripts/build-sp11-imx681-libcamera-docker.sh
userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch
userspace/camera/libcamera/BASE.txt
userspace/camera/libcamera/imx681.yaml
```

The builder intentionally refuses an untracked or modified copy of any input.
Once that commit exists, run it on an ARM64 Linux host with an ARM64 Docker
server:

```bash
cd /home/leon/Workspace/repos/linux-surface-pro-11-oe
./scripts/build-sp11-imx681-libcamera-docker.sh --jobs 10
```

The builder pulls Ubuntu 26.04, resolves the immutable image ID, and runs that
ID rather than the mutable tag. It downloads the exact Ubuntu
`0.7.0-1ubuntu2` source and verifies the DSC, orig tarball, and Debian tarball
against `BASE.txt` before source dependency resolution. It privately stages
only the four byte-identical `HEAD` inputs above and mounts that mode-`0700`
directory read-only. The repository itself is never mounted into the
container, and unrelated untracked files do not enter the build.

Every invocation gets a unique
`0.7.0-1ubuntu2+sp11.1.<23-digit-UTC-nanoseconds>.<32-hex-random-nonce>`
revision and a new private `build/libcamera-docker/build.*` output directory.
That path is ignored by Git, mode `0700`, and contains exactly these eight
regular files:

```text
gstreamer1.0-libcamera_<version>_arm64.deb
libcamera0.7_<version>_arm64.deb
libcamera-ipa_<version>_arm64.deb
libcamera-tools_<version>_arm64.deb
libcamera-v4l2_<version>_arm64.deb
libcamera_<version>_arm64.buildinfo
libcamera_<version>_arm64.changes
sp11-imx681-libcamera-build-manifest.txt
```

Before copying, the container verifies every SHA-256 entry in the build's
`.changes`, package names/versions/architectures, the IPA module, detached
signature, byte-identical tuning file, and same-build `ipa_verify`. The host
then verifies the exact eight-file set, manifest fields, package metadata and
hashes, selected `.changes` entries, `.buildinfo` hash, and an independently
extracted same-build IPA. The manifest records the support commit, source and
asset hashes, immutable image identity, build times, package metadata, and
final package hashes. Output is returned with the invoking user's UID/GID. The
builder never installs a package.

The retained `.changes` is the unmodified record of the complete binary-any
build. It references additional development, debug, Python, and other
non-selected artifacts that are intentionally not exported, so the eight-file
directory is a selected runtime/install bundle, not a self-contained Debian
upload. The container verifies every referenced SHA-256 entry while all build
outputs exist; the host re-verifies the six delivered entries (five DEBs plus
`.buildinfo`) and records that completed phase in the manifest. The manifest
also enumerates every intentionally omitted entry.

Before installation, select the one printed directory, parse its exact version
from the manifest, and repeat the package/record bindings. Run this complete
block in one Bash shell; it deliberately contains no artifact wildcard:

```bash
set -euo pipefail
export SP11_LIBCAMERA_ARTIFACTS=/absolute/path/printed/by/the/builder
case "$SP11_LIBCAMERA_ARTIFACTS" in
  /*) ;;
  *) echo 'Artifact directory must be absolute' >&2; exit 1 ;;
esac
SP11_CANONICAL_ARTIFACTS="$(readlink -e -- "$SP11_LIBCAMERA_ARTIFACTS")"
test "$SP11_CANONICAL_ARTIFACTS" = "$SP11_LIBCAMERA_ARTIFACTS"
export SP11_EXPECTED_OUTPUT_ROOT=/home/leon/Workspace/repos/linux-surface-pro-11-oe/build/libcamera-docker
test "$(dirname "$SP11_LIBCAMERA_ARTIFACTS")" = "$SP11_EXPECTED_OUTPUT_ROOT"
case "$(basename "$SP11_LIBCAMERA_ARTIFACTS")" in
  build.*) ;;
  *) echo 'Artifact directory does not have a builder-created name' >&2; exit 1 ;;
esac
test -d "$SP11_LIBCAMERA_ARTIFACTS"
test ! -L "$SP11_LIBCAMERA_ARTIFACTS"
test "$(stat -c '%u' "$SP11_LIBCAMERA_ARTIFACTS")" -eq "$(id -u)"
test "$(stat -c '%a' "$SP11_LIBCAMERA_ARTIFACTS")" = 700

export SP11_MANIFEST="$SP11_LIBCAMERA_ARTIFACTS/sp11-imx681-libcamera-build-manifest.txt"
test -f "$SP11_MANIFEST"
test ! -L "$SP11_MANIFEST"

manifest_scalar() {
  awk -v label="$1" '
    index($0, label ": ") == 1 {
      count++
      value = substr($0, length(label) + 3)
    }
    END { if (count != 1) exit 1; print value }
  ' "$SP11_MANIFEST"
}

manifest_package_field() {
  awk -v package_file="$1" -v field="$2" '
    $0 == "Package file: " package_file {
      package_count++
      active = 1
      next
    }
    active && /^Package file: / { active = 0 }
    active && $0 ~ "^  " field ": " {
      field_count++
      value = substr($0, length(field) + 5)
    }
    END {
      if (package_count != 1 || field_count != 1) exit 1
      print value
    }
  ' "$SP11_MANIFEST"
}

changes_sha_size() {
  awk -v selected_name="$1" '
    /^Checksums-Sha256:$/ { active = 1; next }
    active && /^[[:space:]]+[0-9a-f]{64}[[:space:]]+[0-9]+[[:space:]]+/ {
      if ($3 == selected_name) {
        count++
        value = $1 " " $2
      }
      next
    }
    active && /^[^[:space:]]/ { active = 0 }
    END { if (count != 1) exit 1; print value }
  ' "$SP11_CHANGES"
}

SP11_VERSION="$(manifest_scalar 'Package version')"
export SP11_VERSION
[[ "$SP11_VERSION" =~ ^0[.]7[.]0-1ubuntu2[+]sp11[.]1[.][0-9]{23}[.][0-9a-f]{32}$ ]]
test "$(manifest_scalar 'Build status')" = verified
test "$(manifest_scalar 'Manifest format')" = 2
test "$(manifest_scalar 'Selected runtime package count')" = 5
test "$(manifest_scalar 'Four build inputs matched support HEAD')" = yes
test "$(manifest_scalar 'Source version')" = 0.7.0-1ubuntu2
test "$(manifest_scalar 'Source DSC SHA-256')" = \
  27a10011fd5efe43564e94bb0328342ec11441963bed37db10a2d524553a02d8
test "$(manifest_scalar 'Same-build IPA verification')" = \
  'IPA module signature is valid'
test "$(manifest_scalar 'Original Changes file retained unmodified')" = yes
test "$(manifest_scalar 'Container pre-export every Changes-Sha256 entry hash verified')" = yes
test "$(manifest_scalar 'Delivered Changes-Sha256 entry count')" = 6
test "$(manifest_scalar 'Host post-copy delivered Changes-Sha256 entries verified')" = yes
test "$(manifest_scalar 'Host post-copy same-build IPA verification')" = \
  'IPA module signature is valid'
export SP11_ARCH=arm64
export SP11_CHANGES="$SP11_LIBCAMERA_ARTIFACTS/libcamera_${SP11_VERSION}_${SP11_ARCH}.changes"
export SP11_BUILDINFO="$SP11_LIBCAMERA_ARTIFACTS/libcamera_${SP11_VERSION}_${SP11_ARCH}.buildinfo"
export SP11_CORE_DEB="$SP11_LIBCAMERA_ARTIFACTS/libcamera0.7_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_IPA_DEB="$SP11_LIBCAMERA_ARTIFACTS/libcamera-ipa_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_TOOLS_DEB="$SP11_LIBCAMERA_ARTIFACTS/libcamera-tools_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_V4L2_DEB="$SP11_LIBCAMERA_ARTIFACTS/libcamera-v4l2_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_GST_DEB="$SP11_LIBCAMERA_ARTIFACTS/gstreamer1.0-libcamera_${SP11_VERSION}_${SP11_ARCH}.deb"

SP11_PACKAGE_NAMES=(
  libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2
  gstreamer1.0-libcamera
)
SP11_PACKAGE_FILES=(
  "$SP11_CORE_DEB" "$SP11_IPA_DEB" "$SP11_TOOLS_DEB" "$SP11_V4L2_DEB"
  "$SP11_GST_DEB"
)
SP11_ALL_ARTIFACTS=(
  "${SP11_PACKAGE_FILES[@]}" "$SP11_CHANGES" "$SP11_BUILDINFO"
  "$SP11_MANIFEST"
)

test "$(find "$SP11_LIBCAMERA_ARTIFACTS" -mindepth 1 -maxdepth 1 -type f -printf . | wc -c)" -eq 8
test -z "$(find "$SP11_LIBCAMERA_ARTIFACTS" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"
for artifact in "${SP11_ALL_ARTIFACTS[@]}"; do
  test -f "$artifact"
  test ! -L "$artifact"
  test "$(stat -c '%u' "$artifact")" -eq "$(id -u)"
  test "$(stat -c '%a' "$artifact")" = 644
done

test "$(manifest_scalar 'Changes file')" = "$(basename "$SP11_CHANGES")"
test "$(manifest_scalar 'Buildinfo file')" = "$(basename "$SP11_BUILDINFO")"
test "$(sha256sum "$SP11_CHANGES" | awk '{ print $1 }')" = \
  "$(manifest_scalar 'Changes file SHA-256')"
test "$(sha256sum "$SP11_BUILDINFO" | awk '{ print $1 }')" = \
  "$(manifest_scalar 'Buildinfo file SHA-256')"
test "$(awk -F': ' '$1 == "Version" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_CHANGES")" = "$SP11_VERSION"
test "$(awk -F': ' '$1 == "Source" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_CHANGES")" = libcamera
test "$(awk -F': ' '$1 == "Architecture" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_CHANGES")" = "$SP11_ARCH"
test "$(awk -F': ' '$1 == "Version" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_BUILDINFO")" = "$SP11_VERSION"
test "$(awk -F': ' '$1 == "Source" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_BUILDINFO")" = libcamera
test "$(awk -F': ' '$1 == "Architecture" { count++; value=$2 }
  END { if (count != 1) exit 1; print value }' "$SP11_BUILDINFO")" = "$SP11_ARCH"

for index in "${!SP11_PACKAGE_FILES[@]}"; do
  package_file="${SP11_PACKAGE_FILES[$index]}"
  package_name="${SP11_PACKAGE_NAMES[$index]}"
  package_basename="$(basename "$package_file")"
  package_sha="$(sha256sum "$package_file" | awk '{ print $1 }')"
  package_size="$(stat -c '%s' "$package_file")"

  test "$(dpkg-deb -f "$package_file" Package)" = "$package_name"
  test "$(dpkg-deb -f "$package_file" Source)" = libcamera
  test "$(dpkg-deb -f "$package_file" Version)" = "$SP11_VERSION"
  test "$(dpkg-deb -f "$package_file" Architecture)" = "$SP11_ARCH"
  test "$(manifest_package_field "$package_basename" Package)" = "$package_name"
  test "$(manifest_package_field "$package_basename" Source)" = libcamera
  test "$(manifest_package_field "$package_basename" Version)" = "$SP11_VERSION"
  test "$(manifest_package_field "$package_basename" Architecture)" = "$SP11_ARCH"
  test "$(manifest_package_field "$package_basename" 'Size bytes')" -eq "$package_size"
  test "$(manifest_package_field "$package_basename" SHA-256)" = "$package_sha"

  read -r changes_sha changes_size <<<"$(changes_sha_size "$package_basename")"
  test "$changes_sha" = "$package_sha"
  test "$changes_size" -eq "$package_size"
done

read -r buildinfo_sha buildinfo_size <<<"$(changes_sha_size "$(basename "$SP11_BUILDINFO")")"
test "$buildinfo_sha" = "$(sha256sum "$SP11_BUILDINFO" | awk '{ print $1 }')"
test "$buildinfo_size" -eq "$(stat -c '%s' "$SP11_BUILDINFO")"

less "$SP11_MANIFEST"

sudo apt install -- \
  "$SP11_CORE_DEB" \
  "$SP11_IPA_DEB" \
  "$SP11_TOOLS_DEB" \
  "$SP11_V4L2_DEB" \
  "$SP11_GST_DEB"
```

Installation remains gated on ADR-0065's raw camera acceptance; do not install
merely because the package build passes.

## Manual Ubuntu package build audit trail

Build from Ubuntu's matching source package instead of copying a locally built
IPA shared object over a packaged file. Use a new private directory and a
unique Debian revision for every build: Meson generates a new IPA signing key,
so reusing a version or a directory can make unrelated artifacts look
coherent. This section is an audit trail, not a substitute for the canonical
HEAD-authenticated Docker builder. Ensure Ubuntu source repositories are
enabled (`deb-src`, or `deb deb-src` in the deb822 `Types` field). Run all of
the following build, verification, and installation blocks in the same shell;
each block enables strict error handling so a failed provenance check stops the
workflow:

```bash
set -euo pipefail
export SP11_OE_REPO=/home/leon/Workspace/repos/linux-surface-pro-11-oe
sudo apt update
sudo apt install build-essential devscripts quilt libcamera-tools
sudo apt build-dep libcamera

export SP11_BASE_VERSION=0.7.0-1ubuntu2
export SP11_UPSTREAM_VERSION="${SP11_BASE_VERSION%%-*}"
export SP11_BUILD_TIMESTAMP="$(date -u +%Y%m%d%H%M%S%N)"
export SP11_BUILD_NONCE="$(openssl rand -hex 16)"
[[ "$SP11_BUILD_TIMESTAMP" =~ ^[0-9]{23}$ ]]
[[ "$SP11_BUILD_NONCE" =~ ^[0-9a-f]{32}$ ]]
export SP11_BUILD_ID="${SP11_BUILD_TIMESTAMP}.${SP11_BUILD_NONCE}"
export SP11_VERSION="${SP11_BASE_VERSION}+sp11.1.${SP11_BUILD_ID}"
export SP11_ARCH="$(dpkg --print-architecture)"
test "$SP11_ARCH" = arm64

install -d -m 0700 "$SP11_OE_REPO/build/libcamera"
SP11_PACKAGE_DIR="$(mktemp -d \
  "$SP11_OE_REPO/build/libcamera/package.${SP11_BUILD_ID}.XXXXXXXX")"
export SP11_PACKAGE_DIR
test ! -L "$SP11_PACKAGE_DIR"
test "$(stat -c '%u' "$SP11_PACKAGE_DIR")" -eq "$(id -u)"
chmod 0700 "$SP11_PACKAGE_DIR"

cd "$SP11_PACKAGE_DIR"
apt source "libcamera=$SP11_BASE_VERSION"

SP11_ORIG_SHA="$(awk -F': ' \
  '$1 == "Ubuntu orig tarball SHA-256" { print $2 }' \
  "$SP11_OE_REPO/userspace/camera/libcamera/BASE.txt")"
SP11_DSC_SHA="$(awk -F': ' \
  '$1 == "Ubuntu DSC SHA-256" { print $2 }' \
  "$SP11_OE_REPO/userspace/camera/libcamera/BASE.txt")"
SP11_DEBIAN_SHA="$(awk -F': ' \
  '$1 == "Ubuntu Debian tarball SHA-256" { print $2 }' \
  "$SP11_OE_REPO/userspace/camera/libcamera/BASE.txt")"
grep -Eq '^[0-9a-f]{64}$' <<<"$SP11_DSC_SHA"
grep -Eq '^[0-9a-f]{64}$' <<<"$SP11_ORIG_SHA"
grep -Eq '^[0-9a-f]{64}$' <<<"$SP11_DEBIAN_SHA"
printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$SP11_DSC_SHA" "libcamera_${SP11_BASE_VERSION}.dsc" \
  "$SP11_ORIG_SHA" "libcamera_${SP11_UPSTREAM_VERSION}.orig.tar.gz" \
  "$SP11_DEBIAN_SHA" "libcamera_${SP11_BASE_VERSION}.debian.tar.xz" | \
  sha256sum -c -

cd "libcamera-$SP11_UPSTREAM_VERSION"

export QUILT_PATCHES=debian/patches
quilt import \
  "$SP11_OE_REPO/userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch"
quilt push
cmp \
  "$SP11_OE_REPO/userspace/camera/libcamera/imx681.yaml" \
  src/ipa/simple/data/imx681.yaml

dch --newversion "$SP11_VERSION" --distribution resolute \
  "Add Surface Pro 11 IMX681 simple-IPA support."
dpkg-buildpackage -b -uc -us
```

Bind the exact five packages to the one build's `.changes` checksums. Do not
replace these paths with wildcards, and do not mix another build into this
directory:

```bash
set -euo pipefail
export SP11_CHANGES="$SP11_PACKAGE_DIR/libcamera_${SP11_VERSION}_${SP11_ARCH}.changes"
export SP11_CORE_DEB="$SP11_PACKAGE_DIR/libcamera0.7_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_IPA_DEB="$SP11_PACKAGE_DIR/libcamera-ipa_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_TOOLS_DEB="$SP11_PACKAGE_DIR/libcamera-tools_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_V4L2_DEB="$SP11_PACKAGE_DIR/libcamera-v4l2_${SP11_VERSION}_${SP11_ARCH}.deb"
export SP11_GST_DEB="$SP11_PACKAGE_DIR/gstreamer1.0-libcamera_${SP11_VERSION}_${SP11_ARCH}.deb"

for artifact in \
  "$SP11_CHANGES" "$SP11_CORE_DEB" "$SP11_IPA_DEB" \
  "$SP11_TOOLS_DEB" "$SP11_V4L2_DEB" "$SP11_GST_DEB"; do
  test -f "$artifact" && test ! -L "$artifact"
  test "$(stat -c '%u' "$artifact")" -eq "$(id -u)"
done

(
  cd "$SP11_PACKAGE_DIR"
  awk '
    /^Checksums-Sha256:$/ { in_sha256 = 1; next }
    in_sha256 && /^[[:space:]]+[0-9a-f]{64}[[:space:]]+[0-9]+[[:space:]]+/ {
      print $1 "  " $3
      next
    }
    in_sha256 { exit }
  ' "$(basename "$SP11_CHANGES")" | sha256sum -c -
)

for artifact in \
  "$SP11_CORE_DEB" "$SP11_IPA_DEB" "$SP11_TOOLS_DEB" \
  "$SP11_V4L2_DEB" "$SP11_GST_DEB"; do
  awk -v name="$(basename "$artifact")" \
    '$NF == name { found = 1 } END { exit !found }' "$SP11_CHANGES"
  test "$(dpkg-deb -f "$artifact" Version)" = "$SP11_VERSION"
done
```

Inspect the exact IPA package and require the module, its detached signature,
and the model-named tuning file. Then extract the exact core/tools/IPA set into
the private directory and run its own verifier before installing anything:

```bash
set -euo pipefail
dpkg-deb -c "$SP11_IPA_DEB" >"$SP11_PACKAGE_DIR/libcamera-ipa.contents"
grep -E '/ipa_soft_simple[.]so$' \
  "$SP11_PACKAGE_DIR/libcamera-ipa.contents"
grep -E '/ipa_soft_simple[.]so[.]sign$' \
  "$SP11_PACKAGE_DIR/libcamera-ipa.contents"
grep -E '/ipa/simple/imx681[.]yaml$' \
  "$SP11_PACKAGE_DIR/libcamera-ipa.contents"

export SP11_VERIFY_ROOT="$SP11_PACKAGE_DIR/verify-root"
install -d -m 0700 "$SP11_VERIFY_ROOT"
dpkg-deb -x "$SP11_CORE_DEB" "$SP11_VERIFY_ROOT"
dpkg-deb -x "$SP11_IPA_DEB" "$SP11_VERIFY_ROOT"
dpkg-deb -x "$SP11_TOOLS_DEB" "$SP11_VERIFY_ROOT"

export SP11_MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
LD_LIBRARY_PATH="$SP11_VERIFY_ROOT/usr/lib/$SP11_MULTIARCH" \
  "$SP11_VERIFY_ROOT/usr/bin/ipa_verify" \
  "$SP11_VERIFY_ROOT/usr/lib/$SP11_MULTIARCH/libcamera/ipa/ipa_soft_simple.so"
```

Require `IPA module signature is valid` before continuing.

Meson generates a new IPA signing key for every build. `libcamera0.7` embeds
that build's public key, while `libcamera-ipa` contains modules signed by its
private key. Installing only the custom IPA beside the distro core can make the
IPA signature fail. Install the exact checksum-verified package paths from this
one unique build. This keeps the core, IPA, V4L2 and GStreamer shims, and
acceptance tools on the same local build:

```bash
set -euo pipefail
sudo apt install \
  "$SP11_CORE_DEB" \
  "$SP11_IPA_DEB" \
  "$SP11_TOOLS_DEB" \
  "$SP11_V4L2_DEB" \
  "$SP11_GST_DEB"
```

Do not install a loose replacement `ipa_soft_simple.so`. The package owns both
the signed IPA module and its tuning data, making upgrades and rollback
traceable. Roll back the same package set together:

```bash
set -euo pipefail
sudo apt install --allow-downgrades \
  libcamera0.7=0.7.0-1ubuntu2 \
  libcamera-ipa=0.7.0-1ubuntu2 \
  libcamera-tools=0.7.0-1ubuntu2 \
  libcamera-v4l2=0.7.0-1ubuntu2 \
  gstreamer1.0-libcamera=0.7.0-1ubuntu2
```

## Acceptance

1. Verify the installed runtime packages all report the one exact
   `$SP11_VERSION` (with its unique UTC timestamp and random nonce) and
   `/usr/share/libcamera/ipa/simple/imx681.yaml` exists:

   ```bash
   set -euo pipefail
   : "${SP11_LIBCAMERA_ARTIFACTS:?Set this to the verified build directory}"
   SP11_MANIFEST="$SP11_LIBCAMERA_ARTIFACTS/sp11-imx681-libcamera-build-manifest.txt"
   SP11_VERSION="$(awk -F': ' '
     $1 == "Package version" { count++; value=$2 }
     END { if (count != 1) exit 1; print value }
   ' "$SP11_MANIFEST")"
   [[ "$SP11_VERSION" =~ ^0[.]7[.]0-1ubuntu2[+]sp11[.]1[.][0-9]{23}[.][0-9a-f]{32}$ ]]
   dpkg-query -W -f='${binary:Package}\t${Version}\n' \
     libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 \
     gstreamer1.0-libcamera
   for package in \
     libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 \
     gstreamer1.0-libcamera; do
     test "$(dpkg-query -W -f='${Version}' "$package")" = "$SP11_VERSION"
   done
   test -f /usr/share/libcamera/ipa/simple/imx681.yaml
   test -f /usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so.sign
   ```

2. Verify the installed simple IPA against the public key embedded in the
   matching core build:

   ```bash
   set -euo pipefail
   ipa_verify \
     /usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so
   ```

   Require `IPA module signature is valid` before continuing.

3. Run camera enumeration with IPA logging enabled:

   ```bash
   set -euo pipefail
   SP11_ENUM_LOG="$(mktemp "${TMPDIR:-/tmp}/sp11-libcamera-enumeration.XXXXXXXX")"
   chmod 0600 "$SP11_ENUM_LOG"
   LIBCAMERA_LOG_LEVELS='IPAProxy:0,IPASoft:0' cam -l 2>&1 | \
     tee "$SP11_ENUM_LOG"
   echo "Enumeration log: $SP11_ENUM_LOG"
   ```

4. Require a log line selecting `.../simple/imx681.yaml`; reject a fallback to
   `uncalibrated.yaml` or `Failed to create camera sensor helper for imx681`.
5. During a stream, require the simple IPA to report a real-gain range near
   `1-16`, not kernel codes `0-960`. Capture at least 30 frames and confirm
   manual codes 0, 768, and 960 behave approximately as 1x, 4x, and 16x while
   AE moves monotonically across the same range.
6. Confirm the 64-code RAW10 pedestal with covered-lens frames. Keep CCM
   disabled until a controlled colour target produces a defensible matrix.
7. Repeat stream start/stop and PipeWire/WebRTC tests. The privacy LED must be
   on only while V4L2 is streaming.
