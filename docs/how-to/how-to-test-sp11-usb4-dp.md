---
id: how-to-test-sp11-usb4-dp
title: "Test SP11 USB4 and DisplayPort"
# prettier-ignore
description: How to build and install the same-version Surface Pro 11 v20 USB4 increment, preserve its guarded production Stubble image, and run one top-port retimer qualification boot.
---

# How To: Test SP11 USB4 and DisplayPort

This procedure keeps the normal `7.2.0-jg-0sp11v20` boot guarded on both
PS8830 retimers and adds one explicitly selected top-port experiment. The
experiment can prove that Enter_USB reaches the retimer. It cannot supply the
missing Qualcomm host-router consumer, create a USB4 domain, or satisfy the
USB4-tunnel gate by itself.

## Safety boundary

- Keep v16 installed and bootable as the independent fallback.
- Keep the dock disconnected until the guide says to attach it.
- Use the exact CalDigit TS4 and bundled passive 0.8 m 40 Gb/s cable that
  passed the matched Windows test.
- Test only the physical top USB-C port and attach the dock once in the
  experimental cold-boot cycle.
- Do not use `--skip-clean` for this same-version build.
- Do not use `devmem`, `i2cget`, `i2cset`, `i2ctransfer`, raw MMIO, debugfs
  writes, driver rebinding, or manual power-domain toggles.
- Secure Boot must be disabled unless the locally built image is signed and
  trusted independently.

The kernel ABI and Debian version remain
`7.2.0-jg-0sp11v20-qcom-x1e` and `7.2.0-jg-0sp11v20`. Reinstalling the new
packages replaces the installed v20 files; it does not create a second v20
GRUB entry. The source manifest is therefore mandatory evidence, and v16 is
the only immediate independent fallback.

## Preserve the guarded v20 artifacts

**Qualification-run note (2026-08-30):** The operator intentionally cleared
the prior local build tree and untracked payload assets before starting this
clean rebuild. No `artifacts-672638f-guarded/` rollback archive is claimed for
this run, so skip the archive-copy commands below. The currently installed
guarded v20 remains the pre-install baseline, and installed v16 remains the
independent rollback. Reinstalling the same v20 ABI replaces the installed
guarded v20, after which v16 is the independent rollback.

For a future same-version rebuild where the prior artifacts still exist, the
build helper recreates `artifacts/`. Before starting, verify and preserve the
guarded pen/touch-integrated build at exact kernel head
`672638f963d37f55a93544568db41bfc4469df6d`.

Set `work_dir` to the build directory actually used on the machine. The
current SP11 checkout uses the first path below; the Docker example in the
README uses the second.

```bash
work_dir=build/linux-surface-pro-11-oe-usb4-support-usb4-v20
# work_dir=build/docker-sp11-qcom-x1e-kernel-usb4-v20

current="$work_dir/artifacts"
guarded="$work_dir/artifacts-672638f-guarded"
guarded_head=672638f963d37f55a93544568db41bfc4469df6d

grep -Fx "Source HEAD: $guarded_head" \
  "$current/sp11-kernel-build-manifest.txt"
(cd "$current" && sha256sum -c SHA256SUMS)

if [ -e "$guarded" ]; then
  diff -qr "$current" "$guarded"
else
  cp -a -- "$current" "$guarded"
fi

grep -Fx "Source HEAD: $guarded_head" \
  "$guarded/sp11-kernel-build-manifest.txt"
(cd "$guarded" && sha256sum -c SHA256SUMS)
```

Stop if the source head, checksums, or an existing backup comparison differs.
Do not overwrite an unexplained backup.

## Build exact v20 source

Build the pushed kernel branch from exact qualification head
`70ddec100fe953712c309067fe2db4d8207facc6`. Use the normal clean path; do not
pass `--skip-clean` with this unchanged package version.

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/integration-7.2.x-usb4-support \
  --image ubuntu:26.04 \
  --platform linux/arm64 \
  --work-dir "$work_dir" \
  --linux-work-volume sp11-qcom-x1e-kernel-usb4-v20 \
  --build-target 'binary-indep binary-qcom-x1e' \
  --reset-source --jobs 8

