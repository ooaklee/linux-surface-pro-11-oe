# Fedora IPTSD package-source contract

This directory contains the Fedora RPM metadata for the maintained Surface Pro
11 IPTSD integration. It is a reusable source input, not a standalone package
builder or image-remastering entry point. Lexr owns source-archive assembly,
template rendering, the native AArch64 RPM build, and Fedora Live integration.

`lexr-sp11-iptsd.spec.in` expects one source-complete archive named
`lexr-sp11-iptsd-source.tar.xz` with this top-level layout:

```text
lexr-sp11-iptsd-source/
|-- source/       # pinned upstream IPTSD plus every Meson fallback source
|-- integration/  # this repository's IPTSD config and lifecycle templates
|-- licenses/     # upstream and fallback dependency licence texts
`-- SOURCE.env    # exact upstream and integration source identities
```

The renderer substitutes `@IPTSD_VERSION@`, `@SOURCE_DATE_EPOCH@`, and
`@CHANGELOG_DATE@`. The archive must be assembled from the checksum-verified
IPTSD source payload described in the parent directory; prebuilt Ubuntu
binaries are not valid package sources.

The resulting Fedora package uses the native `/usr` layout, conflicts with the
generic `iptsd` package and the legacy `g6-pen` daemon, and preserves the
kernel/userspace boundary: the kernel supplies direct touch while this service
creates only the stylus device. Its post-install script reloads udev and emits
synthetic add events only for already-enumerated HIDRAW nodes below the two
maintained `001C:045E:0C80` and `001C:045E:0C83` digitizers.

Changing the spec, source-tree layout, or template placeholders requires a
complete native AArch64 RPM build and package-content inspection in Lexr. That
structural result does not replace physical pen, touch, suspend/resume, or
installation testing on Surface Pro 11 hardware.
