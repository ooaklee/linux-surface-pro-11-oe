---
id: how-to-bring-up-pen
title: "Build and Validate Surface Pro 11 Pen Support"
# prettier-ignore
description: Build, install and validate the maintained IPTSD integration through linux-armer.
---

# How To: Build and Validate Surface Pro 11 Pen Support

Last reviewed: 2026-08-30

The maintained pen path uses the in-kernel device support paired with the
audited `iptsd-v1` userspace component. Keep a known-good kernel available
while qualifying a new build.

## Inspect compatibility

```sh
linux-armer userspace show iptsd-v1
linux-armer doctor userspace --feature iptsd
```

The catalogue reports the component's support grade and compatible kernel
generation. Stop if the selected kernel falls outside that contract.

## Obtain IPTSD

Download the published, checksum-verified release:

```sh
linux-armer userspace pull iptsd --cache-dir build/linux-armer/userspace
```

Or build the pinned source using the maintained container policy:

```sh
linux-armer userspace build iptsd \
  --output-dir build/linux-armer/iptsd
```

The IPTSD build executes when invoked; unlike the camera build it has no dry-run
mode. Its verified payload is `build/linux-armer/iptsd/stage` for the explicit
output above.

## Install

```sh
linux-armer userspace install iptsd \
  --from build/linux-armer/iptsd/stage \
  --dry-run
sudo linux-armer userspace install iptsd \
  --from build/linux-armer/iptsd/stage \
  --yes
```

For a mounted installed system, add `--root <absolute-mount-point>` to both
commands. Do not run diagnostic pen processors while IPTSD owns the device.

## Verify on the device

After rebooting into the matching kernel:

```sh
linux-armer doctor userspace --feature iptsd
```

Then test hover, contact, pressure, both buttons, eraser, edge accuracy,
multi-touch coexistence and suspend/resume in a drawing application. A static
doctor pass verifies files and policy; it does not claim physical pen
qualification.

If the doctor reports a recognised legacy conflict, use `clean scan`, `clean
plan` and `clean apply` as described in the root README. Keep the clean-up
receipt so `clean restore` can reverse the exact change.