artifacts="$work_dir/artifacts"
grep -Fx \
  'Source HEAD: 70ddec100fe953712c309067fe2db4d8207facc6' \
  "$artifacts/sp11-kernel-build-manifest.txt"
(cd "$artifacts" && sha256sum --check --strict SHA256SUMS)
```

The Docker helper writes `SHA256SUMS` atomically after comparing the package
list manifest with the exported package set. A missing checksum manifest or a
set mismatch is an export failure, not a reason to install without the gate.
All four packages must report version `7.2.0-jg-0sp11v20`. Reject a mixed
bundle.

## Inspect the packaged Stubble images

The kernel image and DTBs are in the large `linux-modules` package, not the
small `linux-image` package. Extract that package into a temporary directory
and inspect both EFI images before installing anything.

```bash
abi=7.2.0-jg-0sp11v20-qcom-x1e
(
set -euo pipefail
modules_deb="$artifacts/linux-modules-${abi}_7.2.0-jg-0sp11v20_arm64.deb"
test -f "$modules_deb"

inspect_dir="$(mktemp -d)"
trap 'rm -rf -- "$inspect_dir"' EXIT
dpkg-deb -x "$modules_deb" "$inspect_dir"

normal="$inspect_dir/boot/vmlinuz-$abi"
experimental="$inspect_dir/usr/lib/linux-image-$abi/sp11-usb4-top-experimental.efi"
production_dtb="$inspect_dir/usr/lib/firmware/$abi/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb"
test -f "$normal"
test -f "$experimental"
test -f "$production_dtb"

# Nothing experimental may be installed into /boot automatically.
if find "$inspect_dir/boot" -maxdepth 1 -type f \
  -name '*usb4*experimental*' -print -quit | grep -q .; then
  echo 'experimental image leaked into /boot' >&2
  exit 1
fi

# The production DTB retains both retimer guards.
test "$(dtc -q -I dtb -O dts "$production_dtb" | \
  grep -c 'parade,disable-usb4')" -eq 2

# The normal Stubble image contains the ordinary model and no experiment.
strings -a "$normal" >"$inspect_dir/normal.strings"
grep -Fq 'Microsoft Surface Pro 11th Edition (OLED)' \
  "$inspect_dir/normal.strings"
if grep -Fq 'top-port USB4 retimer experiment' \
  "$inspect_dir/normal.strings"; then
  echo 'experimental DTB leaked into the normal Stubble image' >&2
  exit 1
fi

# The alternate image must contain exactly one embedded DTB.
objdump -h "$experimental" >"$inspect_dir/experimental.sections"
test "$(awk '$2 == ".dtbauto" { count++ } END { print count + 0 }' \
  "$inspect_dir/experimental.sections")" -eq 1
objcopy --dump-section \
  .dtbauto="$inspect_dir/experimental.dtb" "$experimental"
test "$(fdtget -t s "$inspect_dir/experimental.dtb" / model)" = \
  'Microsoft Surface Pro 11th Edition (OLED, top-port USB4 retimer experiment)'
test "$(dtc -q -I dtb -O dts "$inspect_dir/experimental.dtb" | \
  grep -c 'parade,disable-usb4')" -eq 1
)
```

The production DTB must have two guards. The alternate image must have one
`.dtbauto`, the explicit experimental model, and one remaining guard. Stop on
any mismatch.

## Install the same-version packages

Confirm the fallback exists before replacing v20:

```bash
fallback_abi=7.2.0-jg-0sp11v16-qcom-x1e
test -f "/boot/vmlinuz-$fallback_abi"
test -f "/boot/initrd.img-$fallback_abi"
test -d "/usr/lib/modules/$fallback_abi"
grep -F "/vmlinuz-$fallback_abi" /boot/grub/grub.cfg
```

Install all four exact artifacts explicitly:

```bash
sudo dpkg -i \
  "$artifacts/linux-headers-${abi}_7.2.0-jg-0sp11v20_arm64.deb" \
  "$artifacts/linux-image-${abi}_7.2.0-jg-0sp11v20_arm64.deb" \
  "$artifacts/linux-modules-${abi}_7.2.0-jg-0sp11v20_arm64.deb" \
  "$artifacts/linux-qcom-x1e-headers-7.2.0-jg-0sp11v20_7.2.0-jg-0sp11v20_all.deb"

