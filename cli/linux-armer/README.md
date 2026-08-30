# linux-armer

`linux-armer` prepares ARM64 installation media for the Microsoft Surface Pro 11. It combines a supported upstream image with a version-bound custom kernel bundle, matching modules, an initramfs, and the Surface Pro 11 device trees.

The first implemented image adapter targets the experimental Ubuntu Concept Resolute Desktop image. Debian, elementary OS, Fedora, and Pop!_OS entries are visible in the catalog, but remain catalog-only until their image layouts have dedicated adapters.

> [!WARNING]
> The generated media and its custom kernel are experimental. Keep another bootable recovery device available, back up important data, and disable Secure Boot before booting an unsigned custom kernel.

## What it does

- Presents a curated, strictly validated catalog from `supported-isos.json`.
- Resolves a complete kernel release from GitHub or accepts a local package directory.
- Refuses mixed kernel ABIs, missing runtime packages, and checksum mismatches.
- Remasters the Ubuntu Casper live filesystem with the selected kernel and modules.
- Generates an initramfs for that exact ABI and copies the matching X1E and X1P device trees.
- Preserves the source image's hybrid ISO/GPT boot layout and updates both ARM64 EFI boot paths.
- Validates the finished ISO before publishing it.
- Detects selected legacy Surface Pro 11 workarounds and can remove recognized files only after backing them up.

## Requirements

- Go 1.26 or newer to build from source.
- Docker with a running daemon and Linux ARM64 container support.
- At least 24 GiB of free workspace storage for an image build.
- Network access when downloading an upstream image or kernel release.

Run the CLI as a regular user. Image tooling runs in an isolated ARM64 Docker container; the CLI does not require the entire process to run as root. Cleanup against a real system root is the exception and may require elevated access for the specific apply operation.

## Build

From `cli/linux-armer`:

```sh
go build -o bin/linux-armer ./cmd/linux-armer
./bin/linux-armer doctor
```

## Command overview

Running `linux-armer` in an interactive terminal opens the Bubble Tea wizard. Every wizard choice maps to the same services used by the non-interactive commands.

```text
linux-armer wizard
linux-armer doctor

linux-armer catalog list
linux-armer catalog show <id>
linux-armer catalog validate [path]

linux-armer kernel release list
linux-armer kernel release download [ref]
linux-armer kernel inspect <directory>
linux-armer kernel build

linux-armer image create --output <iso>
linux-armer image validate <iso>

linux-armer clean scan
linux-armer clean plan
linux-armer clean apply --yes
```

Use `linux-armer <command> --help` for the complete option set. Machine-readable JSON is available where a command advertises a `--json` option.

## Create the first supported image

The shortest image command selects `ubuntu-concept-resolute-x1e` and the latest complete kernel release:

```sh
linux-armer doctor
linux-armer image create --output linux-armer-ubuntu-sp11.iso
linux-armer image validate linux-armer-ubuntu-sp11.iso
```

Use `--source` to supply an already downloaded Ubuntu Concept ISO, `--source-sha256` to require a known digest, `--kernel-dir` to use a local kernel bundle, or `--kernel-release` to select a tagged release. Cache and temporary-workspace locations can also be overridden.

The Ubuntu Concept URL is mutable. For a repeatable build, download it once, record its SHA-256 digest, and pass both the local path and digest:

```sh
# Linux
sha256sum resolute-desktop-arm64+x1e.iso

# macOS
shasum -a 256 resolute-desktop-arm64+x1e.iso

linux-armer image create \
  --source resolute-desktop-arm64+x1e.iso \
  --source-sha256 <sha256> \
  --kernel-release <release-tag> \
  --output linux-armer-ubuntu-sp11.iso
```

`--dry-run` prints the deterministic operation plan without remastering an image. `--keep-workspace` retains intermediate files for troubleshooting.

### Why this is a true live-image remaster

Copying kernel packages beside an untouched installer does not change the kernel used by the live environment. The Ubuntu adapter instead unpacks the Casper filesystem, installs the custom runtime packages, rebuilds the initramfs, replaces `/casper/vmlinuz` and `/casper/initrd`, adds the paired device trees, and repacks the filesystem.

