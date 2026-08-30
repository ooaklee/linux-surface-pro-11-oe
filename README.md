# Linux on Microsoft Surface Pro 11

This repository develops `linux-armer`, an ARM64 command-line companion for
building, validating, writing and maintaining experimental Surface Pro 11
Linux media. The supported path is the compiled CLI: repository scripts are
not part of the current operator workflow.

> [!WARNING]
> The generated media, custom kernels and hardware support remain
> experimental. Back up important data, keep a known-good boot entry and a
> separate recovery device, and disable Secure Boot before booting an unsigned
> custom kernel.

The first implemented image adapter is
`ubuntu-concept-resolute-x1e`. Other ARM64 images can appear in the catalogue
without being buildable; `catalog show` reports an entry's actual support
level.

## Build the CLI

The build host needs Go 1.26 or newer. Image and kernel builds also need a
running Docker daemon with Linux ARM64 container support.

```sh
go -C cli/linux-armer build -o bin/linux-armer ./cmd/linux-armer
./cli/linux-armer/bin/linux-armer doctor
```

Run `linux-armer` in an interactive terminal to open the wizard, or use the
same services through explicit subcommands. `linux-armer <command> --help`
shows the options implemented by that command. The examples below use
`linux-armer` for a binary installed on `PATH`; substitute
`./cli/linux-armer/bin/linux-armer` when running directly from the checkout.

## End-to-end workflow

### 1. Inspect the source-image catalogue

```sh
linux-armer catalog validate
linux-armer catalog list
linux-armer catalog show ubuntu-concept-resolute-x1e
```

Catalogue-only entries are useful references, but `image create` accepts only
an entry with an implemented adapter.

### 2. Obtain a kernel bundle

Build the maintained custom kernel in the CLI-owned ARM64 container workflow:

```sh
linux-armer kernel build --dry-run
linux-armer kernel build \
  --output-dir build/linux-armer/kernel-current
linux-armer kernel inspect build/linux-armer/kernel-current
```

Use `--git-url` and `--git-branch` only when intentionally testing another
kernel source. `--reset-source` resets the source tree in the CLI-owned work
volume; it does not modify a host checkout.

Alternatively, download a published, checksum-verified kernel release:

```sh
linux-armer kernel release list
linux-armer kernel release download <release-tag> \
  --output-dir build/linux-armer/kernel-bundle
linux-armer kernel inspect build/linux-armer/kernel-bundle
```