test -f "/boot/vmlinuz-$abi"
test -f "/usr/lib/linux-image-$abi/sp11-usb4-top-experimental.efi"
```

The package post-install and `update-grub` steps select only the guarded
`/boot/vmlinuz-$abi` image.

## Regress the normal guarded boot

Boot the normal v20 entry once before selecting the experiment. Confirm:

```bash
uname -r
tr -d '\0' </proc/device-tree/model; echo
```

The ABI must be v20 and the model must be the ordinary OLED model, without
`top-port USB4 retimer experiment`. Quickly verify:

- normal one-, two-, and three-finger touch;
- pen inking, pressure variation, and the barrel button;
- a direct USB3 device; and
- Direct USB-C DisplayPort Alt Mode.

**Qualification result (2026-08-30):** One-, two-, and three-finger touch, pen
inking with pressure variation, the barrel button, and a direct USB3 device
passed on the clean v20 rebuild. Direct USB-C DisplayPort Alt Mode was not run
because no suitable test device or adapter was available; do not count it as a
regression pass.

### Capture the guarded attach control

Before selecting the experiment, confirm that the live production tree has two
guards:

```bash
test "$(find /sys/firmware/devicetree/base \
  -type f -name 'parade,disable-usb4' -print | wc -l)" -eq 2
```

Attach the matched TS4 once to the physical top port and wait 15 seconds. The
guarded control must reject USB4 mode and must not create a Thunderbolt device
or USB4 domain. An ordinary USB fallback function may still enumerate; record
the USB topology instead of treating that as a failure. Use only passive
evidence:

```bash
sudo journalctl -k -b --no-pager | \
  grep -E 'ps883.*USB4 disabled via DT|USB4|thunderbolt'
lsusb -t
find /sys/bus/thunderbolt/devices -mindepth 1 -maxdepth 1 -print 2>/dev/null
```

The 2026-08-30 control session observed the DT policy rejection and no dock
topology. This is the expected production safety result, not evidence of a bad
dock or cable. Disconnect all test devices and shut down completely before the
experimental boot.

## Prepare the one-boot experimental image

After package installation has completed its `update-grub`, copy the alternate
EFI image under a distinct filename:

```bash
abi=7.2.0-jg-0sp11v20-qcom-x1e
sudo install -m 0600 \
  "/usr/lib/linux-image-$abi/sp11-usb4-top-experimental.efi" \
  "/boot/vmlinuz-$abi-usb4-top-experimental"
```

Do not run `update-grub` while this temporary `/boot` copy exists. Keep the TS4
disconnected and power the machine off completely.

At the next GRUB menu, highlight the normal v20 entry and press `e`. On its
`linux` line, change only the kernel image path from:

```text
/boot/vmlinuz-7.2.0-jg-0sp11v20-qcom-x1e
```

to:

```text
/boot/vmlinuz-7.2.0-jg-0sp11v20-qcom-x1e-usb4-top-experimental
```

Some GRUB configurations omit the `/boot` prefix; preserve the existing style.
Leave the command line and `initrd` line unchanged. Do not edit or add a
`devicetree` line. Boot the transient edit with Ctrl-X.

## Verify the live experiment before attachment

With the TS4 still disconnected, require the ABI, live model, and one remaining
guard:

```bash
expected_model='Microsoft Surface Pro 11th Edition (OLED, top-port USB4 retimer experiment)'
test "$(uname -r)" = '7.2.0-jg-0sp11v20-qcom-x1e'
test "$(tr -d '\0' </proc/device-tree/model)" = "$expected_model"
test "$(find /sys/firmware/devicetree/base \
  -type f -name 'parade,disable-usb4' -print | wc -l)" -eq 1
```

If any check fails, stop and do not attach the dock.

## Collect the one-attach comparison

Capture the disconnected baseline immediately before the only attach:

```bash
./scripts/collect-sp11-usb4-diagnostics.sh \
  --out "build/usb4-diagnostics/top-baseline-$(date -u +%Y%m%dT%H%M%SZ)" \
  --port-label top --phase baseline \
  --expected-kernel-commit 70ddec100fe953712c309067fe2db4d8207facc6 \
  --expected-device-tree-model "$expected_model"
