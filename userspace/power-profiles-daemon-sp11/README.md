# SP11 native platform-profile userspace

This directory extends pinned upstream `power-profiles-daemon` 0.30 to consume
the kernel's native per-handler platform-profile class on device-tree systems.
It replaces the SP11-specific need for a synthetic
`/sys/firmware/acpi/platform_profile` compatibility interface; it does not
remove or override the genuine ACPI interface on ACPI systems.

The daemon continues to prefer the upstream legacy files when both are
present. When those files are absent, it accepts exactly one complete
`/sys/class/platform-profile/platform-profile-*` device with `profile` and
`choices` attributes. More than one class device is deliberately rejected
rather than choosing an incomplete machine-wide policy arbitrarily.

`BASE.txt` pins the upstream source and the first 7.2.2 SP11 ABI that contains
the required class interface. The interface commit is in the history of the
PR25 `sp11v1` build and is byte-equivalent to the current target branch's
framework implementation. The daemon remains able to use a real legacy ACPI
interface, but the supported DT-only SP11 pairing is
`7.2.2-jg-0sp11v1-qcom-x1e` or newer on the 7.2.2 patch line.

## OpenEmbedded build

The `meta-sp11` append applies the patch to the upstream
`power-profiles-daemon_0.30.bb` recipe from `meta-openembedded/meta-oe`. Add the
layer and include `power-profiles-daemon` in the image as normal. The append
assigns package revision suffix `.sp11.1`, so package feeds can distinguish
and upgrade from an unmodified 0.30 build. It also installs the non-executable
`SP11-NATIVE-CLASS` identity record used by
Lexr to distinguish this integration from the unmodified distribution daemon.
The marker is evidence of package contents, not evidence that the live kernel
has instantiated the class device. The append
does not fabricate a kernel package dependency: OpenEmbedded kernel package
names vary by image, and blocking package installation before the matching
kernel has booted would make upgrades harder to recover. Compatibility is
enforced by the image/release pairing and reported by Lexr against installed
kernel ABIs. On the 7.2.2 patch line, the exact-pair gate begins at
`7.2.2-jg-0sp11v1-qcom-x1e`; later `sp11vN` generations remain compatible.

## Validation

The patch was compiled as ARM64 against the 0.30 tag in an Ubuntu 26.04
container. Its two new upstream-style integration tests passed:

- one class device binds the `platform_profile` driver and switches
  `balanced` to `low-power`;
- two class devices are rejected as ambiguous and retain the placeholder.

For validation on the Ubuntu installation, the same patch is also built over
the checksum-pinned `power-profiles-daemon` 0.30-2 source as
`0.30-2+sp11.1`. That package installs the same `SP11-NATIVE-CLASS` identity
record as the OE recipe. It is a local qualification artifact, not a committed
binary or a substitute for publishing a signed package repository. The full
upstream suite currently has two unrelated Python 3.14/umockdev byte-string
comparison failures in `test_amd_pstate_upower`; 123 tests pass, six skip, and
both native-class tests pass. The final binary package is therefore built with
`DEB_BUILD_OPTIONS=nocheck` only after recording that test result.

Physical release qualification must still boot the exact kernel and userspace
pair, confirm there is exactly one class device, and exercise all profiles:

```sh
find /sys/class/platform-profile -mindepth 1 -maxdepth 1 -type l -print
powerprofilesctl list
powerprofilesctl set power-saver
powerprofilesctl set performance
powerprofilesctl set balanced
journalctl -b -u power-profiles-daemon --no-pager
```

The expected SP11 choices are `low-power`, `balanced`,
`balanced-performance`, and `performance`. Desktop exposure remains the three
standard PPD profiles; `balanced-performance` is an internal kernel choice,
not a fourth desktop profile.
The patch also accepts the kernel ABI's canonical `balanced-performance`
spelling when it observes a profile selected outside PPD; upstream 0.30 only
recognises the non-canonical underscore spelling in that read path.
