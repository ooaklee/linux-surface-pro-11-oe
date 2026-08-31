---
id: how-to-bring-up-pen
title: "Build and Validate Surface Pro 11 Pen Support"
# prettier-ignore
description: Build, install and validate the maintained IPTSD integration through Lexr.sh.
---

# How To: Build and Validate Surface Pro 11 Pen Support

Last reviewed: 2026-08-30

The maintained pen path uses the in-kernel device support paired with the
audited `iptsd-v1` userspace component. Keep a known-good kernel available
while qualifying a new build.

## Inspect compatibility

```sh
lexr userspace show iptsd-v1
lexr doctor userspace --feature iptsd
```

The catalogue reports the component's support grade and compatible kernel
generation. Stop if the selected kernel falls outside that contract.

## Obtain IPTSD

Download the published, checksum-verified release:

```sh
lexr userspace pull iptsd --cache-dir build/lexr/userspace
IPTSD_INPUT="<exact-directory-printed-by-userspace-pull>"
```

Or build the pinned source using the maintained container policy:

```sh
lexr userspace build iptsd \
  --output-dir build/lexr/iptsd
IPTSD_INPUT="build/lexr/iptsd/stage"
```

The IPTSD build executes when invoked; unlike the camera build it has no dry-run
mode. Its verified payload is `build/lexr/iptsd/stage` for the explicit
output above. Whichever acquisition route you choose, keep its corresponding
`IPTSD_INPUT` value for installation; a pulled release is not installed from
the native build path.

## Install

```sh
lexr userspace install iptsd \
  --from "$IPTSD_INPUT" \
  --dry-run
sudo lexr userspace install iptsd \
  --from "$IPTSD_INPUT" \
  --yes
```

For a mounted installed system, add `--root <absolute-mount-point>` to both
commands. Do not run diagnostic pen processors while IPTSD owns the device.

## Verify on the device

After rebooting into the matching kernel:

```sh
lexr doctor userspace --feature iptsd
```

Then test hover, contact, pressure, both buttons, eraser, edge accuracy,
multi-touch coexistence and suspend/resume in a drawing application. A static
doctor pass verifies files and policy; it does not claim physical pen
qualification. Those interaction tests are an intentional physical
qualification boundary and are not capabilities claimed by the CLI.

If the doctor reports a recognised legacy conflict, use `clean scan`, `clean
plan` and `clean apply` as described in the root README. Keep the clean-up
receipt so `clean restore` can reverse the exact change.