```

Connect the exact TS4 and bundled 40 Gb/s cable once to the physical top port,
wait 15 seconds, and capture the attached state:

```bash
./scripts/collect-sp11-usb4-diagnostics.sh \
  --out "build/usb4-diagnostics/top-attached-$(date -u +%Y%m%dT%H%M%SZ)" \
  --port-label top --phase attached \
  --expected-kernel-commit 70ddec100fe953712c309067fe2db4d8207facc6 \
  --expected-device-tree-model "$expected_model"

sudo journalctl -k -b --no-pager | \
  grep -E 'ps883|qmp-combo|USB4|thunderbolt'
```

The useful expected split is:

```text
ps883x: USB4 mode accepted by retimer; host-router state not established
qmp-combo: USB4/TBT mux request ignored: no active host-router PHY consumer
```

The first line means the former PS8830 device-tree rejection was bypassed and
the driver completed its USB4 configuration writes without error. It does not
prove link training or a negotiated USB4 rate. The second means that no active
host-router PHY consumer existed when the mux request arrived; it does not say
why initialization was absent or prove that one consumer is the only remaining
blocker. Charging without a USB4 domain remains a valid result for this
increment. If a domain or router appears unexpectedly, collect it passively;
do not rebind or probe registers.

**Observed on 2026-08-30:**

```text
ps883x_retimer 5-0008: USB4 mode accepted by retimer; host-router state not established
qcom-qmp-combo-phy fda000.phy: USB4/TBT mux request ignored: no active host-router PHY consumer
```

The UCSI top-port partner appeared, but USB, PCI, DRM, Thunderbolt, and USB4
domain snapshots showed no dock topology. This is a pass for the retimer-only
qualification and a negative result for link, domain, and tunnel establishment.

Disconnect the dock and power off. On the next boot, use the normal unedited
v20 entry. Then remove the temporary copy before any future `update-grub`:

```bash
abi=7.2.0-jg-0sp11v20-qcom-x1e
sudo rm -- "/boot/vmlinuz-$abi-usb4-top-experimental"
```

The packaged source remains available at
`/usr/lib/linux-image-$abi/sp11-usb4-top-experimental.efi`, so the temporary
copy is recoverable. Verify the guarded rollback:

```bash
test "$(uname -r)" = '7.2.0-jg-0sp11v20-qcom-x1e'
test "$(tr -d '\0' </proc/device-tree/model)" = \
  'Microsoft Surface Pro 11th Edition (OLED)'
test "$(find /sys/firmware/devicetree/base \
  -type f -name 'parade,disable-usb4' -print | wc -l)" -eq 2
```

The 2026-08-30 rollback passed those three checks. It did not repeat the manual
touch, pen, USB3, or direct-DisplayPort regressions after rollback.

## Interpret against the Windows oracle

The reviewed, redacted Windows result proves that this TS4, cable, and top port
can enumerate the Qualcomm host router, Microsoft root router, TS4 router,
USB3 and PCIe topology, and a DisplayPort tunnel. A private reviewed device
graph additionally maps the successful Windows path to `UBF0.PRT1` / `URS1`.
The bottom Windows run is not a valid negative comparison because `URS0` was
reserved by KDNET with `CM_PROB_USED_BY_DEBUGGER`.

The capture does not provide the host-router MMIO map, interrupts, clocks,
resets, IOMMU stream IDs, firmware/ring protocol, or decoded PS8830 sideband
sequence. Do not publish the raw Windows output; use the
[redacted result](https://github.com/ooaklee/sp11-windows-capture/blob/85161cd5c84f2d7463f74d9ff2a81fcc175ff86c/analysis/usb4-first-attach-20260829/redacted-result.md)
as the public hardware evidence.

A later kernel may pass the USB4-tunnel gate only when one matched attach
shows a Linux USB4 domain and host router, downstream router enumeration,
USB3/PCIe/DisplayPort tunnels, stable display output, detach recovery, and no
direct-DP regression. This retimer-only experiment is not that claim.
