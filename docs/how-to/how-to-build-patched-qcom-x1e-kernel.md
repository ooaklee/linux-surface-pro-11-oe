---
id: how-to-build-patched-qcom-x1e-kernel
title: "Build a Patched qcom-x1e Kernel"
# prettier-ignore
description: How-to guide for building and testing a Surface Pro 11 qcom-x1e kernel with ath12k disable-rfkill support.
---

# How To: Build a Patched qcom-x1e Kernel

Use this procedure when Wi-Fi probes on Surface Pro 11 but remains
hard-blocked by rfkill, and `scripts/troubleshoot-sp11-wifi-rfkill.sh` reports
that the installed ath12k modules do not contain `disable-rfkill` support.

## Purpose

The firmware and board-file helpers are enough for WCN7850 to probe, load
firmware, and create an interface. On Surface Pro 11, Wi-Fi still needs ath12k
to skip rfkill configuration for the Denali WCN7850 devicetree node.

This procedure builds Ubuntu qcom-x1e kernel packages with the targeted
Surface Pro 11 rfkill patches.

## Prerequisites

- Installed Ubuntu on Surface Pro 11, booting from internal NVMe.
- Temporary networking through USB-C Ethernet, USB phone tethering, or another
  non-Wi-Fi path.
- Secure Boot disabled.
- The direct live USB kept nearby as a recovery environment.
- At least 40 GB free disk space for the kernel source, build tree, and
  generated `.deb` packages.
- AC power connected. Kernel builds can take a long time.
- An older known-good qcom-x1e kernel still installed. Do not run
  `apt autoremove` before this experiment.
- For the preferred off-device build: Docker on a host that can run
  `linux/arm64` containers. Native ARM64 is fastest; x86_64 hosts may use QEMU
  emulation and can be much slower.
- The Docker build host must provide `python3` and either the regular system
  `/usr/lib/apt/apt-helper` or `lz4` on `PATH`. The wrapper checks this before
  starting the immutable release build; macOS hosts normally use `lz4`.
- Enough Docker storage for a persistent Linux work volume. The host work
  directory only receives control files and copied artifacts; the kernel source
  and object tree are kept in Docker's `sp11-qcom-x1e-kernel-build` volume.

## Procedure

1. Mount the `SP11DATA` USB partition and enter the support directory.

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
cd "$SP11DATA/support"
```

2. Confirm the current failure mode.

```bash
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Continue only if Wi-Fi is still hard-blocked and the ath12k module scan says
`disable-rfkill support not found`.

## Dockerized ARM64 Build

Use this path when you have a stronger build machine available. The Surface
exports the exact qcom-x1e source package metadata, the build host compiles in
a Docker ARM64 Linux container, and the generated packages are copied into the
USB payload.

3. On the Surface, write the running kernel source metadata to `SP11DATA`.

```bash
./scripts/collect-sp11-kernel-source-metadata.sh \
  --out "$SP11DATA/sp11-kernel-source.env"
```

4. Move the USB back to the Docker build host, enter this repository root, then
   build the patched packages.

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

The wrapper runs Docker with `--platform linux/arm64`. The host `--work-dir`
stores Docker control files and copied artifacts. The actual kernel source and
object tree build under `/linux-work` in the Docker volume
`sp11-qcom-x1e-kernel-build`, which keeps the Linux kernel checkout on a
case-sensitive filesystem even when the build host is macOS. Successful builds
copy generated qcom-x1e `.deb` files to
`build/docker-sp11-qcom-x1e-kernel/artifacts/`, then to
`payload/kernel-debs/` when `--copy-to-payload` is set. Because the container
runs as root, the wrapper also runs Ubuntu `debian/rules` directly instead of
through `fakeroot`.

Treat `build/docker-sp11-qcom-x1e-kernel/artifacts/` as managed scratch space.
Real Docker runs clean it inside the container before copying new packages so
stale `.deb` files cannot leak into `payload/kernel-debs/`.

If the container cannot fetch the exact qcom-x1e source version, provide
matching apt source configuration from the same repositories that provided the
installed kernel:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --metadata /path/to/sp11-kernel-source.env \
  --apt-sources /path/to/qcom-x1e.sources \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

