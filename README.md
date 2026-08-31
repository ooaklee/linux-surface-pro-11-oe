# Linux on Microsoft Surface Pro 11

This repository develops the OpenEmbedded integration and hardware support for
running ARM64 Linux on the Surface Pro 11. The command-line companion is now
[Lexr.sh](https://github.com/ooaklee/lexr.sh), maintained in its own repository
and pinned here as the `cli/lexr` submodule. The supported path is the compiled
`lexr` CLI; repository scripts are not part of the current operator workflow.

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
running Docker daemon with Linux ARM64 container support. Initialise the pinned
submodule after cloning this repository, then build Lexr from its module:

```sh
git submodule update --init --recursive
mkdir -p cli/lexr/bin
go -C cli/lexr build -o bin/lexr ./cmd/lexr
./cli/lexr/bin/lexr doctor
```

Clone [the standalone Lexr.sh repository](https://github.com/ooaklee/lexr.sh)
instead when working on the CLI independently of this OE integration. Run
`lexr` in an interactive terminal to open the wizard, or use the same services
through explicit subcommands. `lexr <command> --help` shows the options
implemented by that command. The examples below use `lexr` for a binary
installed on `PATH`; substitute `./cli/lexr/bin/lexr` when running directly
from this checkout.

Lexr.sh is the current product name and `lexr` is the current command. Existing
schema and installed-state paths remain unchanged for compatibility, including
`/sp11/linux-armer-manifest.json`, `${HOME}/.linux-armer-handoffs` and
`/var/lib/linux-armer`. Established `linux-armer-*.json` bundle, provenance and
release filenames also remain stable; new transient output belongs under
`build/lexr`.

## End-to-end workflow

### 1. Inspect the source-image catalogue

```sh
lexr catalog validate
lexr catalog list
lexr catalog show ubuntu-concept-resolute-x1e
```

Catalogue-only entries are useful references, but `image create` accepts only
an entry with an implemented adapter.

### 2. Obtain a kernel bundle

Build the maintained custom kernel in the CLI-owned ARM64 container workflow:

```sh
lexr kernel build --dry-run
lexr kernel build \
  --output-dir build/lexr/kernel-current
lexr kernel inspect build/lexr/kernel-current
```

Use `--git-url` and `--git-branch` only when intentionally testing another
kernel source. `--reset-source` resets the source tree in the CLI-owned work
volume; it does not modify a host checkout.

Alternatively, download a published, checksum-verified kernel release:

```sh
lexr kernel release list
lexr kernel release download <release-tag> \
  --output-dir build/lexr/kernel-bundle
lexr kernel inspect build/lexr/kernel-bundle
```

See [Build a Patched qcom-x1e Kernel](docs/how-to/how-to-build-patched-qcom-x1e-kernel.md)
and [Prepare Kernel Release Artefacts](docs/how-to/how-to-release-kernel-artifacts.md)
for the detailed build and release paths.

### 3. Create the live image

Use a local upstream image and record its independently obtained SHA-256 when
possible:

```sh
lexr image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-dir build/lexr/kernel-bundle \
  --output build/lexr/lexr-ubuntu-sp11.iso
```

Omit `--source` to let the catalogue download the pinned source, or replace
`--kernel-dir` with `--kernel-release <release-tag>`. Add `--dry-run` to review
the plan without remastering.

To carry the companion CLI, maintained source and an eligible offline IPTSD
release on the medium:

```sh
lexr image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-release <release-tag> \
  --companion-source-dir cli/lexr \
  --companion-userspace iptsd \
  --output build/lexr/lexr-ubuntu-sp11.iso
```

The image contains one logical inventory. Its on-media copy is
`/sp11/linux-armer-manifest.json`, and the generated ISO has the matching
sidecar representation. `companion_bundle` is an attribute of that existing
ISO manifest, including when no companion is requested. It is never a separate
companion manifest. Portable userspace receipts verify their own component
files but do not create another ISO inventory.

### 4. Validate and write the USB

```sh
lexr image validate build/lexr/lexr-ubuntu-sp11.iso
lexr image devices
lexr image write build/lexr/lexr-ubuntu-sp11.iso \
  --device <whole-device> \
  --dry-run

sudo lexr image write build/lexr/lexr-ubuntu-sp11.iso \
  --device <whole-device> \
  --confirm '<exact phrase from the current dry run>'
```

Review the current dry run, then use its exact device-bound confirmation in the
privileged command. The CLI never elevates itself. The writer rejects unsafe
targets and succeeds only after a full SHA-256 read-back and safe ejection.

### 5. Install while retaining a fallback

Keep the running, known-good ABI installed. Inspect the downloaded bundle,
then preflight the target before changing it:

```sh
lexr kernel inspect kernel-bundle
lexr kernel preflight kernel-bundle \
  --root / \
  --fallback-abi <known-good-abi>
lexr kernel install kernel-bundle \
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
lexr userspace catalog validate
lexr userspace list
lexr userspace status
lexr userspace pull recommended --cache-dir build/lexr/userspace
lexr userspace install recommended \
  --from build/lexr/userspace \
  --dry-run
```

Repeat the install with elevated privileges and `--yes` after reviewing it.
IPTSD and camera components also have maintained native builds. Camera supports
a non-mutating plan; the IPTSD build executes when invoked:

```sh
lexr userspace build iptsd \
  --output-dir build/lexr/iptsd
lexr userspace build camera \
  --output-dir build/lexr/camera \
  --dry-run
```

Audio, pen and camera have different support grades. Inspect
`userspace show <component>` before changing a system.

### 7. Diagnose the host and device

```sh
lexr doctor
lexr doctor userspace
lexr doctor hardware wifi bluetooth audio
```

Use `--root <absolute-path>` with the userspace or hardware doctor to inspect a
mounted target. Diagnostic commands do not change the system. Review their
output before sharing it because host diagnostics can include environment
paths; device diagnostics deliberately omit private device identities.

### 8. Import private Windows material

Some device-bound platform firmware and the Bluetooth public address must come
from the same Surface. On Windows, run the canonical collector from this
checkout's initialised Lexr submodule:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\cli\lexr\tools\collect-sp11-windows-handoff.ps1 `
  -OutputDirectory E:\sp11-handoff
```

The collector never exports Windows Wi-Fi firmware. Treat its output as
private, device-bound and proprietary; do not publish it or add it to an image
or release. Move it privately to Linux, then validate and import it:

```sh
HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
lexr handoff import /path/to/sp11-handoff --store "$HANDOFF_STORE"
lexr handoff list --store "$HANDOFF_STORE"
lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature firmware \
  --feature bluetooth \
  --adsp-policy enabled \
  --dry-run

sudo lexr handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --feature firmware \
  --feature bluetooth \
  --adsp-policy enabled \
  --confirm '<exact phrase from the current dry run>'
```

The unprivileged shell expands `$HOME`, so `HANDOFF_STORE` remains the same
absolute user-store path when it is passed through `sudo`.

Use `--adsp-policy disabled` for a live USB target and `enabled` for the
installed NVMe system. `handoff restore` runs with `sudo` and reads its receipt
beneath the target rather than the hand-off store. `handoff purge` must receive
`--store "$HANDOFF_STORE"` when removing a reviewed private import.

### 9. Detect and recover from recognised legacy changes

Never remove old workarounds by guessing paths. Build an exact plan from the
CLI's bounded allow-list:

```sh
lexr clean scan --root /
lexr clean plan --root / \
  --output lexr-cleanup-plan.json
sudo lexr clean apply --root / \
  --plan lexr-cleanup-plan.json \
  --yes
```

Keep the durable receipt. If needed, validate and restore the captured entries:

```sh
sudo lexr clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --yes
```

## Current guidance

- [Lexr.sh CLI reference, source and safety model](https://github.com/ooaklee/lexr.sh)
- [Lexr.sh supported image catalogue](https://github.com/ooaklee/lexr.sh/blob/main/supported-isos.json)
- [Lexr.sh releases](https://github.com/ooaklee/lexr.sh/releases)
- [How-to guides](docs/how-to/)
- [Architecture decisions](docs/adr/)
- [Kernel release preparation](docs/how-to/how-to-release-kernel-artifacts.md)
- [Kernel recovery from USB](docs/how-to/how-to-reinstall-patched-kernel-from-usb.md)

Documents and reports with explicit historical dates remain evidence of the
experiments they describe. Use the standalone Lexr.sh guidance for current CLI
behaviour and this README and the current OE how-to guides for integration
actions.
