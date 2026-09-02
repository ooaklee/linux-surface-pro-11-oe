# meta-sp11

OpenEmbedded integration for Surface Pro 11 support components. Add this
directory and `meta-openembedded/meta-oe` to `BBLAYERS`, then include the
required components in the target image. The `iptsd-sp11` recipe builds pinned
upstream iptsd and installs device-matched pen-only presets, a guarded udev
rule, a dynamic systemd service, and suspend/resume handling. The
`power-profiles-daemon_0.30.bbappend` teaches the upstream daemon to use one
native platform-profile class device on DT-only systems while preserving its
ACPI path on ACPI systems.

`iptsd-sp11` conflicts with `g6-pen`: the latter is retained only for raw HEAT
diagnostics and deterministic replay, and the two consumers must not run
together. The layer targets the post-5.0 `UNPACKDIR` layout (Styhead through
the current Wrynose 6.0 LTS).

The power-profile append is paired with SP11 kernel
`7.2.2-jg-0sp11v1-qcom-x1e` or newer on the 7.2.2 line. It deliberately does
not synthesize an ACPI sysfs hierarchy or impose an ABI-named kernel package
dependency.