For bring-up only, the Docker wrapper can use the public git branch instead of
apt source metadata:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --work-dir build/docker-sp11-qcom-x1e-kernel \
  --copy-to-payload
```

Treat git mode as a fallback because it may not match the exact qcom-x1e
package version currently installed on the Surface. Git mode defaults to an
`ubuntu:25.10` container because the current `qcom-x1e-7.0` git branch expects
Rust 1.85 and LLVM 19 during Ubuntu config validation.

### Johan G. 7.1.3 source

The `jg/ubuntu-qcom-x1e-7.1.3-jg-1` tag requires Ubuntu 26.04, the matching
build-compatibility patches, and the standard Surface Pro 11 v2 patch set:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.1.3 patches/sp11-qcom-x1e-7.1.3-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.3-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.1.3-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 4 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-jg-7.1.3-sp11-v2-build-$(date +%Y%m%d-%H%M%S).log
```

If `check-config` reports changed options after moving to a newer `jg-*` tag,
regenerate the tag-specific annotations patch first:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch "jg/ubuntu-qcom-x1e-7.1.3-jg-<n>" \
  --reset-source
```

The helper removes only the stale tag-specific annotations patch. It preserves
the other compatibility patches in the directory. Rerun the original build
command unchanged after confirming the new patch filename.

### Johan G. 7.2-rc5 v2 source

The `jg/ubuntu-qcom-x1e-7.2rc` branch carries the Surface Pro 11 Wi-Fi
`disable-rfkill` change and the Denali DTB `disable-rfkill;` node upstream, so
no local rfkill or DTS patches are required (see
[ADR0047](../adr/adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)). The upstream
branch configures the DMIC clock at 4.8 MHz, which reintroduces microphone
static, so the Surface Pro 11 v2 patch set restores the validated 2.4 MHz
clock and gives the result the distinct `7.2-rc5-jg-0sp11v2` ABI:

Use the immutable `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` tag for pinned build
provenance. The command below is a normal local build. A future publishable
build must also pass `--release-build` and follow
[Release Prebuilt Kernel Artifacts](how-to-release-kernel-artifacts.md); the
moving `jg/ubuntu-qcom-x1e-7.2rc` branch is not durable release provenance.

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 8 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v2-build-$(date +%Y%m%d-%H%M%S).log
```

The output is a matching four-package set
(`linux-image`, `linux-modules`, `linux-headers`,
`linux-qcom-x1e-headers`). See
[ADR0048](../adr/adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build.md) for the
DMIC decision and embedded-DTB correction. ADR0055 retires the former
installed loose-DTB selector.

### Johan G. 7.2-rc5 v3 source (touchscreen)

The Surface Pro 11 v3 build layers the MSHW0485 OLED touchscreen enablement on
top of the v2 build. It restores the validated 2.4 MHz DMIC clock, enables the
`spi@a88000` QSPI controller in the Denali device tree, and gives the result
the distinct `7.2-rc5-jg-0sp11v3` ABI:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3 \
  --copy-to-payload \
  --reset-source \
  --jobs 8 \
  2>&1 | tee build/sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3-build-$(date +%Y%m%d-%H%M%S).log
```

For a fresh experimental release-mode verification run, use the baseline's
exact platform as well as its image digest, start with a clean repository, and
choose a new work directory and Docker volume:

```bash
RELEASE_CHECK_WORK=build/docker-sp11-qcom-x1e-kernel-release-check
SIGNING_DIR="<owner-controlled-private-signing-directory>"
SIGNING_KEY="$SIGNING_DIR/sp11-module-signing-key.pem"
SIGNING_CERT="$SIGNING_DIR/sp11-module-signing-cert.pem"
SIGNING_PIN_FILE="$SIGNING_DIR/sp11-module-signing-pin.txt"
test ! -e "$RELEASE_CHECK_WORK"
test -f "$SIGNING_KEY"
test -f "$SIGNING_CERT"
test -f "$SIGNING_PIN_FILE"
install -d -m 0700 "$RELEASE_CHECK_WORK"
install -d -m 0700 "$RELEASE_CHECK_WORK/artifacts"
ARTIFACTS_FIRST_ENTRY="$(
  find "$RELEASE_CHECK_WORK/artifacts" \
    -mindepth 1 -maxdepth 1 -print -quit
)" || exit 1
test -z "$ARTIFACTS_FIRST_ENTRY"

