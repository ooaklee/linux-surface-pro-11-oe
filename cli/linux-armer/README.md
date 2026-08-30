# linux-armer

`linux-armer` prepares ARM64 installation media for the Microsoft Surface Pro 11 and audits the userspace support installed alongside its custom kernels. It combines a supported upstream image with a version-bound kernel bundle, matching modules, an initramfs, and the Surface Pro 11 device trees. Its userspace companion can then report missing support and manage the small set of components for which the project has an audited workflow.

The first implemented image adapter targets the experimental Ubuntu Concept Resolute Desktop image. Debian, elementary OS, Fedora, and Pop!_OS entries are visible in the catalogue, but remain `catalog-only` until their image layouts have dedicated adapters.

> [!WARNING]
> The generated media and its custom kernel are experimental. Keep another bootable recovery device available, back up important data, and disable Secure Boot before booting an unsigned custom kernel.

## What it does

- Presents a curated, strictly validated catalogue from `supported-isos.json`.
- Resolves a candidate kernel release from GitHub or accepts a local package directory, then verifies every selected package before use.
- Refuses mixed kernel ABIs, missing runtime packages, and checksum mismatches.
- Remasters the Ubuntu Casper live filesystem with the selected kernel and modules.
- Generates an initramfs for that exact ABI and copies the matching X1E and X1P device trees.
- Synchronises and validates the Casper identity shared by the generated initramfs and direct USB medium.
- Registers the exact kernel packages in the deployable Ubuntu root and supplies a non-Casper installed initramfs, paired device trees, bounded kernel hooks, and explicit installed-system GRUB entries.
- Applies `soundwire_qcom.sp11_feedback_active_offset2_zero=1` to both live and installed boot paths while keeping the USB-only `qcom_q6v5_pas` blacklist out of the installed system.
- Preserves the source image's hybrid ISO/GPT boot layout and updates both ARM64 EFI boot paths.
- Validates the finished ISO before publishing it.
- Can place a manifest-tracked Linux ARM64 companion CLI, its corresponding source and catalogues, and an eligible offline IPTSD release on the finished medium.
- Discovers whole storage devices on Linux and macOS, refuses unsafe targets, and writes a validated ISO only after an exact image-and-device-bound confirmation; success requires a complete SHA-256 read-back and safe ejection.
- Imports strictly validated, device-bound Windows evidence into a private content-addressed store and exposes only redacted summaries and exact-confirmation retention controls.
- Audits firmware, audio, pen, camera, wireless, Bluetooth, power-profile, and obsolete-workaround state without changing the installed system.
- Downloads exact, checksum-verified userspace release sets and exposes bounded build and install workflows only for explicitly supported components.
- Detects a fixed set of legacy Surface Pro 11 workarounds and can apply and reverse an exact reviewed clean-up plan with durable receipts.

## Requirements

- Go 1.26 or newer to build the CLI from source, and on the image-building host when `--companion-source-dir` is used.
- Docker with a running daemon and Linux ARM64 container support.
- At least 24 GiB of free workspace storage for an image build.
- Network access when downloading an upstream image, kernel release, or userspace release.
- `diskutil` and `plutil` on macOS, or `lsblk`, `umount`, and `udisksctl` on Linux, when discovering or writing removable media.

Run the CLI as a regular user for image creation and validation, catalogue, download, build, diagnostic, hand-off import, and dry-run commands. Image tooling runs in an isolated ARM64 Docker container; the CLI does not require the entire process to run as root. Writing a raw USB device, a userspace install, or clean-up against a real system root is the exception and requires elevated access for the specific operation.

## Build

From a complete OE checkout's `cli/linux-armer` directory:

```sh
go build -o bin/linux-armer ./cmd/linux-armer
./bin/linux-armer doctor
```

## Command overview

Running `linux-armer` in an interactive terminal opens the Bubble Tea wizard. Every wizard choice maps to the same services used by the non-interactive commands.