See [Build a Patched qcom-x1e Kernel](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
and [Prepare Kernel Release Artefacts](docs/how-to/how-to-release-kernel-artifacts.md)
for the detailed build and release paths.

### 3. Create the live image

Use a local upstream image and record its independently obtained SHA-256 when
possible:

```sh
linux-armer image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-dir build/linux-armer/kernel-bundle \
  --output build/linux-armer/linux-armer-ubuntu-sp11.iso
```

Omit `--source` to let the catalogue download the pinned source, or replace
`--kernel-dir` with `--kernel-release <release-tag>`. Add `--dry-run` to review
the plan without remastering.

To carry the companion CLI, maintained source and an eligible offline IPTSD
release on the medium:

```sh
linux-armer image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-release <release-tag> \
  --companion-source-dir cli/linux-armer \
  --companion-userspace iptsd \
  --output build/linux-armer/linux-armer-ubuntu-sp11.iso
```

The image contains one logical inventory. Its on-media copy is
`/sp11/linux-armer-manifest.json`, and the generated ISO has the matching
sidecar representation. `companion_bundle` is an attribute of that existing
ISO manifest, including when no companion is requested. It is never a separate
companion manifest. Portable userspace receipts verify their own component
files but do not create another ISO inventory.

### 4. Validate and write the USB

```sh
linux-armer image validate build/linux-armer/linux-armer-ubuntu-sp11.iso
linux-armer image devices
linux-armer image write build/linux-armer/linux-armer-ubuntu-sp11.iso \
  --device <whole-device> \
  --dry-run
```

Repeat `image write` without `--dry-run` and enter the exact confirmation it
prints. The writer rejects unsafe targets and succeeds only after a full
SHA-256 read-back and safe ejection.

### 5. Install while retaining a fallback

Keep the running, known-good ABI installed. Inspect the downloaded bundle,
then preflight the target before changing it:

```sh
linux-armer kernel inspect kernel-bundle
linux-armer kernel preflight kernel-bundle \
  --root / \
  --fallback-abi <known-good-abi>
linux-armer kernel install kernel-bundle \
  --root / \
  --fallback-abi <known-good-abi> \
  --dry-run
```

Review the plan, then repeat `kernel install` with elevated privileges and
`--yes`. For an installed system mounted below a live environment, replace `/`
with that absolute mount point. The full recovery procedure is in
[Reinstall a Patched Kernel from USB](docs/how-to/how-to-reinstall-patched-kernel-from-usb.md).

### 6. Manage userspace support

```sh
linux-armer userspace catalog validate
linux-armer userspace list
linux-armer userspace status
linux-armer userspace pull recommended --cache-dir build/linux-armer/userspace
linux-armer userspace install recommended \
  --from build/linux-armer/userspace \
  --dry-run
```

Repeat the install with elevated privileges and `--yes` after reviewing it.
IPTSD and camera components also have maintained native builds. Camera supports
a non-mutating plan; the IPTSD build executes when invoked:

```sh
linux-armer userspace build iptsd \
  --output-dir build/linux-armer/iptsd
linux-armer userspace build camera \
  --output-dir build/linux-armer/camera \
  --dry-run
```

Audio, pen and camera have different support grades. Inspect
`userspace show <component>` before changing a system.

### 7. Diagnose the host and device

```sh
linux-armer doctor
linux-armer doctor userspace
linux-armer doctor hardware wifi bluetooth audio
```

Use `--root <absolute-path>` with the userspace or hardware doctor to inspect a
mounted target. Diagnostic commands do not change the system. Review their
output before sharing it because host diagnostics can include environment
paths; device diagnostics deliberately omit private device identities.

### 8. Import private Windows material

Some device-bound platform firmware and the Bluetooth public address must come
from the same Surface. On Windows, run the canonical collector from a private
checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\linux-armer\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff
```

The collector never exports Windows Wi-Fi firmware. Treat its output as
private, device-bound and proprietary; do not publish it or add it to an image
or release. Move it privately to Linux, then validate and import it:

```sh
linux-armer handoff import /path/to/sp11-handoff
linux-armer handoff list
linux-armer handoff apply <id> \
  --target-root / \
  --feature firmware \
  --feature bluetooth \
  --adsp-policy enabled \
  --dry-run
```

Use `--adsp-policy disabled` for a live USB target and `enabled` for the
installed NVMe system. Repeat the apply with the exact confirmation after
review. `handoff restore` reverses a recorded application, and `handoff purge`
removes a reviewed private import from the store.

### 9. Detect and recover from recognised legacy changes

Never remove old workarounds by guessing paths. Build an exact plan from the
CLI's bounded allow-list:

```sh
linux-armer clean scan --root /
linux-armer clean plan --root / \
  --output linux-armer-cleanup-plan.json
sudo linux-armer clean apply --root / \
  --plan linux-armer-cleanup-plan.json \
  --yes
```

Keep the durable receipt. If needed, validate and restore the captured entries:

```sh
sudo linux-armer clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --yes
```

## Current guidance

- [CLI reference and safety model](cli/linux-armer/README.md)
- [Supported image catalogue](cli/linux-armer/supported-isos.json)
- [How-to guides](docs/how-to/)
- [Architecture decisions](docs/adr/)
- [Kernel release preparation](docs/how-to/how-to-release-kernel-artifacts.md)
- [Kernel recovery from USB](docs/how-to/how-to-reinstall-patched-kernel-from-usb.md)

Documents and reports with explicit historical dates remain evidence of the
experiments they describe. Use this README and the current how-to guides for
operator actions.
