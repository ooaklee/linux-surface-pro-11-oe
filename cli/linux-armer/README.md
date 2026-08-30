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

Run the CLI as a regular user for image creation and validation, catalogue, download, build, diagnostics, hand-off import, and every dry run whose input is readable by that user. Image tooling runs in an isolated ARM64 Docker container; the CLI does not require the entire process to run as root. Raw USB writing, kernel installation, userspace installation, hand-off application, hand-off restoration, and clean-up against a real system root require elevated access for the specific operation. A hand-off restore preview normally also needs elevation because the privileged application creates its receipt directory with private root-only permissions. The CLI never elevates itself.

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
linux-armer kernel release prepare --help
linux-armer kernel release validate <release-directory>
linux-armer kernel inspect <directory>
linux-armer kernel preflight <bundle-directory> --root <path> --fallback-abi <abi>
linux-armer kernel install <bundle-directory> --root <path> --fallback-abi <abi> --dry-run
linux-armer kernel build

linux-armer image create --output <iso>
linux-armer image validate <iso>
linux-armer image devices
linux-armer image write <iso> --device <whole-device> --dry-run
linux-armer image release prepare <iso> --dry-run
linux-armer image release validate <release-directory>

HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
linux-armer handoff import <directory> --store "$HANDOFF_STORE"
linux-armer handoff list --store "$HANDOFF_STORE"
linux-armer handoff apply <id> --store "$HANDOFF_STORE" --target-root <path> --dry-run
sudo linux-armer handoff restore <receipt-id> --target-root <path> --dry-run
linux-armer handoff purge <id> --store "$HANDOFF_STORE" --dry-run

linux-armer userspace list
linux-armer userspace show <component>
linux-armer userspace catalog validate [path]
linux-armer userspace status
linux-armer userspace pull <component|recommended>
linux-armer userspace build <iptsd|camera>
linux-armer userspace install <component|recommended> --from <directory>
linux-armer userspace audio release prepare --help
linux-armer userspace audio release validate <release-directory>
linux-armer userspace camera capture --dry-run
linux-armer userspace camera render <capture.raw> <preview.png>
linux-armer userspace camera release prepare --help
linux-armer userspace camera release validate <release-directory> --authority-sha256 <sha256>

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

The payload is stored under `/sp11/companion`. The embedded
`/sp11/linux-armer-manifest.json` and the ISO-adjacent
`*.iso.manifest.json` sidecar are byte-identical copies of the only image
inventory; their mandatory `companion_bundle` attribute records every
companion file. The deterministic
source archive includes the strict Windows hand-off collector at
`linux-armer/tools/collect-sp11-windows-handoff.ps1`; it never contains
collected device data. The portable receipt inside an IPTSD release verifies
that component's relocatable files and is itself included in the outer
inventory. It is not a second image manifest.

The repository currently declares no project-wide redistribution terms for the CLI. A locally requested companion records `project_licence: not-declared` and prints a warning. Do not redistribute that companion image until the copyright holder publishes suitable project terms and the required third-party notices.

Tag-based CLI publication is fail-closed for the same reason. The repository root is the single legal-document authority for both companion images and CLI releases. The companion builder requires the complete Git repository to be clean, inventories those root documents, and includes them in its source archive. The release job will not invoke GoReleaser unless the root contains a non-empty regular recognised project licence or copying document and a non-empty regular `THIRD_PARTY_NOTICES.md`; it then verifies the exact bytes occur once in every platform archive before publication. Neither document exists yet, so tag publication remains intentionally blocked. Supplying them requires an explicit copyright and dependency review; the CLI and workflow do not invent licensing terms.

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

The source image is hybrid boot media: it contains ISO boot metadata and an appended GPT EFI System Partition. The adapter replays that layout and installs direct GRUB in both the ISO filesystem and appended EFI partition. Ubuntu's initramfs generation creates a Casper media UUID, so the adapter writes that same value to `.disk/casper-uuid-generic` and records the discovery contract in the image manifest. Output validation checks exact UUID agreement, Casper's default boot and live-layer declarations, the boot records, kernel, initramfs, module tree, device trees, manifests, and both EFI locations before descriptor-bound no-replace publication writes the manifest and journal first, then the ISO as the final commit marker.

