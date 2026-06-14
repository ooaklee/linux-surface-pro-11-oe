---
id: adrs-adr026
title: "ADR026: Prebuilt Kernel Release Artifacts"
# prettier-ignore
description: Architecture Decision Record (ADR) for publishing optional prebuilt Surface Pro 11 qcom-x1e kernel packages as release artifacts instead of committing binaries to git.
---

## Context

[ADR019](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md) introduced a
patched qcom-x1e kernel build for the Surface Pro 11 Wi-Fi rfkill blocker.
[ADR020](adr-0020-dockerized-arm64-kernel-build.md) and
[ADR023](adr-0023-docker-kernel-build-case-sensitive-work-volume.md) moved the
heavy build into a Dockerized ARM64 Linux environment on a stronger host.

That workflow works, but it is slow. The first successful git-fallback kernel
build produced three installable `.deb` packages:

- `linux-headers-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb`,
- `linux-image-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb`,
- `linux-modules-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb`.

The modules package is large enough that committing it to git would violate
normal GitHub file limits and make every clone carry experimental binaries.
GitHub's large-file guidance recommends releases rather than regular git
history for distributing large binaries, and GitHub Releases allow many assets
per release with individual assets under the documented release-asset limit:

- <https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github>
- <https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>

The existing project guardrails already treat generated kernel packages as
local artifacts:

- `.gitignore` excludes `payload/kernel-debs/`, `*.deb`, and `build/`;
- `payload/kernel-debs/` is copied into USB images as local install media;
- release-like manifests are generated under `build/.../artifacts/`;
- firmware blobs and Windows driver extracts are explicitly excluded from
  redistribution unless their rights are confirmed.

Publishing prebuilt Linux kernel packages also creates source and provenance
obligations. The Linux kernel is GPL-2.0-only as a whole, and distributing
kernel binaries requires corresponding source availability. A public binary
release therefore needs more than the `.deb` files: it needs enough source,
patch, build, and checksum evidence for users to audit or rebuild the package
set.

- <https://docs.kernel.org/process/license-rules.html>
- <https://www.gnu.org/licenses/gpl-faq.html>

## Decision

The project will publish optional prebuilt qcom-x1e kernel packages as GitHub
Release assets, not as tracked git files. This supersedes ADR019's
local-artifacts-only stance only for optional public downloads; it does not
change the rule that generated `.deb` files and build trees stay out of git.

`payload/kernel-debs/` will remain a local/offline staging directory for USB
image creation. Users can populate it either by building locally or by
downloading a published release bundle and verifying its checksums.

Each prebuilt kernel bundle will be published as an experimental prerelease
until the kernel path is no longer bring-up quality. Release names and tags
will identify the device, package ABI/version, and patch purpose, for example:

```text
sp11-qcom-x1e-7.0.0-22.22-rfkill1
```

Each binary release must include, at minimum:

- the installable qcom-x1e `.deb` files;
- `SHA256SUMS` for every uploaded asset;
- a sanitized build manifest recording source mode, upstream URL, branch,
  source commit, build target, patch list, repository commit, Docker image
  family or digest when available, and build command shape;
- a package manifest listing package filenames, sizes, versions, and checksums
  without local workstation paths;
- patch checksums for `patches/ubuntu-qcom-x1e-7.0/`;
- corresponding source sufficient for the binary release, either as source
  package artifacts, a patched source archive, or immutable instructions and
  links that retrieve the exact source commit plus the project patches used;
- release notes that mark the artifacts as experimental, Surface Pro 11
  specific, unsigned, and optional.

The raw local manifests under `build/.../artifacts/` are build outputs, not
automatically public release manifests. They may contain absolute paths from
the container, host, or device that built the packages. Public release
manifests must be regenerated or sanitized before upload and should prefer
package basenames, repository-relative paths, upstream URLs, commits, and
checksums.

The project will provide a release-preparation helper that writes sanitized
assets under ignored `build/release/<release-name>/` directories. That helper
may copy local `.deb` files into the release directory, but those copies remain
ignored build output and must not be committed. Public release preparation
will refuse a dirty support repository by default so manifests do not point to
a commit that lacks the release instructions or patch state being described.
The helper will also refuse to print a publish command unless corresponding
source assets are included; source-less output is allowed only as an explicit
local draft.

Release assets should be flat and easy to inspect. A supplemental tarball that
contains the same files under `kernel-debs/` is acceptable for convenience, but
the individual `.deb`, manifest, and checksum assets remain the canonical
download surface.

The project will not commit `.deb` packages or nested package folders under
`payload/kernel-debs/`. A folder named after one `.deb`, such as
`payload/kernel-debs/linux-headers-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64/`, would
make a local staging area look like canonical public distribution and would
still not solve git-history bloat. If a directory layout is needed for release
preparation, it should live under ignored build output, for example:

```text
build/release/sp11-qcom-x1e-7.0.0-22.22-rfkill1/
```

Generated manifests must avoid private or local-only paths. Container-internal
paths are acceptable only when they explain reproducible build layout; public
manifests should prefer repository-relative paths, package basenames, upstream
URLs, commits, and checksums.

Release notes must avoid claiming bit-for-bit reproducibility unless that has
been tested. The accurate claim for the current workflow is "built from these
recorded inputs".

## Consequences

Users who trust the experimental release can avoid a multi-hour kernel build by
downloading the `.deb` assets, verifying `SHA256SUMS`, copying the packages to
`payload/kernel-debs/`, rebuilding the USB image, and installing with the
existing `--install-only` fallback guard.

GitHub Releases are not an apt repository. Users still need explicit download,
checksum, copy-to-payload, USB rebuild, and Surface-side install instructions.

The git repository remains small and source-focused. Cloning the repository
does not fetch large experimental kernel binaries.

Release assets become part of the project's public support surface. A bad or
stale release can cause boot or Wi-Fi regressions on user devices, so release
notes must clearly state the tested device, kernel ABI, DTB requirements, and
fallback-kernel expectations.

Prebuilt kernel packages are unsigned experimental packages. Users must keep a
known-good fallback qcom-x1e kernel installed, keep recovery media available,
and understand that Secure Boot may need to remain disabled for this bring-up
path.

Git LFS is intentionally not used for these packages. It would add quota and
bandwidth management, require users to understand LFS behavior, and still make
binary pointers part of normal repository history. GitHub Releases are a
better fit for optional downloads.

The first available artifacts were produced from git fallback source mode,
which is useful for bring-up but not the preferred long-term package source.
Those artifacts may be published only if they are clearly labeled as
experimental git-fallback builds. Future releases should prefer apt source
mode that matches the installed Ubuntu qcom-x1e package stream when the exact
source package is available.

No proprietary firmware, Windows driver-store extracts, service reports,
hardware identifiers, or local diagnostic archives may be included in kernel
release assets unless redistribution rights and privacy review are complete.
