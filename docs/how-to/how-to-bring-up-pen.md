---
id: how-to-bring-up-pen
title: "How To: Build and Validate the SP11 Pen Integration"
# prettier-ignore
description: Build, install, inspect, validate, and roll back the Surface Pro 11 HIDRAW and pinned iptsd pen integration without enabling duplicate touch or the legacy raw HEAT daemon.
---

# How To: Build and Validate the SP11 Pen Integration

> [!NOTE]
> For current CLI-managed image, kernel, userspace, private hand-off, diagnosis,
> and clean-up workflows, start with [Use Lexr](how-to-use-lexr.md). This page
> retains low-level, manual, or evidence procedures for bring-up and
> troubleshooting.

This procedure exercises the matching
`sp11/integration-7.2.x-pen-part-2` kernel and support branches. It is a
pre-release hardware test, not a release procedure. The integration supports
X1P/LCD `045e:0c80` and X1E/OLED `045e:0c83`; the X1E/OLED core pen path passed
on v19, while a separate X1P device run remains. Keep a known-good kernel in
GRUB while completing the eraser, recovery, and suspend/resume matrix.

## Build the paired artifacts

Build the kernel packages from the matching kernel branch after that branch is
available to the Docker builder:

```sh
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/integration-7.2.x-pen-part-2 \
  --image ubuntu:26.04 \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-pen-part-2 \
  --linux-work-volume sp11-kernel-pen-part-2 \
  --copy-to-payload --reset-source --jobs 8
```

Build the pinned ARM64 userspace payload and its corresponding source bundle:

```sh
./scripts/build-sp11-iptsd-docker.sh --copy-to-payload
```

The userspace builder verifies upstream iptsd commit
`a83bc1232f7096f8b33b50fdbda249cd640de670` and tree
`06c6e812873e117930eca60b8a32cec40fd13281`, then records binary and source
hashes in `payload/iptsd-sp11/SHA256SUMS`.

Build the USB image only after both payloads exist. The image carries the pen
installer and binaries on `SP11DATA`; it does not modify the running live
desktop.

## Install on the test system

Install and boot the matching kernel first. From the mounted `SP11DATA`
partition, install the userspace integration into the installed system:

```sh
SP11DEV="$(blkid -L SP11DATA)"
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
test -n "$SP11DATA"
cd "$SP11DATA/support"
sudo ./scripts/install-sp11-support.sh --installed-system --require-iptsd
sudo reboot
```

The installer verifies every payload hash, disables the legacy
`g6-pen.service`, masks generic `iptsd@.service`, installs pen-only presets for
both SP11 product IDs, reloads udev, and lets the matching HIDRAW node start a
dynamic `sp11-iptsd@` service. Do not hard-code `/dev/hidrawN`; numbering can
change after reset or resume.

## Inspect discovery and ownership

```sh
uname -r
lsmod | grep mshw0485_touch
grep -H . /sys/class/hidraw/hidraw*/device/uevent 2>/dev/null
systemctl list-units 'sp11-iptsd@*.service'
systemctl is-active g6-pen.service || true
journalctl -b -k | grep -E 'MSHW0485|IPTS HIDRAW|mshw0485'
journalctl -b -u 'sp11-iptsd@*.service'
```

Success requires one matching SPI HID identity (`045e:0c80` or `045e:0c83`),
one active iptsd instance bound to its current HIDRAW node, and an inactive
`g6-pen.service`. Inspect `libinput list-devices` or the compositor settings and
confirm there is one direct touchscreen plus one stylus device, not a second
iptsd touchscreen.

## Hardware validation matrix

Record the kernel commit, package version, support commit, iptsd payload
hashes, device SKU, and firmware version with every result.

- Confirm existing one-, two-, and three-finger touch and gestures before and
  while iptsd runs.
- Enter and leave hover repeatedly at the center and all four edges. Lift must
  be immediate and must not leave a stuck cursor or contact.
- Draw slow and fast continuous strokes, diagonals, circles, and edge-to-edge
  lines. Check for gaps, jumps, axis inversion, and clipping.
- Vary pressure from light contact to firm contact and confirm a monotonic
  response in an input-event inspector and a drawing application.
- Exercise positive and negative tilt in both axes.
- Test the barrel button and confirm `BTN_STYLUS` transitions.
- Record the second/top button as a known limitation: unmodified iptsd v3.1.0
  does not advertise `BTN_STYLUS2`, so it is not a pass gate for this candidate.
- Enter hover and contact with the eraser, then transition back to the pen tip.
- Restart the dynamic service ten times and verify that each old process exits
  and exactly one new process owns the current HIDRAW node.
- Trigger transport recovery where safe and check for duplicate uinput devices,
  stale pre-reset strokes, recovery loops, or kernel warnings.
- Complete at least 20 suspend/resume cycles. After each resume, verify a new
  eligible HIDRAW node, a new iptsd process, working touch, hover, and lift.
- Repeat from multiple cold boots and test both the installed-system and live
  USB preparation paths separately.

Do not report a button, eraser, tilt, pressure, or suspend capability as working
unless its transition was observed on this branch.

## Recorded X1E acceptance

On 2026-08-30, kernel `7.2.0-jg-0sp11v19-qcom-x1e` at `ec96c9da79af` and
support commit `6e7aaeee4bfc` passed the installed-system core matrix on the
X1E/OLED `045e:0c83` panel. Phase 84 used SET_FEATURE `0x05`-only
initialization and one response per level-low IRQ. The capture recorded 3,903
virtual-stylus events, pressure 0 through 3309, variation on both tilt axes,
all four DFT reports, and exact steady-state IRQ/report accounting. The barrel
button was confirmed manually after the capture. Kernel taint, panel resets,
host-fault recoveries, transport/protocol errors, and iptsd restarts stayed at
zero. Normal one-, two-, and three-finger touch was then confirmed to work as
expected. This record is X1E-only; separate X1P hardware validation, eraser,
comprehensive touch/gesture regression, forced recovery, and repeated
suspend/resume remain.

## Rollback

Stop the userspace processor without affecting direct touch:

```sh
sudo systemctl stop 'sp11-iptsd@*.service'
sudo mv /etc/udev/rules.d/70-sp11-iptsd.rules \
  /etc/udev/rules.d/70-sp11-iptsd.rules.disabled
sudo systemctl unmask iptsd@.service
sudo udevadm control --reload-rules
```

Then boot the known-good kernel from GRUB. The raw `/dev/g6ts-heat` ABI remains
available for diagnostics, but do not start `g6-pen` unless production iptsd is
stopped and the diagnostic procedure requires it.