If publication fails, the CLI reports every recoverable transaction path and does not remove anything through a mutable pathname. Inspect the reported final and hidden staging entries before removing them; the absence of the requested ISO means the output set was not committed.

Directly written hybrid media and a nested ISO stored on an outer filesystem are different strategies. The direct ISO does not use `iso-scan/filename`; that argument belongs to the labelled outer-disk loopback workflow. All live-USB entries keep the temporary aDSP blacklist because enabling the DSP while the live root remains on USB can reset or disconnect the medium. Installed-system entries do not carry that blacklist.

The modified deployable root also registers the exact image and modules packages in dpkg, carries a separate non-Casper initramfs, seeds both model-specific device trees under `/boot`, and installs a bounded refresh helper plus explicit X1E and X1P GRUB entries. Ubuntu's default minimal layered installation is expected to deploy this root, so that path inherits the selected kernel support rather than depending on the live-only USB entry. The optional full-desktop upper layer carries its own package database and is not yet proven to preserve the same hand-off. The structural validator extracts and checks the default minimal-root assets; completing that installation, allowing the installer to run its target bootloader step, and booting the installed system on a Surface Pro 11 remain hardware gates.

The extracted live filesystem stays inside a named Linux Docker volume throughout the remaster. This preserves case-sensitive paths, root ownership, device nodes, and Linux extended attributes even when the host filesystem cannot represent them faithfully. The source and completed artefacts cross the host boundary; the mutable Linux filesystem does not.

Structural validation is a publication gate, not a substitute for booting the media on a Surface Pro 11. Disable Secure Boot before using the unsigned custom kernel, and treat an actual device boot as the final compatibility gate.

Compressed raw disk images use a different partition and boot model. Catalogue entries such as Fedora's `.raw.xz` image will require a separate adapter rather than being passed through the ISO remasterer.

### Prepare local image release assets

`image release prepare` first validates one completed linux-armer ISO, proves
that its embedded manifest bytes equal the existing adjacent
`*.iso.manifest.json`, and then produces deterministic split zstd parts,
checksums, release notes, and a path-free release manifest in a fresh local
directory. It preserves that one ISO manifest—including its
`companion_bundle` attribute—rather than introducing another image inventory.
The command never uploads files or changes a remote release.

```sh
linux-armer image release prepare linux-armer-ubuntu-sp11.iso \
  --repository-root <oe-checkout> \
  --release-name <release-name> \
  --out-dir build/release/<release-name> \
  --dry-run

linux-armer image release validate build/release/<release-name>
```

Remove `--dry-run` only after reviewing the source identity and fresh destination. Validation checks the closed release set and reconstructs the complete ISO identity from the ordered parts without publishing it.

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

