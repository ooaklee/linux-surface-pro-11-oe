---
id: how-to-repeat-kernel-build-for-new-release
title: "Repeat the Kernel Build for a New Release"
# prettier-ignore
description: Build, inspect and qualify a new reviewed Surface Pro 11 kernel revision through Lexr.sh.
---

# How To: Repeat the Kernel Build for a New Release

Last reviewed: 2026-08-31

Use this procedure after the maintained kernel branch or an intentionally
reviewed source branch advances. A new build is a new provenance event: never
rename an old package set or add new packages to its output directory.

## Select and review the source

Record the repository and reviewed branch or ref. Prefer a signed or otherwise
independently reviewed immutable revision for a release candidate.

```sh
lexr doctor --workspace .
lexr kernel build \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch <reviewed-ref> \
  --work-dir build/lexr/kernel-work-<generation> \
  --output-dir build/lexr/kernel-<generation> \
  --dry-run
```

The dry run reports the container policy without invoking Docker or creating a
release. Review the source change separately; the CLI does not assert that an
arbitrary ref is safe.

## Build into fresh output

Repeat the same command without `--dry-run`. Use `--jobs <count>` if the build
host needs a lower concurrency limit. If a cached source is genuinely invalid
or intentionally changing lineage, add `--reset-source`; this resets only the
CLI-owned build volume.

Do not use `--skip-clean` for a release candidate unless you can account for
every retained build product. The published bundle must come from the current
invocation.

## Inspect and prepare the release

```sh
lexr kernel inspect build/lexr/kernel-<generation>
```

The directory must be one closed, ABI-bound runtime set. Retain the exact
corresponding source closure and explicit licence inputs, then use:

```sh
lexr kernel release prepare --help
lexr kernel release validate <prepared-release-directory>
```

Follow [Prepare Kernel Release Artefacts](how-to-release-kernel-artifacts.md)
for all required preparation inputs and release-note constraints.

## Build and validate test media

The optional companion-source inclusion below requires the
[initialised Lexr submodule](../../README.md#build-the-cli). While Lexr remains
private, populating that submodule requires authenticated repository access;
once it is public, ordinary anonymous submodule initialisation is sufficient.
Omit `--companion-source-dir` when the source checkout is intentionally
unavailable.

```sh
lexr image create \
  --source <ubuntu-concept-iso> \
  --source-sha256 <sha256> \
  --kernel-dir build/lexr/kernel-<generation> \
  --companion-source-dir cli/lexr \
  --output build/lexr/lexr-<generation>.iso
lexr image validate build/lexr/lexr-<generation>.iso
lexr image devices
lexr image write build/lexr/lexr-<generation>.iso \
  --device <whole-device> \
  --dry-run

sudo lexr image write build/lexr/lexr-<generation>.iso \
  --device <whole-device> \
  --confirm '<exact phrase from the current dry run>'
```

The explicit companion source makes the matching Linux ARM64 binary and source
archive available from the live medium. Review the fresh `image devices`
inventory, then run the privileged command only after checking and copying its
exact device-bound confirmation. The CLI never elevates itself.

## Qualify and retain recovery

Keep the previous ABI installed and visible in GRUB. On the candidate kernel:

```sh
lexr doctor userspace
lexr doctor hardware wifi bluetooth audio touchscreen
```

Exercise cold boot, display, storage, networking, Bluetooth, speakers,
microphone, pen, touch, camera and suspend/resume. Record failures against the
exact source revision and ABI. Static validation proves package coherence, not
physical hardware qualification. These device exercises are an intentional
physical qualification boundary and are not capabilities claimed by the CLI.

If the new build fails, boot the retained fallback and follow
[Reinstall a Patched Kernel from USB](how-to-reinstall-patched-kernel-from-usb.md).
