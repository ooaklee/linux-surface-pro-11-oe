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

### Changed

- Removed the unsafe live-USB aDSP menu entry; every live entry now retains the USB-protection blacklist while installed systems remain unaffected.

### Fixed

- Corrected Ubuntu live-media discovery so a regenerated Casper initramfs cannot be published with a stale ISO UUID marker.
