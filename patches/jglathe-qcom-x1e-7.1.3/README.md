# Johan G. qcom-x1e 7.1.3 build compatibility patches

These patches are for building Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.1.3
branch with this repository's Docker kernel builder.

The upstream branch already carries the Surface Pro 11 Wi-Fi `disable-rfkill`
kernel and Denali DTB changes, so this directory only carries build policy
compatibility patches needed by Ubuntu's `check-config` step.

## Build environment

The verified Docker image is `ubuntu:26.04`. The kernel's `debian/control`
requires GCC 15, and the regeneration helper also installs
`gcc-15-aarch64-linux-gnu`, which provides
`aarch64-linux-gnu-gcc-15`.

## Why the annotations patch is larger than 7.1.1

The 7.1.1 source was authored against an Ubuntu 26.04 toolchain (rustc 1.93,
LLVM 21), so its annotations patch was minimal (just `DRM_MSM_VALIDATE_XML`
and `RUST_IS_AVAILABLE`).

The 7.1.3 annotations record rustc 1.88.0 and LLVM 20.1.5. The verified
`ubuntu:26.04` build uses rustc 1.93.1 and LLVM 21.1.8, exposes two additional
Rust feature probes, and supplies the package version signature. Together with
the obsolete `DRM_MSM_VALIDATE_XML` policy, this changes eight annotation
symbols. The annotations patch imports the `olddefconfig` output back into the
annotations file so `check-config` passes.

## Regenerating the annotations patch

If a future `jg/ubuntu-qcom-x1e-7.1.3-jg-*` branch has similar toolchain drift
(a `check-config` failure of the form `N config options have been changed`),
regenerate the `0001-debian-qcom-x1e-update-annotations-for-*.patch` patch with
the helper script:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch "jg/ubuntu-qcom-x1e-7.1.3-jg-<n>" \
  --reset-source
```

The helper runs the export → `olddefconfig` → import cycle inside an
`ubuntu:26.04` container, installs the complete build dependency set from the
kernel source package, and uses the same GCC and Rust probes as the real
package build. It writes the resulting patch back into this directory as
`0001-debian-qcom-x1e-update-annotations-for-7.1.3-jg-<n>.patch`. Any stale
prior `0001-debian-qcom-x1e-update-annotations-for-*.patch` is removed
automatically. Rerun the kernel build command unchanged afterwards;
`--reset-source` on the builder will pick up the new patch.

### Manual regeneration (fallback)

If the helper is unavailable, the same cycle can be run by hand from within an
`ubuntu:26.04` container with the source already cloned in the Docker volume:

```bash
VERSION=7.1.3-jg-1
BASE_VERSION=7.1.3
SRC="/linux-work/source/git-jg-ubuntu-qcom-x1e-${VERSION}"
BUILD_DIR=/tmp/build-config-update
ANNOTATIONS="$SRC/debian.qcom-x1e/config/annotations"
mkdir -p "$BUILD_DIR"

# Install the tools needed to generate and satisfy debian/control.
apt-get update
apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates cpio debhelper devscripts dpkg-dev \
  dwarves equivs flex gcc-15 gcc-15-aarch64-linux-gnu git kmod libelf-dev \
  libssl-dev python3 python3-dev rsync

# Generate debian/control and install the complete source build dependencies.
test -f "$SRC/debian/control" || (cd "$SRC" && ./debian/rules debian/control)
(cd /tmp && mk-build-deps --install --remove \
  --tool "apt-get -y --no-install-recommends" "$SRC/debian/control")

# Export annotations to .config. The explicit -f is required when the command
# is run outside the kernel source directory.
python3 "$SRC/debian/scripts/misc/annotations" -f "$ANNOTATIONS" \
  --export --arch arm64 --flavour qcom-x1e > "$BUILD_DIR/.config"
SIGNATURE="Ubuntu ${VERSION}-qcom-x1e ${BASE_VERSION}"
sed -i \
  "s/.*CONFIG_VERSION_SIGNATURE.*/CONFIG_VERSION_SIGNATURE=\"${SIGNATURE}\"/" \
  "$BUILD_DIR/.config"

MAKE_ARGS=(
  -C "$SRC" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
  HOSTCC=aarch64-linux-gnu-gcc-15 CC=aarch64-linux-gnu-gcc-15
  RUSTC=rustc HOSTRUSTC=rustc RUSTFMT=rustfmt BINDGEN=bindgen
  "KERNELRELEASE=${VERSION}-qcom-x1e" CONFIG_DEBUG_SECTION_MISMATCH=y
  KBUILD_BUILD_VERSION=1 CFLAGS_MODULE=-DPKG_ABI=1 PYTHON=python3
)
make "${MAKE_ARGS[@]}" rustavailable || true
make "${MAKE_ARGS[@]}" olddefconfig

python3 "$SRC/debian/scripts/misc/annotations" -f "$ANNOTATIONS" \
  --arch arm64 --flavour qcom-x1e --import "$BUILD_DIR/.config"

# Capture the diff
git -C "$SRC" diff -- debian.qcom-x1e/config/annotations \
  > "0001-debian-qcom-x1e-update-annotations-for-${VERSION}.patch"
```

Set `VERSION` to the full version token and `BASE_VERSION` to the version
without the `-jg-<n>` suffix. The `CONFIG_VERSION_SIGNATURE` value must match
what `debian/rules.d` injects during the real build.

For `7.1.3-jg-1`, the complete package build should subsequently report
`check-config: all good` and produce image, modules, ABI-specific headers, and
common qcom-x1e headers packages containing `7.1.3-jg-1` in their filenames.
