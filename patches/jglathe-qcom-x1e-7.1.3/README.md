# Johan G. qcom-x1e 7.1.3 build compatibility patches

These patches are for building Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.1.3
branch with this repository's Docker kernel builder.

The upstream branch already carries the Surface Pro 11 Wi-Fi `disable-rfkill`
kernel and Denali DTB changes, so this directory only carries build policy
compatibility patches needed by Ubuntu's `check-config` step.

## Build environment

The only viable Docker image is `ubuntu:26.04`. The kernel's `debian/control`
hardcodes `gcc-15` as a build dependency, and no other stable distribution
release provides that package.

## Why the annotations patch is larger than 7.1.1

The 7.1.1 source was authored against an Ubuntu 26.04 toolchain (rustc 1.93,
LLVM 21), so its annotations patch was minimal (just `DRM_MSM_VALIDATE_XML`
and `RUST_IS_AVAILABLE`).

The 7.1.3 source regressed — its annotations were authored against an older,
nonstandard toolchain (rustc 1.88, LLVM 20). Building under `ubuntu:26.04`
causes 20 config options to differ. The annotations patch imports the
`olddefconfig` output back into the annotations file so `check-config` passes.

## Regenerating the annotations patch

If a future branch has similar toolchain drift, regenerate the patch from
within an `ubuntu:26.04` container:

```bash
# With the source already cloned in the Docker volume:
SRC=/linux-work/source/git-jg-ubuntu-qcom-x1e-<version>
BUILD_DIR=/tmp/build-config-update

# Export annotations to .config, run olddefconfig, import changes
python3 "$SRC/debian/scripts/misc/annotations" --export --arch arm64 --flavour qcom-x1e > "$BUILD_DIR/.config"
sed -i 's/.*CONFIG_VERSION_SIGNATURE.*/CONFIG_VERSION_SIGNATURE="Ubuntu <version>-qcom-x1e <version>"/' "$BUILD_DIR/.config"
make -C "$SRC" O="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
python3 "$SRC/debian/scripts/misc/annotations" -f "$SRC/debian.qcom-x1e/config/annotations" \
  --arch arm64 --flavour qcom-x1e --import "$BUILD_DIR/.config"

# Capture the diff
git -C "$SRC" diff -- debian.qcom-x1e/config/annotations > 0001-debian-qcom-x1e-update-annotations-for-<version>.patch
```
