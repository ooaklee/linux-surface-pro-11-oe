# SP11 IMX681 libcamera integration

This bundle teaches libcamera 0.7's simple IPA how the kernel's IMX681 gain
control maps to real gain and installs model-named tuning data. Apply it only
after the v14 kernel passes the raw-capture gates in ADR-0065.

The kernel control code `x` programs global U8.8 gain as `0x0100 + 4*x`, so
real gain is `1 + x/64`. `AnalogueGainLinear{ 1, 64, 0, 64 }` expresses that
relationship to libcamera. Without the helper, the simple IPA treats codes
`0..960` as real gain and uses the kernel default, 192, as its 1x threshold;
automatic exposure then cannot reduce the initial 4x sensor gain correctly.

The patch applies and the simple IPA target compiles against both upstream tag
`v0.7.0` and Ubuntu's exact `0.7.0-1ubuntu2` source after its distro patch
series. The Ubuntu validation also signs the IPA and verifies it with the
matching build's `ipa_verify`. `BASE.txt` records the source hashes.

The sensor model reported by the CCS driver is `imx681`. The tuning filename
must therefore be `imx681.yaml`, not `smiapp.yaml`. The patch adds that file to
the simple IPA's Meson install set. The standalone YAML beside the patch is an
audit copy and must stay byte-identical to the copy carried by the patch.

## Deliberate limits

- No fixed black level is asserted. The simple IPA estimates it until raw dark
  frames provide a defensible value.
- The CCMs are seed values from `karsies-wq/sp11-imx681-linux` commit
  `b08f76f40b8d7b715bd4da6aef484f86142cc147`; validate them with a colour
  target before treating image quality as calibrated.
- The patch does not change the global AGC target or Adjust defaults.
- It does not add a privacy-LED daemon. V4L2 core owns the DT privacy LED.
- It does not relax PipeWire service hardening.

## Build an Ubuntu package

Build from Ubuntu's matching source package instead of copying a locally built
IPA shared object over a packaged file. Use a new private directory and a
unique Debian revision for every build: Meson generates a new IPA signing key,
so reusing a version or a directory can make unrelated artifacts look
coherent. Ensure Ubuntu source repositories are enabled (`deb-src`, or
`deb deb-src` in the deb822 `Types` field). Run all of the following build,
verification, and installation blocks in the same shell; each block enables
strict error handling so a failed provenance check stops the workflow:

```bash
set -euo pipefail
export SP11_OE_REPO=/home/leon/Workspace/repos/linux-surface-pro-11-oe
sudo apt update
sudo apt install build-essential devscripts quilt libcamera-tools
sudo apt build-dep libcamera

export SP11_BASE_VERSION=0.7.0-1ubuntu2
export SP11_UPSTREAM_VERSION="${SP11_BASE_VERSION%%-*}"
export SP11_BUILD_ID="$(date -u +%Y%m%d%H%M%S%N)"
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
SP11_DEBIAN_SHA="$(awk -F': ' \
  '$1 == "Ubuntu Debian tarball SHA-256" { print $2 }' \
  "$SP11_OE_REPO/userspace/camera/libcamera/BASE.txt")"
grep -Eq '^[0-9a-f]{64}$' <<<"$SP11_ORIG_SHA"
grep -Eq '^[0-9a-f]{64}$' <<<"$SP11_DEBIAN_SHA"
printf '%s  %s\n%s  %s\n' \
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
   `$SP11_VERSION` (with its unique UTC build ID) and
   `/usr/share/libcamera/ipa/simple/imx681.yaml` exists:

   ```bash
   set -euo pipefail
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
   `1-16`, not kernel codes `0-960`. Capture at least 30 frames and confirm AE
   can move gain below the 4x kernel default in a bright scene.
6. Validate black level from raw dark frames and the CCMs with a colour target.
   Keep the estimator and seed matrices until those measurements pass.
7. Repeat stream start/stop and PipeWire/WebRTC tests. The privacy LED must be
   on only while V4L2 is streaming.