./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --platform linux/arm64/v8 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3 patches/sp11-qcom-x1e-7.2-rc5-release-signing-v1" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir "$RELEASE_CHECK_WORK" \
  --linux-work-volume sp11-qcom-x1e-kernel-release-check \
  --module-signing-key "$SIGNING_KEY" \
  --module-signing-certificate "$SIGNING_CERT" \
  --module-signing-pin-file "$SIGNING_PIN_FILE" \
  --reset-source \
  --release-build \
  --jobs 8
```

Release mode refuses `--apt-sources`. It uses the exact
`20260807T000000Z` Ubuntu snapshot and retains the authenticated APT cache,
signed indexes, acquired list targets, and pre/post installed-package
inventories in the private daemon-owned release-state volume. After the build
container has stopped, a separate network-disabled container mounts that volume
read-only and exports the bounded canonical host record
`sp11-kernel-retained-evidence.tar`. The host work directory therefore contains
that tar, three bound controller files, and the flat `artifacts/` directory; it
does not recreate the retained APT directory trees. A successful run requires
all four files below in `artifacts/`:

The pinned snapshot contains six signed, positive-size backports indexes whose
decompressed payload is empty. APT legitimately emits no local list view for
those indexes. Release mode binds the six exact paths and compressed
identities, requires their views to be absent, and still requires and verifies
the other 26 list views. It never fabricates placeholder list files.

```text
artifacts/sp11-kernel-build-manifest.txt
artifacts/sp11-kernel-module-signatures.txt
artifacts/sp11-kernel-apt-provenance.txt
artifacts/sp11-kernel-build-inputs.txt
```

Require the imported record and its three host controls as well:

```bash
test -s "$RELEASE_CHECK_WORK/sp11-kernel-retained-evidence.tar"
test -s "$RELEASE_CHECK_WORK/docker-build-args.txt"
test -s "$RELEASE_CHECK_WORK/docker-build-inside.sh"
test -s "$RELEASE_CHECK_WORK/sp11-oci-index.json"
```

Preserve `sp11-kernel-retained-evidence.tar` together with those three files.
The release preparer validates and cross-binds the tar, the flat artifacts, and
the controller files before it creates a local review candidate.

The underlying immutable-input build and validation path has one real result in
the [2026-08-08 build evidence](../sp11-kernel-immutable-build-evidence-20260808.md).
That run predates the daemon-owned volume, read-only exporter, and canonical
evidence-tar handoff described above; the new handoff has no real integration
result yet and still requires a fresh end-to-end run. The historical result is
one provenance-validated build, not a byte-reproducibility result. Its last
envelope deliberately records publication schema propagation as incomplete
because that is its immutable build-time state. The kernel and image
preparation paths consume and validate the exact provenance set and record its
propagation completion in outer manifests while keeping overall publication
blocked. Preserve all four files byte-for-byte. ADR-0056 resolves the signing
decision in favor of an encrypted owner-controlled RSA-4096 key shared by the
packaged in-tree kernel modules and exact-ABI touchscreen modules, with only its
public certificate identity propagated. The controlled-signing implementation
and hostile fixture gates are
part of the current release path, but no fresh real C/D pair has yet established
byte reproducibility. Recovery/hardware evidence, corresponding-source review,
and explicit release authorization also remain open. [`LEGAL.md`](../../LEGAL.md)
records the interim MIT direction for project-authored code and the upstream
ALSA/local-hardware-configuration basis for SP11 UCM; both final reviews remain
pending, but that pending status alone does not block ordinary development or
publication of newly authored material.

#### Deterministic identity and the next raw comparison

The deterministic, signing-independent kernel/Deb build identity is
implemented and fixture-tested. Release mode takes the fixed
`SOURCE_DATE_EPOCH`, `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`, and
`KBUILD_BUILD_TIMESTAMP` values from the committed baseline, checks the epoch
against the pinned source commit, and propagates them through build-dependency
generation and both Debian kernel-package targets. This foundation does not
make generated development signing reproducible. ADR-0056 adds the controlled
module-signing model; generated development signing remains non-release and
cannot satisfy the raw comparison.

After two new clean builds from the same committed support HEAD, compare their
retained work directories without normalization:

```bash
REPO_ROOT="$(pwd -P)"
SUPPORT_HEAD="$(git rev-parse --verify HEAD)"
python3 -I ./scripts/compare-sp11-kernel-raw-builds.py \
  --baseline "$REPO_ROOT/config/kernel-baselines/7.2-rc5-jg-0.env" \
  --support-repo "$REPO_ROOT" \
  --support-head "$SUPPORT_HEAD" \
  --build-a "$REPO_ROOT/build/sp11-kernel-clean-c" \
  --build-b "$REPO_ROOT/build/sp11-kernel-clean-d"