```text
linux-armer wizard
linux-armer doctor
linux-armer doctor userspace

linux-armer catalog list
linux-armer catalog show <id>
linux-armer catalog validate [path]

linux-armer kernel release list
linux-armer kernel release download [ref]
linux-armer kernel inspect <directory>
linux-armer kernel build

linux-armer image create --output <iso>
linux-armer image validate <iso>
linux-armer image devices
linux-armer image write <iso> --device <whole-device> --dry-run

linux-armer handoff import <directory>
linux-armer handoff list
linux-armer handoff purge <id> --dry-run

linux-armer userspace list
linux-armer userspace show <component>
linux-armer userspace catalog validate [path]
linux-armer userspace status
linux-armer userspace pull <component|recommended>
linux-armer userspace build <iptsd|camera>
linux-armer userspace install <component|recommended> --from <directory>

linux-armer clean scan
linux-armer clean plan --output linux-armer-cleanup-plan.json
linux-armer clean apply --plan linux-armer-cleanup-plan.json --yes
linux-armer clean restore /var/lib/linux-armer/backups/<transaction>/receipt.json --yes
```

Use `linux-armer <command> --help` for the complete option set. Machine-readable JSON is available where a command advertises a `--json` option.

## Create the first supported image

The shortest image command selects `ubuntu-concept-resolute-x1e` and the latest candidate kernel release. The release's packages become trusted only after their publisher checksums and measured contents pass verification:

```sh
linux-armer doctor
linux-armer image create --output linux-armer-ubuntu-sp11.iso
linux-armer image validate linux-armer-ubuntu-sp11.iso
```

Use `--source` to supply an already downloaded Ubuntu Concept ISO, `--source-sha256` to require a known digest, `--kernel-dir` to use a local kernel bundle, or `--kernel-release` to select a tagged release. Cache and temporary-workspace locations can also be overridden.

The catalogue pins Canonical's dated 2026-03-26 snapshot rather than its mutable latest-image alias. Canonical does not publish a checksum alongside that snapshot, so a reproducible trust decision still requires you to record the downloaded SHA-256 digest and pass both the local path and digest:

```sh
# Linux
sha256sum resolute-desktop-arm64+x1e-20260326.iso

# macOS
shasum -a 256 resolute-desktop-arm64+x1e-20260326.iso

linux-armer image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-release <release-tag> \
  --output linux-armer-ubuntu-sp11.iso
```

`--dry-run` prints the deterministic operation plan without remastering an image. `--keep-workspace` retains intermediate files for troubleshooting.

### Carry the offline companion

An image can carry the exact Linux ARM64 CLI, a deterministic archive of the corresponding maintained source, and validated copies of both catalogues. Add the audited IPTSD release when offline pen and touchscreen installation is useful:

```sh
linux-armer image create \
  --source resolute-desktop-arm64+x1e-20260326.iso \
  --source-sha256 <sha256> \
  --kernel-release <release-tag> \
  --companion-source-dir . \
  --companion-userspace iptsd \
  --output ../../build/linux-armer/linux-armer-ubuntu-sp11.iso
```

`--companion-source-dir` must identify a complete `linux-armer` source tree and requires a working host Go toolchain. Keep the image output, its sidecars, and any explicit `--workspace-dir` outside that source tree, as in the example. The source is snapshotted before its binary and archive are built, and a clean Git-backed tree must match the CLI's recorded commit. `--companion-userspace` is repeatable, but the initial offline allow-list accepts only `iptsd`. `recommended`, restricted audio, platform firmware, and experimental camera packages are not accepted for on-media inclusion.

The payload is stored under `/sp11/companion`. The existing `/sp11/linux-armer-manifest.json` and its sidecar remain the only image inventory; their mandatory `companion_bundle` attribute records every companion file. The deterministic source archive includes the strict Windows hand-off collector at `linux-armer/tools/collect-sp11-windows-handoff.ps1`; it never contains collected device data. The portable receipt inside an IPTSD release verifies that component's relocatable files and is itself included in the outer inventory. It is not a second image manifest.

The repository currently declares no project-wide redistribution terms for the CLI. A locally requested companion records `project_licence: not-declared` and prints a warning. Do not redistribute that companion image until the copyright holder publishes suitable project terms and the required third-party notices.

After booting the live image, copy the executable from the read-only medium to a writable executable filesystem before using it:

```sh
COMPANION_ROOT=/cdrom/sp11/companion
TOOL=/tmp/linux-armer

install -m 0755 \
  "$COMPANION_ROOT/bin/linux-arm64/linux-armer" \
  "$TOOL"

"$TOOL" version
"$TOOL" catalog validate \
  "$COMPANION_ROOT/catalogues/supported-isos.json"
"$TOOL" userspace catalog validate \
  "$COMPANION_ROOT/catalogues/supported-userspace.json"
"$TOOL" doctor userspace
```

