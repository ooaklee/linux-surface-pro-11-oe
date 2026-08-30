# Changelog

Notable changes to `linux-armer` are documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and intends to use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Feature-oriented Go CLI foundation with shared image orchestration, deterministic image plans, and execution journals.
- Strict, human-readable ARM64 installation-media catalogue schema v2 with explicit upstream filenames, versioned links, publisher checksums where available, and a dedicated validation package.
- GitHub kernel release discovery and checksum-verified bundle downloads.
- Version-bound kernel bundle validation for image, modules, ABI, version, package digests, and Surface Pro 11 device trees.
- Experimental Ubuntu Concept Casper remastering and structural output validation.
- Docker-isolated ARM64 image tooling.
- Host readiness checks plus reviewed, reversible detection and removal of selected obsolete workarounds.
- Strict clean-up plan files, crash-oriented atomic quarantine, durable prepared and completed receipts, and verified restoration without overwriting changed content.
- Bubble Tea wizard and scriptable command groups for catalogue, kernel, image, doctor, clean-up, and userspace workflows.
- Strict, human-readable userspace component catalogue with dedicated validation and action-capability checks.
- Shared, non-mutating `userspace status` and `doctor userspace` diagnostics for required, supported, experimental, diagnostic-only, and obsolete support.
- Catalogue-bound kernel compatibility, FullIO boot-argument, static AArch64 ELF dependency, package-state, and legacy-component diagnostics.
- Exact userspace release downloads that require an audited remote asset set and agreement between release digests and publisher checksums.
- Bounded source-build workflows for the pinned `iptsd` integration and experimental IMX681 libcamera package set.
- Explicit userspace installation with dry runs, re-verification, root-only mutation, and a deliberate recommended set containing audio and `iptsd`.
- A named Linux Docker volume for remaster filesystems so device nodes, ownership, case-sensitive paths, and extended attributes survive on every supported host.
- Deterministic installed-system hand-off with exact dpkg registration, a non-Casper initramfs, paired versioned device trees, explicit X1E/X1P GRUB entries, and bounded kernel lifecycle hooks.
- Repository-wide documentation quality gates covering all Go declarations, including tests, and British-English comments and public prose.
- Cross-platform GoReleaser configuration for Linux and macOS on AMD64 and ARM64.
- Adapter-owned live-media discovery metadata with exact Casper initramfs and ISO UUID synchronisation.
- A manifest-tracked on-media companion containing a static Linux ARM64 CLI, its corresponding source archive, validated catalogues, and optionally the redistribution-eligible IPTSD release.
- Closed-set companion validation that rehashes every extracted file and rejects absent, extra, malformed, or incorrectly permissioned payloads.
- Native local release preparation and closed-set validation for split image assets, kernel packages and source evidence, FullIO audio, and coherent camera packages.
- Native IMX681 route discovery, private packed-RAW10 capture validation, and deterministic PNG inspection rendering.
- Strict private Windows hand-off v2 collection, import, same-device application, restoration, and confirmed retention controls for platform firmware and Bluetooth evidence.
- Policy-bound original-INF provenance for every Windows firmware payload, with collector self-tests, Pester coverage, and release-archive delivery of the canonical collector.
- Protected local-NTFS Windows collection transactions with exact private ACLs, retained no-follow object identities, no-replace publication, and bounded cleanup which never traverses a reparse object.
- Physical Bluetooth controller authority which binds Windows evidence to the built-in WCN7850 radio and selects the matching Linux device-tree controller independently of its `hciN` index.
- Repository-level quality gates that keep every maintained how-to and named migration report connected to a native CLI path and require British-English public prose.

### Changed

- Removed the unsafe live-USB aDSP menu entry; every live entry now retains the USB-protection blacklist while installed systems remain unaffected.
- Advanced the image manifest to schema v3 so `companion_bundle` is always explicit without creating a second ISO inventory.
- Made verified userspace release receipts relocatable so an offline bundle remains installable after being copied to installation media.
- Retired the legacy root script directory, shell tests, helper tools, and their obsolete workflow after recording each native owner or intentional scope boundary.
- Replaced the unpublished Windows hand-off v1 shape with v2, removing an opaque adapter digest and requiring exact original-INF authority; pre-release v1 collections must be removed and recollected.
- Made `PermanentAddress` authoritative only when structured PnP ancestry reaches the exact built-in radio; optional BTHPORT evidence must corroborate that same value, and external or ambiguous Windows radios fail closed.

### Fixed

- Corrected Ubuntu live-media discovery so a regenerated Casper initramfs cannot be published with a stale ISO UUID marker.
- Restored offline installation compatibility with the immutable `sp11-iptsd-v1` archive while retaining exact operational-file identities and rejecting unreviewed documentation variants.
- Kept legacy diagnostic captures ignored after retiring their generators, and made repository-root legal documents authoritative and mandatory inside every distributable CLI archive and companion inventory.