```

The fail-closed `sp11-kernel-raw-matched-pair-v1` comparator is implemented,
reviewed, and wired into CI through hostile synthetic fixtures. It accepts a
pair only after matching the immutable retained inputs, then compares every
kernel Deb and the seven manifest outputs as raw bytes or raw identities under
`sp11-kernel-zero-normalization-v1`. Controlled-signing candidates must also
carry matching cryptographic module-signature reports and exact reviewed
unsigned-path inventories; those reports are evidence assets rather than an
eighth source-tree output. A validated mismatch exits `1`; unsafe or
inconsistent input exits `2`. Its report always records publication as
unauthorized.

No fresh C/D pair has been built or compared since the deterministic identity
was added. P0.4b and P0.4 overall therefore remain open, while P0.4c remains
the single earlier real immutable-input build. The signing model is selected,
but no fresh controlled-signing build pair exists. The deterministic
patched-source generator is implemented,
but the retained 2026-08-08 exact four-patch tree was correctly rejected for an
escaping tracked symlink; a corrected fresh build and new manifest are required
before archive validation can resume. Recovery/hardware evidence, legal
corresponding-source review, and explicit authorization remain **NO-PUBLISH**
gates. The interim licence/UCM direction in [`LEGAL.md`](../../LEGAL.md) does
not replace third-party per-file terms or the pending final reviews, but those
reviews are no longer blanket publication gates for newly authored artifacts.

The exact-tree preflight treats the digest-pinned OCI/APT toolchain as trusted
build authority. It is not a sandbox against source rules that can mutate a
root-writable container runtime; that stronger threat model requires a separate
non-root or read-only-root-filesystem build design.

The host-side Docker launch assumes an exclusive, trusted host controller from
before private control/output-root creation or acquisition through bind-source
resolution and use. After a root is acquired, release-mode writes are confined
to held directory and creation-owned file descriptors; collisions, links,
special nodes, persistent mapping drift, and pathname deletion or overwrite are
rejected. This flow does not claim integrity, availability, or victim
preservation against a concurrent process with the same host credentials
racing root creation/acquisition or substituting a validated bind source. That
stronger guarantee requires privilege separation or a separately reviewed
supervisor and daemon-owned, content-addressed inputs.

That trusted-controller boundary also requires exclusive use of the selected
Docker context, socket, and daemon credentials, with no concurrent read-write
mount or mutation of the named release-state volume from creation through
evidence import. A daemon-owned volume is not itself immutable or
content-addressed. Any later forensic use of the retained volume requires the
same exclusive custody and a fresh validation; the imported evidence tar is
the bounded host-side record of the accepted run.

Host-side orchestration also assumes an exclusive trusted checkout and a
non-hostile process environment, system toolchain, and `PATH`; it does not
claim resistance to a malicious replacement of ordinary host utilities.
Security-critical retained release-evidence helpers use absolute isolated
interpreter authority and commit-bound code, while legacy orchestration
utilities remain inside this
explicit host-toolchain boundary.

The kernel ABI carries the touchscreen device tree, but the runtime QSPI
support ships as out-of-tree modules from the geocausa Phase 91 baseline
(`gpi`, `spi-geni-qcom`, `mshw0485_touch`). Build them against the installed
v3 headers on the device. The pinned helper installs them as `updates/`
overrides, regenerates the exact target initramfs with the available Ubuntu
backend, and verifies that it contains the custom source versions:

```bash
./scripts/build-sp11-touchscreen-modules.sh --install
```

If multiple v3 header trees are installed, pass `--release VER`. The script
refuses plain and v2 ABIs by default because compiling successfully against
their headers does not add the required MSHW0485 device-tree node. The default
uses the validated Linux-integrated controller path; reserve
`--windows-se-init` for a diagnosed cold-boot A/B test.

See [ADR0049](../adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md) for
the touchscreen kernel decision and
[ADR0050](../adr/adr-0050-sp11-touchscreen-clean-install-release-flow.md) for
the clean-install deployment and release-integrity decision.

5. Rebuild and write the live USB image so `payload/kernel-debs/` is copied to
   `SP11DATA`.

Use the same image-builder options that are working for the current test path,
for example the direct-boot image from the README:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso path/to/ubuntu-x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate

./scripts/write-image-to-macos-disk.sh build/sp11-ubuntu-live-direct.img /dev/diskX
```