A non-zero userspace doctor result means support is still missing; it does not by itself mean the companion is damaged. If IPTSD was included, first verify its installation plan and then apply it to the live session:

```sh
IPTSD_ROOT="$COMPANION_ROOT/userspace/iptsd-v1/sp11-iptsd-v1"

"$TOOL" userspace install iptsd --from "$IPTSD_ROOT" --dry-run
sudo "$TOOL" userspace install iptsd --from "$IPTSD_ROOT" --yes
"$TOOL" doctor userspace --feature iptsd
```

For an installed system mounted at `/target`, add `--root /target` to the install and doctor commands.

### Why this is a true live-image remaster

Copying kernel packages beside an untouched installer does not change the kernel used by the live environment. The Ubuntu adapter instead unpacks the Casper filesystem, installs the custom runtime packages, rebuilds the initramfs, replaces `/casper/vmlinuz` and `/casper/initrd`, adds the paired device trees, and repacks the filesystem.

The source image is hybrid boot media: it contains ISO boot metadata and an appended GPT EFI System Partition. The adapter replays that layout and installs direct GRUB in both the ISO filesystem and appended EFI partition. Ubuntu's initramfs generation creates a Casper media UUID, so the adapter writes that same value to `.disk/casper-uuid-generic` and records the discovery contract in the image manifest. Output validation checks exact UUID agreement, Casper's default boot and live-layer declarations, the boot records, kernel, initramfs, module tree, device trees, manifests, and both EFI locations before the output is atomically published.

Directly written hybrid media and a nested ISO stored on an outer filesystem are different strategies. The direct ISO does not use `iso-scan/filename`; that argument belongs to the labelled outer-disk loopback workflow. All live-USB entries keep the temporary aDSP blacklist because enabling the DSP while the live root remains on USB can reset or disconnect the medium. Installed-system entries do not carry that blacklist.

The modified deployable root also registers the exact image and modules packages in dpkg, carries a separate non-Casper initramfs, seeds both model-specific device trees under `/boot`, and installs a bounded refresh helper plus explicit X1E and X1P GRUB entries. Ubuntu's default minimal layered installation is expected to deploy this root, so that path inherits the selected kernel support rather than depending on the live-only USB entry. The optional full-desktop upper layer carries its own package database and is not yet proven to preserve the same hand-off. The structural validator extracts and checks the default minimal-root assets; completing that installation, allowing the installer to run its target bootloader step, and booting the installed system on a Surface Pro 11 remain hardware gates.

The extracted live filesystem stays inside a named Linux Docker volume throughout the remaster. This preserves case-sensitive paths, root ownership, device nodes, and Linux extended attributes even when the host filesystem cannot represent them faithfully. The source and completed artefacts cross the host boundary; the mutable Linux filesystem does not.

Structural validation is a publication gate, not a substitute for booting the media on a Surface Pro 11. Disable Secure Boot before using the unsigned custom kernel, and treat an actual device boot as the final compatibility gate.

Compressed raw disk images use a different partition and boot model. Catalogue entries such as Fedora's `.raw.xz` image will require a separate adapter rather than being passed through the ISO remasterer.

## Write the validated image to USB

`image devices` is read-only and lists every whole physical device with the evidence needed to review it, including whether the disk has an active non-mount consumer. It does not present an internal, non-removable, non-USB, read-only, system-backed, in-use, weakly identified, or undersized device as an acceptable target merely because its path was supplied explicitly.

```sh
linux-armer image devices
linux-armer image write linux-armer-ubuntu-sp11.iso \
  --device /dev/diskX \
  --dry-run
```

Replace `/dev/diskX` with the reviewed whole-device path shown on your host. The dry run performs structural ISO validation, hashes the complete source, inspects the target, and prints an exact confirmation phrase without unmounting or writing anything. It is safe to repeat after reconnecting the device.

Run the real operation with elevated privilege and paste the exact phrase from the current plan. The phrase includes both the whole-device path and full source SHA-256; `yes`, a shortened digest, and a phrase from a different plan are rejected.

