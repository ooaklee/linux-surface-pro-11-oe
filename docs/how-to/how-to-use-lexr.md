---
id: how-to-use-lexr
title: "Use Lexr from the OE Repository"
# prettier-ignore
description: How-to guide for building and using the Lexr companion CLI from the pinned OE submodule.
---

# How To: Use Lexr from the OE Repository

Use [Lexr.sh](https://github.com/ooaklee/lexr.sh) for current Surface Pro 11
image, kernel, userspace, private hand-off, diagnosis, and clean-up workflows.
The OE repository retains low-level integration evidence and pins the reviewed
Lexr source revision beneath `cli/lexr`.

> [!WARNING]
> Lexr images and kernels are experimental. Back up important data, keep a
> separate recovery device and known-good kernel, and disable Secure Boot before
> booting an unsigned custom kernel. A confirmed image write erases the selected
> whole device.

## Get the repository and pinned CLI

For a fresh checkout, initialise the Lexr submodule with the repository:

```sh
git clone --recurse-submodules \
  --branch cli/linux-armer \
  https://github.com/ooaklee/linux-surface-pro-11-oe.git
cd linux-surface-pro-11-oe
git submodule status -- cli/lexr
```

For an existing checkout:

```sh
git fetch origin cli/linux-armer
git switch cli/linux-armer
git pull --ff-only
git submodule sync -- cli/lexr
git submodule update --init --recursive cli/lexr
git submodule status -- cli/lexr
```

These examples select the integration branch explicitly while the cut-over is
under review. Omit `--branch cli/linux-armer` and the branch-switching steps
after the same changes reach the repository's default branch.

During Lexr's private phase, recursive initialisation succeeds only for GitHub
accounts which can read `ooaklee/lexr.sh`. Git uses the caller's normal GitHub
authentication; do not place a token in a clone URL, shell history, repository
file, or support report. Someone without access can clone the OE repository
without `--recurse-submodules`, but cannot build or run the pinned CLI until
access is granted or Lexr becomes public. The same recursive clone and submodule
commands work anonymously after that transition.

`git submodule update` checks out the exact revision recorded by OE. It does not
silently follow Lexr's default branch.

## Build without ambiguous provenance

Install Go 1.26 or newer, then run Lexr's source builder from the OE root:

```sh
go -C cli/lexr run ./cmd/lexr-build
LEXR=./cli/lexr/bin/lexr
"$LEXR" version
```

Use `cmd/lexr-build` instead of a bare `go build` when provenance matters. The
builder resolves the selected Lexr checkout explicitly, disables Go's ambiguous
automatic VCS stamping, and records the Lexr revision rather than the containing
OE revision. Keep `LEXR` set in the current shell for the examples below.

## Check an image-build host

Run the host checks as a regular user before downloading or remastering an
image:

```sh
mkdir -p build/lexr
"$LEXR" doctor --workspace build/lexr
```

The doctor checks the Go and Docker tooling, ARM64 container support, and
workspace capacity used by image creation. It does not start a build or change
the host. Add `--json` when a machine-readable report is required.

## Create and validate an image

The Ubuntu Concept Casper adapter is the first implemented image adapter. A dry
run prints its deterministic plan without downloading or building:

```sh
"$LEXR" image create \
  --kernel-release latest \
  --output build/lexr/lexr-sp11.iso \
  --dry-run
```

Create and independently validate the image after reviewing that plan:

```sh
"$LEXR" image create \
  --kernel-release latest \
  --output build/lexr/lexr-sp11.iso

"$LEXR" image validate build/lexr/lexr-sp11.iso
```

`latest` is convenient for evaluation. Select an exact tag shown by
`lexr kernel release list` when a repeatable build is required. Use `--source`
with `--source-sha256` for a locally retained source image whose digest must be
pinned. A local kernel bundle can be selected with `--kernel-dir`.

To carry the matching Linux ARM64 CLI, maintained source, and catalogues on the
image, add `--companion-source-dir cli/lexr`. Add
`--companion-userspace iptsd` only when the reviewed offline pen payload is
needed. The source checkout must be complete and clean, and the ISO and its
workspace must remain outside `cli/lexr`. Do not redistribute a companion image
until the Lexr repository contains the project licence and third-party notices
required by its publication gate.

## Write a reviewed USB device

List whole devices, then bind one exact image and device to a dry-run plan:

```sh
"$LEXR" image devices
"$LEXR" image write build/lexr/lexr-sp11.iso \
  --device "<whole-device>" \
  --dry-run
```

Check the device identity, capacity, transport, and image digest. Use a whole
removable USB device, never one of its partitions and never system storage. The
mutating command requires effective root and the exact phrase printed by the
current dry run:

```sh
sudo "$LEXR" image write build/lexr/lexr-sp11.iso \
  --device "<whole-device>" \
  --confirm '<exact phrase from the current dry run>'
```

Lexr re-inspects and unmounts the target, writes the image, reads back the full
source length, verifies its SHA-256 digest, and safely ejects the device. Do not
interrupt the write or reuse a confirmation after either the image or device
has changed.

## Download, preflight, and install a kernel

List the candidate releases in the established OE release channel and download
one verified bundle into a fresh directory:

```sh
"$LEXR" kernel release list
"$LEXR" kernel release download latest \
  --headers \
  --output-dir build/lexr/kernel-bundle
```

On the target Surface, preserve the currently running known-good Surface kernel
as the fallback and inspect the complete installation without mutation:

```sh
FALLBACK_ABI="$(uname -r)"

"$LEXR" kernel preflight build/lexr/kernel-bundle \
  --root / \
  --fallback-abi "$FALLBACK_ABI"

"$LEXR" kernel install build/lexr/kernel-bundle \
  --root / \
  --fallback-abi "$FALLBACK_ABI" \
  --dry-run
```

Install only after reviewing the target root, selected ABI, package set, boot
changes, and fallback:

```sh
sudo "$LEXR" kernel install build/lexr/kernel-bundle \
  --root / \
  --fallback-abi "$FALLBACK_ABI" \
  --yes
```

`preflight` and `install --dry-run` do not modify the target and do not require
root when their inputs are readable. The real install requires effective root
and `--yes`; Lexr never elevates itself. Do not use `--allow-unverified` for a
downloaded release whose authoritative checksum manifest should be present.

## Check userspace support

The catalogue and userspace checks are read-only:

```sh
"$LEXR" userspace list
"$LEXR" userspace status --root /
"$LEXR" doctor userspace --root /
```

A non-zero userspace doctor result means required support is missing; it does
not by itself mean the CLI is damaged. Use `--feature <component>` for one
focused check and `--json` for automation. For an alternate root, pass its
explicit path. If a check needs user-level state, also pass `--user-home` as the
absolute home path visible inside that target. Userspace installation is a
separate, receipt-backed mutation and requires its own dry run, effective root,
and confirmation. See the
[Lexr userspace guide](https://github.com/ooaklee/lexr.sh#userspace-companion)
for component-specific pull, build, and install commands.

## Keep Windows hand-offs private

Some platform firmware and the Bluetooth public controller address must be
collected from an authorised Windows installation on the same Surface. They are
private device data, not release assets, diagnostics, or ISO companion content.
Never add a collected hand-off, its manifest, or its payloads to Git, an issue,
a release, an image, or an ordinary support report.

The non-private collector source is
`cli/lexr/tools/collect-sp11-windows-handoff.ps1`. Follow the
[Lexr private hand-off procedure](https://github.com/ooaklee/lexr.sh#private-windows-hand-offs)
to collect into protected Windows storage and transfer it privately. Importing
copies a strictly validated version 3 hand-off into a protected,
content-addressed store beneath the current user's home; it does not modify the
target system:

```sh
HANDOFF_STORE="${HOME}/.lexr-handoffs"
"$LEXR" handoff import "<private-handoff-directory>" \
  --store "$HANDOFF_STORE"
"$LEXR" handoff list --store "$HANDOFF_STORE"
```

Application is a separate privileged boundary. For an installed NVMe system,
review the `enabled` aDSP policy with a dry run:

```sh
"$LEXR" handoff apply "<id>" \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --adsp-policy enabled \
  --dry-run

sudo "$LEXR" handoff apply "<id>" \
  --store "$HANDOFF_STORE" \
  --target-root / \
  --adsp-policy enabled \
  --confirm '<exact phrase from the current dry run>'
```

Use `--adsp-policy disabled` for a live USB target. Application revalidates the
private store, re-derives the same-device binding from the live identity root,
and retains private backups and a recovery receipt. The current CLI accepts only
version 3 store entries. Versions 1 and 2 were unpublished predecessor shapes;
use the exact binary which created such an entry to purge it before upgrading,
then recollect with the current collector. Never replace the reviewed purge
with recursive manual deletion.

## Scan and plan legacy clean-up

Scan only the compiled set of recognised obsolete workarounds, then write a
reviewable plan:

```sh
"$LEXR" clean scan --root /
"$LEXR" clean plan \
  --root / \
  --output build/lexr/lexr-cleanup-plan.json
```

Both commands leave the target unchanged; `clean plan` only creates the named
JSON plan. Unexpected files, links, or changed content remain for manual review.
Applying a plan is a separate privileged operation which requires the exact
reviewed plan and `--yes`, and publishes durable recovery receipts beneath the
target. Recreate the plan if the target changes, and do not manually delete a
workaround which Lexr declined to recognise.

## Privilege boundary summary

Run discovery, doctor, catalogue, download, image creation and validation,
kernel preflight, userspace status, hand-off import, and all dry runs as a
regular user whenever their inputs are readable. Effective root is required for
the actual USB write, kernel or userspace installation, hand-off application or
restoration, and clean-up application or restoration. A dry run is evidence for
review, not authority for a later changed target.

Use `lexr <command> --help` for the current option set. The
[Lexr repository](https://github.com/ooaklee/lexr.sh) is authoritative for CLI
source, releases, issues, and detailed command documentation; OE remains the
publication channel for the custom kernel and related hardware-support assets.