Replace `/dev/diskX` with the verified removable USB disk.

6. Boot back into installed Ubuntu, mount `SP11DATA`, and install the payload
   packages with the Surface-side fallback guard.

```bash
cd "$SP11DATA/support"
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only
```

The helper refuses to install if it cannot find another installed qcom-x1e
kernel ABI to use as a GRUB fallback. Do not override that guard unless you are
comfortable recovering through the direct live USB:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$SP11DATA/payload/kernel-debs" \
  --install-only \
  --allow-no-fallback
```

For debugging, inspect the generated package list before installing:

```bash
find "$SP11DATA/payload/kernel-debs" -maxdepth 1 -type f -name '*.deb' -print | sort
```

Use `--install-only` for the actual install so the fallback-kernel guard and
post-install support helper run consistently.

## On-Device Build Fallback

Use this path when Docker is not available.

1. Build from the installed Ubuntu source package version.

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

This can take hours. The helper writes a manifest at:

```text
$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-build-manifest.txt
```

If apt source download fails because source repositories are disabled, enable
source entries for the same Ubuntu/PPA repositories that provide the installed
qcom-x1e packages, run `sudo apt update`, and rerun the command. By default the
helper derives the source package and version from the running kernel packages,
starting with `linux-modules-$(uname -r)`. Use `--source-version candidate`
only when you intentionally want to build the apt source candidate instead.

2. Install the generated qcom-x1e kernel packages.

The helper can do this directly:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

The helper refuses to install if it cannot find another installed qcom-x1e
kernel ABI to use as a GRUB fallback. Do not override that guard unless you are
comfortable recovering through the direct live USB:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only \
  --allow-no-fallback
```

For debugging, inspect the generated package list before installing:

```bash
cat "$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-debs.txt"
```

Use `--install-only` for the actual install so the fallback-kernel guard and
post-install support helper run consistently.

## Reboot and Validate

On the tested installed qcom-x1e Stubble path, each kernel uses the Denali DTB
embedded in its exact Stubble-wrapped EFI image. The support installer does
not select, copy, or inject a shared loose DTB. If
`/boot/sp11-denali.dtb` exists from an earlier release, it is left untouched
as inert recovery evidence; its presence or contents do not establish
live-FDT provenance. The guarded install must finish its normal live-root GRUB
regeneration successfully before reboot.

1. Reboot and choose the patched kernel.

```bash
sudo reboot
```

If the patched kernel fails, use GRUB advanced options to boot another
known-good qcom-x1e kernel such as the verified `7.0.0-32-qcom-x1e` entry, or
boot the direct live USB and rerun the installed support helper.

## Expected Output

The build should produce qcom-x1e kernel `.deb` packages under the selected
work directory, including image, modules, and headers packages.

After booting the patched kernel, `uname -r` should match the ABI that the
build produced. For the first verified Docker git-fallback build this is
`7.0.0-22-qcom-x1e`, even though the Surface had previously upgraded to
`7.0.0-32-qcom-x1e`. The important validation is whether the loaded ath12k
module and device tree now expose `disable-rfkill`.