`kernel build` owns a compiled ARM64 Docker build policy and does not require a repository helper script. By default it builds the [`sp11/integration-7.2.x`](https://github.com/ooaklee/linux_ms_dev_kit-sp11/tree/sp11/integration-7.2.x) branch of the custom kernel; `--git-url` and `--git-branch` select another HTTPS source and branch or tag. The policy pins the Ubuntu 26.04 ARM64 base image by digest and records the exact fetched revision and tree, its own recipe digest, and an installed-toolchain digest beside the packages. `kernel release download` resolves candidate release assets and verifies the publisher checksum manifest before writing a local bundle manifest.

`kernel release prepare` accepts only that exact closed native build output, one or more corresponding-source archives, explicit licence text, a tag-like release identity, and a fresh output path. Its dry run hashes and validates all inputs without creating a parent or output. A real run revalidates the build, copies through private staging, produces one path-free public manifest and British-English notes, checksums the complete set, validates it, and atomically publishes the new local directory. `kernel release validate` performs the same closed-directory structural checks without contacting a remote service. Neither command publishes, installs, elevates privilege, or makes a hardware-qualified claim. The retired `sp11v3` ABI and separate out-of-tree touchscreen modules are rejected because the maintained kernel carries that stack in-tree.

`kernel preflight` is the read-only installation gate. It inspects the exact Debian package metadata, rejects unexpected packages or mixed ABIs, proves that the explicitly selected fallback ABI is the running and bootable kernel, requires a fresh target ABI, and shows the bounded package, initramfs, and GRUB command sequence. The target root and fallback ABI are always explicit. `--running-abi` is accepted only when checking an alternate-root fixture; the live root always uses direct `uname` evidence.

`kernel install` repeats that preflight immediately before mutation, stages immutable package copies, retains the fallback kernel, backs up GRUB, and verifies the installed kernel image, initramfs, module tree, boot entry, and both Surface Pro 11 device trees. A real install requires effective root privilege and `--yes`; the CLI does not elevate itself, change the default kernel, remove the fallback, reboot, or install historical out-of-tree workarounds. If a mutating command or final verification fails, it attempts a bounded rollback and reports the recovery evidence in its receipt.

Review the exact transaction without privilege before installing it:

```sh
RUNNING_ABI="$(uname -r)"

linux-armer kernel preflight <kernel-bundle> \
  --root / \
  --fallback-abi "$RUNNING_ABI"

linux-armer kernel install <kernel-bundle> \
  --root / \
  --fallback-abi "$RUNNING_ABI" \
  --dry-run

sudo linux-armer kernel install <kernel-bundle> \
  --root / \
  --fallback-abi "$RUNNING_ABI" \
  --yes
```

A local bundle without an authoritative `SHA256SUMS` file is rejected unless `--allow-unverified` is supplied explicitly. That switch accepts only the locally measured package bytes; it is not publisher verification and should not be used for an unknown bundle.

The build subcommand works from a standalone released CLI as well as an OE checkout. Its private transaction and new output directory must be relative to the selected containment root; the output directory must not already exist. Source data persists in a Docker volume labelled for that exact work boundary, while generated packages cross through a private host transaction. `--reset-source` may clean only that managed volume source tree. The command builds packages but never installs them, elevates privileges, reboots, or publishes a release.

Successful output contains the coherent signed image and modules pair, optional paired headers, `SHA256SUMS`, a normal kernel bundle manifest, and a source-provenance manifest. Review the complete non-mutating plan first:

```sh
linux-armer kernel build --dry-run
linux-armer kernel build \
  --repository-root <build-root> \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11 \
  --git-branch sp11/integration-7.2.x \
  --output-dir build/linux-armer/kernel-v19
```

After materialising the exact recorded source revision and its licence text,
review and prepare a local release with unique absent output paths:

```sh
linux-armer kernel release prepare \
  --build-dir build/linux-armer/kernel-v19 \
  --output-dir build/release/sp11-qcom-x1e-v19 \
  --release-name sp11-qcom-x1e-v19 \
  --source build/linux-armer/release-source/linux-v19.tar.xz \
  --licence build/linux-armer/release-source/LICENSE.kernel.txt \
  --dry-run

linux-armer kernel release prepare \
  --build-dir build/linux-armer/kernel-v19 \
  --output-dir build/release/sp11-qcom-x1e-v19 \
  --release-name sp11-qcom-x1e-v19 \
  --source build/linux-armer/release-source/linux-v19.tar.xz \
  --licence build/linux-armer/release-source/LICENSE.kernel.txt

linux-armer kernel release validate build/release/sp11-qcom-x1e-v19
```

Preparation records the supplied source bytes; the operator remains responsible for proving that the archive corresponds to the manifest's exact revision and tree and that its licence evidence is sufficient for redistribution. See the repository's kernel release how-to for the verified source-materialisation procedure.

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

The canonical Windows collector is `tools/collect-sp11-windows-handoff.ps1` in the CLI source tree and emits one strict directory. It is also present in the companion source archive, so a user can extract that ordinary non-private script from the live medium before running it in Windows. Contract version 2 and collector `2.0.0` use a fresh random salt and a domain-separated SMBIOS UUID binding for same-device application. The raw SMBIOS UUID is never exported. A selected Bluetooth adapter instance identifier remains private in-memory collection evidence and is not exported as either raw text or a digest. Platform firmware is an all-or-absent eleven-file set with fixed destinations, copied-byte digests, and Windows DriverStore provenance; every file must come from its exact compiled original INF basename rather than a mutable `oemN.inf` alias or a filename-only match. Windows Wi-Fi firmware is deliberately excluded because Linux board firmware remains owned by the distribution firmware package.

Contract version 2 is an unpublished pre-release cut-over, not an import, application, or migration compatibility extension. The CLI never imports or applies version 1 material. An exact version 1 entry already held in the content-addressed private store remains visible as schema `1` through `handoff list` and can be removed only through the reviewed `handoff purge` transaction below. Purge each such entry before recollecting with collector `2.0.0`; do not bypass the closed-set checks with recursive deletion. A transferred version 1 source directory is not valid version 2 input and must not be reused.

### Collect on Windows

Run collection from an elevated Windows PowerShell 5.1 session. First create one new protected parent on a local fixed NTFS volume. The following locale-independent commands set the exact owner and access rules required by the collector:

```powershell
$privateParent = Join-Path $env:ProgramFiles 'linux-armer-private'
if ([System.IO.Directory]::Exists($privateParent) -or
    [System.IO.File]::Exists($privateParent)) {
    throw 'Choose a new private parent; do not reset an existing directory.'
}
[void][System.IO.Directory]::CreateDirectory($privateParent)

$administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$localSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$propagation = [System.Security.AccessControl.PropagationFlags]::None
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl

$security = New-Object System.Security.AccessControl.DirectorySecurity
$security.SetOwner($administrators)
$security.SetAccessRuleProtection($true, $false)
[void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $administrators, $fullControl, $inheritance, $propagation, $allow)))
[void]$security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $localSystem, $fullControl, $inheritance, $propagation, $allow)))
[System.IO.Directory]::SetAccessControl($privateParent, $security)
```

Use the stock `Program Files` directory as the protected parent's immediate
ancestor. Its default ACL grants unprivileged principals read and execute
access only, while the stock filesystem-root ACL grants create-directory
access on the root and makes its broader Modify entry inherit-only. Do not put
the parent beneath `ProgramData`: its stock Users rule grants write-attribute
and write-extended-attribute access to that ancestor, which the collector
deliberately rejects at this privileged boundary even when the new child has
the exact private ACL.

Choose a new child name for every collection; the requested child must not already exist. Unplug external Bluetooth radios before collecting Bluetooth evidence, then run the collector from the CLI source tree:

```powershell
$handoff = Join-Path $privateParent `
    ('sp11-handoff-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    .\tools\collect-sp11-windows-handoff.ps1 `
    -OutputDirectory $handoff
if ($LASTEXITCODE -ne 0) {
    throw 'Windows hand-off collection failed.'
}
```

The default Bluetooth source is the sole network-adapter `PermanentAddress` whose structured PnP ancestry reaches the exact built-in WCN7850 radio. Add `-UseBTHPORTRegistry` only when you also want the collector to require the sole valid local BTHPORT address to agree exactly with that independently correlated value. The built-in radio and transport identities are `QCA_SHB\UART_H4_HMT` and `ACPI\QCOM0D04`; attached or ambiguous physical radios fail closed.

The parent check walks from the filesystem root without following reparse points, requires trusted ownership, rejects access which could redirect the privileged path, and retains filesystem object identities across writes and publication. Staging receives the same private DACL. Publication is a no-replace same-parent move, and failure cleanup enumerates and removes only checked entries without recursive traversal through a reparse object.

Do not collect directly onto FAT, exFAT, a network share, or an unprotected directory. The implementation can accept a local removable NTFS parent only when the identical ACL, ancestor, and no-reparse policy passes, but collecting on fixed local NTFS and transferring only the completed child gives the clearest boundary. Copy that complete child to a new directory on trusted removable storage after the collector reports success:

```powershell
$transferRoot = 'E:\linux-armer-private-transfer'
if ([System.IO.Directory]::Exists($transferRoot) -or
    [System.IO.File]::Exists($transferRoot)) {
    throw 'Choose a new empty transfer directory.'
}
[void][System.IO.Directory]::CreateDirectory($transferRoot)
Copy-Item -LiteralPath $handoff -Destination $transferRoot -Recurse -ErrorAction Stop
```

The removable copy is private even when its filesystem cannot preserve Windows ACLs. It is a transfer copy, never the live privileged output transaction. Keep it physically controlled and remove unneeded copies after Linux import has been verified.

### Import and apply on Linux

Copy the completed hand-off directory from the private medium to the Linux system, then import it as the same unprivileged user who will manage it:

```sh
HANDOFF_STORE="${HOME}/.linux-armer-handoffs"
linux-armer handoff import <windows-handoff-directory> --store "$HANDOFF_STORE"
linux-armer handoff list --store "$HANDOFF_STORE"
```

`$HOME` is expanded by the unprivileged shell, so `HANDOFF_STORE` is the absolute path to that user's private store. Keep this same value for every import, inspection, application, and retention command; in particular, the shell expands it before `sudo`, preventing privileged application from selecting root's separate default store.

Import rejects unknown or mis-cased JSON fields, missing or extra files, symbolic links, special files, case-colliding paths, non-canonical mappings, digest or size mismatches, and source mutation during verification. It publishes the exact bytes atomically beneath a mode-`0700` content-addressed store and protects every stored file with mode `0600`. Re-importing identical bytes revalidates and reuses the existing entry. Ordinary and JSON output contain only redacted summary fields; they never contain the Bluetooth address, raw UUID, adapter identifier, salts, or their bindings.

Applying an imported hand-off is a separate, privileged transaction. The command revalidates the stored closed set, proves that the live SMBIOS identity at `--identity-root` matches the device-bound evidence, and prepares changes only beneath the mandatory `--target-root`. The default identity root is `/`; keep it when preparing another mounted root on the same Surface. Use `--feature firmware` or `--feature bluetooth` to select one included feature, or omit the repeatable flag to select every included feature. Firmware application also requires an explicit aDSP policy: `enabled` for an installed system whose root is on internal storage, or `disabled` for a live USB root.

Review the immutable plan as an unprivileged user before applying it. The dry run prints the exact ID-, policy-, target-, and current-state-bound confirmation phrase:

```sh
linux-armer handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root /target \
  --feature firmware \
  --feature bluetooth \
  --adsp-policy enabled \
  --dry-run

sudo linux-armer handoff apply <id> \
  --store "$HANDOFF_STORE" \
  --target-root /target \
  --feature firmware \
  --feature bluetooth \
  --adsp-policy enabled \
  --confirm '<exact phrase from the current dry run>'
```

For the running live system, spell the target explicitly as `--target-root /` and select `--adsp-policy disabled` when firmware is included. The transaction installs only the fixed eleven-file platform-firmware set, its Denali GPU link, the selected aDSP policy, and the private Bluetooth runtime integration represented by the imported evidence. It does not copy Windows Wi-Fi firmware, change an unselected feature, expose private values in output, or accept a confirmation generated for another plan.

Bluetooth application records the compiled selector `surface-pro-11-wcn7850-uart`, never a boot-order-dependent numeric index. At service start, the Linux helper scans `/sys/class/bluetooth/hciN/device/of_node/compatible` for the exact NUL-delimited `qcom,wcn7850-bt` token supplied by the Surface Pro 11 UART device-tree node. An external controller cannot acquire authority by appearing as `hci0`; no built-in match times out without issuing an HCI address mutation, and multiple matching candidates fail as ambiguous.

Every started mutation keeps private same-filesystem backups and a durable receipt beneath the target. A failure attempts bounded rollback but deliberately retains the receipt and backups for inspection or recovery. Restore is therefore explicit and uses its own current-state-bound confirmation:

```sh
sudo linux-armer handoff restore <receipt-id> \
  --target-root /target \
  --dry-run

sudo linux-armer handoff restore <receipt-id> \
  --target-root /target \
  --confirm '<exact phrase from the current restore dry run>'
```

Do not delete a retained receipt or its private backup directory until application, boot validation, and any necessary restoration have completed. `--json` is available for redacted automation output on both commands.

Review retention before deleting an entry from the same explicit private store:

```sh
linux-armer handoff purge <id> --store "$HANDOFF_STORE" --dry-run
linux-armer handoff purge <id> --store "$HANDOFF_STORE" --confirm 'purge <id>'
```

Purge accepts only the complete content-addressed phrase, revalidates the private closed set, atomically isolates that exact direct child, revalidates it again, and removes only the verified files and directories. This is also the sole supported removal path for an exact pre-release version 1 store entry; version 1 remains ineligible for import, migration, and application. Purging a stored entry does not remove application receipts or backups from a target root; recover or deliberately retain those records independently.

Host-independent tests do not replace maintained-hardware qualification. Successful collection on supported Windows, private transfer, same-device Linux import and application, Bluetooth address programming, firmware loading, cold boot, and restoration on the same physical Surface Pro 11 remain release gates. [ADR022](docs/adr/adr-022-privileged-windows-collection-and-controller-authority.md) records the privileged storage and controller-authority decision together with the reviewed Microsoft driver-package evidence.

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

Both userspace source-build adapters use compiled Go policy and do not invoke repository scripts. They require the complete OE checkout because the native builders authenticate their tracked component inputs; pass `--repository-root <oe-checkout>` when it cannot be detected from the current directory. Pull, status, doctor, and installation from a downloaded immutable release do not have that checkout requirement. A successful native camera build prints an independent authority SHA-256 for its final receipt. Retain it separately from the directory. Installing a native camera build or prepared local camera release repeats static Git-backed provenance proof and therefore requires both the explicit repository root and the corresponding independently retained authority digest.

Review an install before granting elevated access. A real install requires both effective root privileges and `--yes`; the CLI does not elevate itself. `--root` may select an alternate target filesystem where the component supports it.

```sh
linux-armer userspace install recommended --from <userspace-cache> --dry-run
sudo linux-armer userspace install recommended --from <userspace-cache> --yes

linux-armer userspace install camera \
  --from <native-camera-build-or-local-release> \
  --repository-root <oe-checkout> \
  --camera-authority-sha256 <matching-build-or-release-authority-sha256> \
  --dry-run
sudo linux-armer userspace install camera \
  --from <native-camera-build-or-local-release> \
  --repository-root <oe-checkout> \
  --camera-authority-sha256 <matching-build-or-release-authority-sha256> \
  --yes
```

The camera installer also retains compatibility with the downloaded, checksum-pinned camera release and does not accept the native-only repository or authority options for that input shape. Native camera input is selected only by its structured build or local-release authority; mixed authority files are rejected. Static validation never executes a supplied package member. The installer verifies every package again while privately staging the confirmed `apt-get` transaction. Installing support never invokes legacy clean-up implicitly. Use the separate `clean` commands to inspect and remove only recognised obsolete workarounds with backups and receipts.

### Prepare local userspace releases

Release commands prepare and validate closed local directories; they never create a Git tag, upload an artefact, or change a remote service. FullIO audio preparation accepts only the reviewed v19c source bytes and an explicit paired kernel tag and ABI. Camera preparation accepts only one validated native camera build, its authenticated inputs, and an explicit paired kernel tag and ABI.

```sh
linux-armer userspace audio release prepare \
  --source-root <SP11X1e-audio-checkout> \
  --repository-root <oe-checkout> \
  --tag sp11-audio-v19c \
  --kernel-tag <kernel-release-tag> \
  --kernel-abi <kernel-abi> \
  --dry-run

linux-armer userspace camera release prepare \
  --from <native-camera-build> \
  --repository-root <oe-checkout> \
  --tag <camera-release-tag> \
  --kernel-tag <kernel-release-tag> \
  --kernel-abi <kernel-abi> \
  --build-authority-sha256 <native-build-authority-sha256> \
  --dry-run
```

Remove `--dry-run` only after reviewing the complete plan. Successful camera preparation prints a release authority SHA-256; retain it separately, then pass it to `camera release validate --authority-sha256` against the newly prepared directory. The resulting manifests make provenance and kernel pairing explicit without claiming hardware qualification.

### Inspect the experimental camera

`userspace camera capture` discovers the exact supported IMX681 media route, can validate it without changing the graph, and otherwise captures complete private 3840×2640 packed-RAW10 frames behind bounded transport, content, temporal, and kernel-error gates. It does not claim that the privacy LED or a cold-boot lifecycle passed; those remain manual hardware gates.

```sh
linux-armer userspace camera capture --dry-run
linux-armer userspace camera capture --output capture.raw --frames 10
linux-armer userspace camera render capture.raw preview.png
```

Capture output and rendered previews may contain sensitive imagery. New files are private on Unix hosts; keep them out of source control, releases, issue attachments, and diagnostics unless their contents have been reviewed deliberately.

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