```sh
sudo linux-armer image write linux-armer-ubuntu-sp11.iso \
  --device /dev/diskX \
  --confirm 'ERASE /dev/diskX DEVICE <opaque-fingerprint> AND WRITE SHA256 <full-sha256>'
```

An interactive terminal can omit `--confirm` and type the displayed phrase at the protected prompt. Automation must pass the exact phrase explicitly. Because the phrase contains the opaque fingerprint, a confirmation obtained for a previous USB device is rejected after another device takes over the same `/dev` path. Immediately before mutation, the manager reopens and rehashes the source, re-inspects the target, compares the already-open source descriptor with target mounts, checks privilege, unmounts only approved removable-style target filesystems, and refuses to continue if any mount, host-storage classification, active storage consumer, or identity drift remains. The production raw opener rejects links and ordinary files, proves that ordinary and raw nodes address the same kernel device, opens with `O_NOFOLLOW`, and proves that its descriptor still denotes that inspected device. The manager then writes bounded chunks, flushes them, reads back exactly the source length, verifies the SHA-256, re-inspects once more, and ejects or powers off the target. A failure returns the exact not-started, prepared, writing, written, verifying, or verified receipt state, complete byte counts, and only complete digests; it never claims that writing, verification, or ejection began before the corresponding boundary was crossed.

This writer is distribution-neutral, but the current pre-write structural validator accepts only the implemented linux-armer Ubuntu Casper output. Future Fedora, Debian, elementary OS, Pop!_OS, and raw-image adapters will retain their own image validation and live-media contracts while reusing the removable-device manager.

## Kernel bundles

A usable kernel bundle contains, at minimum:

- one `linux-image-..._arm64.deb` package;
- one matching `linux-modules-..._arm64.deb` package;
- SHA-256 coverage for every selected package; and
- the X1E OLED and X1P LCD device trees supplied by the same modules package.

The bundle records its release, repository, ABI, version, package digests, and expected device-tree paths. `linux-armer` derives the ABI and version from package filenames and rejects a bundle if required packages are absent, versions are mixed, or a local file no longer matches its recorded digest. Headers are optional for live-image creation.

`kernel build` delegates to the repository's maintained Docker-based kernel build helper. By default it builds the [`sp11/integration-7.2.x`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/tree/sp11/integration-7.2.x) branch of the custom kernel; `--git-url` and `--git-branch` select another source. `kernel release download` resolves candidate release assets and verifies the publisher checksum manifest before writing a local bundle manifest.

The build subcommand requires a complete OE checkout because its audited helper lives under `scripts/`. A standalone release archive can create images, inspect and download bundles, run diagnostics, and manage published userspace bundles, but it cannot reproduce repository-backed source builds. Run a source build from the checkout or pass its absolute location explicitly:

```sh
linux-armer kernel build --dry-run
linux-armer kernel build \
  --repository-root <oe-checkout> \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11 \
  --git-branch sp11/integration-7.2.x
```

## Image catalogue

`supported-isos.json` is intentionally hand-editable. Each entry has a stable ID, user-facing metadata, exact upstream filename, artefact format, HTTPS download and homepage links, support status, adapter, mutability flag, compatibility notes, and verification date. The filename must be a portable basename, must match the final URL path segment exactly, and must use the extension declared by `artifact_kind`. An optional catalogue checksum can use SHA-256 or SHA-512. Image creation currently consumes SHA-256 source digests; use `--source-sha256` when a build must enforce a digest that is not supplied by an implemented catalogue entry.

Validate edits before committing them:

```sh
linux-armer catalog validate supported-isos.json
go test ./internal/catalog/...
```

Validation is strict and unknown fields are rejected. Semantic problems—including duplicate or malformed IDs, unsupported architectures or formats, insecure URLs, filename/format disagreement, invalid adapter/support combinations, malformed checksums, and invalid dates—are reported together. Both `arm64` and `aarch64` input spellings normalise to `arm64`.

To add discoverable media before an adapter exists, use:

```json
{
  "id": "distribution-release-arm64",
  "name": "Distribution Release ARM64",
  "distribution": "Distribution",
  "release": "Release",
  "filename": "distribution-arm64.iso",
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

Mark an entry `implemented` only when its named adapter can create and validate that artefact format.

## Private Windows hand-offs

Some Surface Pro 11 platform firmware and the Bluetooth public controller address must come from an authorised Windows installation on the same device. They are private device data, not a userspace release and not an ISO companion. Do not add a collected hand-off directory, its manifest, or any of its payloads to an image, release, issue, diagnostic archive, or source checkout.

The canonical Windows collector is `tools/collect-sp11-windows-handoff.ps1` in the CLI source tree and emits one strict directory. It is also present in the companion source archive, so a user can extract that ordinary non-private script from the live medium before running it in Windows. The v1 contract uses a fresh random salt and domain-separated bindings for the SMBIOS UUID and selected Bluetooth adapter instance, so neither raw identifier is exported and independently collected hand-offs are not trivially linkable. Platform firmware is an all-or-absent eleven-file set with fixed destinations, copied-byte digests, and Windows DriverStore provenance. Windows Wi-Fi firmware is deliberately excluded because Linux board firmware remains owned by the distribution firmware package.

Copy the collector's output directory to the Linux system through a private medium, then import it as the same unprivileged user who will manage it:

```sh
linux-armer handoff import <windows-handoff-directory>
linux-armer handoff list
```

Import rejects unknown or mis-cased JSON fields, missing or extra files, symbolic links, special files, case-colliding paths, non-canonical mappings, digest or size mismatches, and source mutation during verification. It publishes the exact bytes atomically beneath a mode-`0700` content-addressed store and protects every stored file with mode `0600`. Re-importing identical bytes revalidates and reuses the existing entry. Ordinary and JSON output contain only redacted summary fields; they never contain the Bluetooth address, raw UUID, adapter identifier, salts, or their bindings.

The default store is `.linux-armer-handoffs` beneath the current user's home directory. Use `--store <directory>` when a different private location is required. Review retention before deleting an entry:

```sh
linux-armer handoff purge <id> --dry-run
linux-armer handoff purge <id> --confirm 'purge <id>'
```

Purge accepts only the complete content-addressed phrase, revalidates the private closed set, atomically isolates that exact direct child, revalidates it again, and removes only the verified files and directories. `handoff apply` is intentionally not available yet: importing trustworthy evidence is distinct from authorising a system mutation, and firmware and Bluetooth application require their own same-device check, transaction, rollback, and receipt before they can become supported commands.

## Userspace companion

The userspace companion helps answer a separate question from image creation: after installing a custom kernel, which supporting components are present, missing, obsolete, or outside the CLI's redistribution boundary?

`supported-userspace.json` is the human-readable source of audited component metadata. It records support maturity, capability, redistribution policy, evidence, remediation, exact release assets where applicable, and the bounded actions available through the CLI. Action flags are declarations only; the catalogue cannot supply commands or writable paths. The dedicated loader rejects unknown fields and inconsistent combinations.

Review and validate the catalogue with:

```sh
linux-armer userspace list
linux-armer userspace show firmware
linux-armer userspace catalog validate supported-userspace.json
go test ./internal/userspace/catalog/...
```

`userspace status` and `doctor userspace` use the same static inspector. They examine filesystem, package, kernel-compatibility, boot-argument, and ELF dependency state below the selected target root and do not start services, execute target binaries, contact the network, probe live devices, or modify the system. Use `--kernel` to select a Surface kernel ABI explicitly, `--feature` to limit the report, and `--json` for automation. Accepted feature names are `kernel`, `firmware`, `wifi`, `bluetooth`, `audio`, `iptsd`, `g6-pen`, `touchscreen`, `camera`, and `power`.

```sh
linux-armer doctor userspace
linux-armer userspace status --feature audio --feature iptsd
linux-armer userspace status --json
```

With no feature filter, only catalogue-required support blocks readiness. When a supported or experimental feature is selected explicitly, its failed checks also produce a failing exit status so scripts receive a useful result. Diagnostic-only and obsolete checks remain clearly labelled and never make the complete default report claim that those components are required.

An alternate or mounted target root must be trusted and quiescent while it is inspected. The doctor resolves symbolic links and confines its static reads at each check, but its report is a point-in-time diagnosis rather than a sandbox for a concurrently hostile filesystem.

### Pull, build, and install

`userspace pull` accepts one supported component or `recommended`. A pull succeeds only when the remote release contains the exact audited asset set, the checksum manifest matches its release digest, and every installable payload is covered by `SHA256SUMS` with matching release and publisher digests. Verified assets and a bundle manifest are published atomically to the local cache.

The recommended set deliberately contains the supported audio release and pinned `iptsd` integration. The camera package set is experimental and remains an explicit opt-in. Restricted platform firmware is never downloaded by `linux-armer`; acquire it from an authorised source and use the status report to verify its presence.

```sh
linux-armer userspace pull recommended
linux-armer userspace pull camera
linux-armer userspace build iptsd
linux-armer userspace build camera
```

Source builds invoke only compiled, component-specific adapters with bounded arguments. Catalogue content is never interpreted as a shell command. The current camera package build requires a native ARM64 Linux host; users on other hosts can still pull and verify the published experimental package set.

Both userspace source-build adapters require the complete OE checkout and its maintained scripts; pass `--repository-root <oe-checkout>` when it cannot be detected from the current directory. Pull, status, doctor, and verified installation workflows do not have that checkout requirement.

Review an install before granting elevated access. A real install requires both effective root privileges and `--yes`; the CLI does not elevate itself. `--root` may select an alternate target filesystem where the component supports it.

```sh
linux-armer userspace install recommended --from <userspace-cache> --dry-run
sudo linux-armer userspace install recommended --from <userspace-cache> --yes