## Validation

After reboot, rerun:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Passing validation for the patch experiment means:

- `DT has disable-rfkill`,
- Wi-Fi `phy0` no longer reports `Hard blocked: yes`.

The module string scan is best-effort. If it says support is not found but the
running patched kernel, loaded DTB property, and `rfkill` hard state all match
the expected values, treat the runtime rfkill result as authoritative and move
on to Wi-Fi scan/connect validation.

That proves the rfkill gate moved. It does not prove Bluetooth, suspend,
touchscreen, audio, camera, or long-term Wi-Fi stability.

## Privacy and Safety

Do not commit generated kernel source trees, `.deb` packages, firmware files,
or logs containing local network configuration.

Keep the previous qcom-x1e kernel installed until the patched kernel has booted
and the rfkill result is known. Avoid `apt autoremove` during this experiment.

## Troubleshooting

If apt source download fails, enable matching source repositories for the
running qcom-x1e kernel source and rerun `sudo apt update`.

If a patch does not apply, stop and record the source package version. The
Ubuntu qcom-x1e source may have changed enough that the patch needs to be
refreshed.

If a Docker build fails with `libfakeroot internal error: payload not
recognized!`, make sure the inner build is running in the wrapper's default
root container path. The root container does not need `fakeroot`, and the
wrapper passes `--no-fakeroot` to assert that direct `debian/rules` path during
the long parallel package build.

If a Docker build logs `warning: the following paths have collided` and later
fails with a missing target such as `net/netfilter/xt_DSCP.o`, the kernel
source was checked out on a case-insensitive filesystem. Use the wrapper's
default `/linux-work` Docker volume path. Do not force `--container-work-dir
/work` on default macOS APFS unless `/work` is backed by a case-sensitive
filesystem.

For reruns in the default Docker volume path, pass `--reset-source` when you
want a fresh checkout. The host wrapper cannot inspect the Docker volume
without starting a container, so stale-source detection happens inside the
inner build helper.

If the build runs out of disk space, remove the host work directory. To also
discard the persistent Docker source/build volume, remove it explicitly:

```bash
rm -rf build/docker-sp11-qcom-x1e-kernel
docker volume rm sp11-qcom-x1e-kernel-build
```

If the patched kernel boots but Wi-Fi is still hard-blocked, save the full
troubleshooting output and compare the DT and ath12k support lines first.

If Wi-Fi disappears from the desktop UI after firmware changes and the dmesg
output shows `failed to start mhi: -34` or `failed to power up :-34`, do a full
cold boot before changing firmware again. On the verified installed system, a
cold boot restored WCN7850 probe and interface creation, after which Wi-Fi
returned to the expected `phy0` hard-blocked state.

## Related Documents

- [ADR018: Wi-Fi rfkill Bring-Up Gate](../adr/adr-0018-wifi-rfkill-bring-up-gate.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [ADR020: Dockerized ARM64 Kernel Build](../adr/adr-0020-dockerized-arm64-kernel-build.md)
- [ADR021: Git Fallback Kernel Build Toolchain](../adr/adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR022: Docker Kernel Build Without fakeroot](../adr/adr-0022-docker-kernel-build-without-fakeroot.md)
- [ADR023: Docker Kernel Build Case-Sensitive Work Volume](../adr/adr-0023-docker-kernel-build-case-sensitive-work-volume.md)
- [ADR047: JG 7.2-rc5-jg-0 Kernel Build](../adr/adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)
- [ADR048: JG 7.2-rc5-jg-0sp11v2 Kernel Build](../adr/adr-0048-jglathe-qcom-7-2-rc5-jg-0sp11v2-build.md)
- [ADR049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build](../adr/adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [Surface Pro 11 Wi-Fi rfkill test after qcom-x1e upgrade](../installed-wifi-rfkill-upgrade-test-20260613.md)
- [Surface Pro 11 Wi-Fi test after Windows firmware and cold boot](../installed-wifi-windows-firmware-cold-boot-test-20260613.md)