The source image is hybrid boot media: it contains ISO boot metadata and an appended GPT EFI System Partition. The adapter replays that layout and installs direct GRUB in both the ISO filesystem and appended EFI partition. Output validation checks the boot records, kernel, initramfs, module tree, device trees, manifests, and both EFI locations before the output is atomically published.

Compressed raw disk images use a different partition and boot model. Catalog entries such as Fedora's `.raw.xz` image will require a separate adapter rather than being passed through the ISO remasterer.

## Kernel bundles

A usable kernel bundle contains, at minimum:

- one `linux-image-..._arm64.deb` package;
- one matching `linux-modules-..._arm64.deb` package;
- SHA-256 coverage for every selected package; and
- the X1E OLED and X1P LCD device trees supplied by the same modules package.

The bundle records its release, repository, ABI, version, package digests, and expected device-tree paths. `linux-armer` derives the ABI and version from package filenames and rejects a bundle if required packages are absent, versions are mixed, or a local file no longer matches its recorded digest. Headers are optional for live-image creation.

`kernel build` delegates to the repository's maintained Docker-based kernel build helper. By default it builds the [`sp11/integration-7.2.x`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/tree/sp11/integration-7.2.x) branch of the custom kernel; `--git-url` and `--git-branch` select another source. `kernel release download` resolves release assets and verifies the publisher checksum manifest before writing a local bundle manifest.

```sh
linux-armer kernel build --dry-run
linux-armer kernel build \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11 \
  --git-branch sp11/integration-7.2.x
```

## Image catalog

`supported-isos.json` is intentionally hand-editable. Each entry has a stable ID, user-facing metadata, artifact format, HTTPS download and homepage links, support status, adapter, mutability flag, compatibility notes, and verification date. An optional catalog checksum can use SHA-256 or SHA-512. Image creation currently consumes SHA-256 source digests; use `--source-sha256` when a build must enforce a digest that is not supplied by an implemented catalog entry.

Validate edits before committing them:

```sh
linux-armer catalog validate supported-isos.json
go test ./internal/catalog/...
```

Validation is strict and unknown fields are rejected. Semantic problems—including duplicate or malformed IDs, unsupported architectures or formats, insecure URLs, filename/format disagreement, invalid adapter/support combinations, malformed checksums, and invalid dates—are reported together. Both `arm64` and `aarch64` input spellings normalize to `arm64`.

To add discoverable media before an adapter exists, use:

```json
{
  "id": "distribution-release-arm64",
  "name": "Distribution Release ARM64",
  "distribution": "Distribution",
  "release": "Release",
  "architecture": "arm64",
  "artifact_kind": "iso",
  "url": "https://example.org/distribution-arm64.iso",
  "homepage": "https://example.org/downloads/",
  "adapter": "none",
  "support_level": "catalog-only",
  "experimental": true,
  "mutable": false,
  "compatibility_notes": [
    "No linux-armer image adapter is implemented yet."
  ],
  "last_verified": "2026-08-30"
}
```

Mark an entry `implemented` only when its named adapter can create and validate that artifact format.

## Reversible cleanup

Cleanup is deliberately separate from image creation. Start with a read-only scan or plan:

```sh
linux-armer clean scan
linux-armer clean plan
```

The scanner considers only a fixed set of known legacy paths. Content markers must match before a regular file is considered recognized; unusual files are left for manual review. Applying a plan requires `--yes`, copies recognized entries into a timestamped backup below `/var/lib/linux-armer/backups`, writes a receipt, and only then removes the originals.

Review the plan and backup location before applying cleanup. A future kernel change can make a workaround relevant again, so removal should remain an explicit user decision.

## Architecture

The executable and Bubble Tea UI are delivery layers. Feature packages own catalog, kernel, image, doctor, and cleanup behavior; orchestration managers compose them into deterministic plans. Docker and process execution are isolated behind platform interfaces. The same operation plans and services are used by interactive and scriptable entry points.

Architecture decisions are recorded in [`docs/adr`](docs/adr/).

## Development

```sh
go fmt ./...
go vet ./...
go test ./...
go build ./cmd/linux-armer
```

Do not commit downloaded images, kernel packages, build workspaces, or generated output ISOs.