linux-armer userspace install camera --from <verified-camera-release> --dry-run
sudo linux-armer userspace install camera --from <verified-camera-release> --yes
```

The installer verifies release contents again before mutation and uses compiled component rules for destination paths and transactions. Installing support never invokes legacy clean-up implicitly. Use the separate `clean` commands to inspect and remove only recognised obsolete workarounds with backups and receipts.

## Reversible clean-up

Clean-up is deliberately separate from image creation. Start with a read-only scan, then write the exact JSON plan you intend to apply:

```sh
linux-armer clean scan
linux-armer clean plan --output linux-armer-cleanup-plan.json
cat linux-armer-cleanup-plan.json
sudo linux-armer clean apply \
  --root / \
  --plan linux-armer-cleanup-plan.json \
  --yes
```

The scanner considers only a fixed set of known legacy paths. Required content markers must match before a regular file is considered recognised. A known service-enablement link must resolve to the exact retired unit. Other links, unusual files, changed content, and entries created after planning are left for manual review.

Applying a plan requires `--yes`. Before the first original path changes, the CLI writes and flushes a prepared recovery receipt below `/var/lib/linux-armer/backups`. Each reviewed entry is then atomically moved into a private same-filesystem quarantine, verified again, copied into its durable backup, and removed from quarantine. A completed receipt is published only after every entry succeeds. If the operation is interrupted, `receipt.pending.json` maps any original, quarantine, and backup locations.

Restore a prepared or completed transaction with the receipt path printed by `clean apply` or included in an interruption error:

```sh
sudo linux-armer clean restore \
  /var/lib/linux-armer/backups/<transaction>/receipt.json \
  --root / \
  --yes
```

Restoration verifies regular-file digests or exact symbolic-link text and refuses to overwrite locally changed content. Recovery copies remain available after a successful restore.

The allow-list currently covers selected system-wide audio routing helpers, in-tree touchscreen configuration hooks, and G6 service enablement. It does not automatically remove arbitrary out-of-tree modules, rebuild contaminated historical initramfs images, delete per-user configuration, or remove unfamiliar UCM data. Those findings require explicit manual diagnosis. A future kernel change can also make a workaround relevant again, so removal remains an operator decision.

## Architecture

The executable and Bubble Tea UI are delivery layers. Feature packages own image catalogue, kernel, image, removable media, private hand-off, userspace, doctor, and clean-up behaviour; orchestration managers compose simpler services. Docker and process execution are isolated behind platform interfaces. Interactive and scriptable image entry points share the same manager and operation plan; other commands use feature-specific dry runs, verified bundle manifests, content-addressed private stores, status reports, or recovery receipts where those records fit their workflow.

Architecture decisions are recorded in [`docs/adr`](docs/adr/).

## Development

```sh
go fmt ./...
go vet ./...
go test ./...
go build ./cmd/linux-armer
```

Do not commit downloaded images, kernel packages, build workspaces, or generated output ISOs.
