# libqmi — pinned sensor dependency

`source/` contains unmodified upstream libqmi 1.39.1 at
[`d9e8af5cae7fdf9749baf87606568d3af4d03082`](https://gitlab.freedesktop.org/mobile-broadband/libqmi/-/commit/d9e8af5cae7fdf9749baf87606568d3af4d03082).
It supplies QMI/QRTR and SSC protocol support for the adjacent libssc snapshot.
This is not a bespoke OE libqmi patch or an upstream release announcement.
[SOURCE.json](SOURCE.json) records every exported file and internal symlink.
The only normalization is to Git's regular/executable modes; source bytes and
notices are unchanged.

Build this dependency first using [the private-prefix recipe](../BUILDING.md).
Do not replace the distribution's `libqmi-glib.so.5` or mix an arbitrary system
libqmi with this qualification stack. Full collection/QRTR is enabled by the
reference recipe; optional modem/firmware-update features are not enabled.
The legacy `gobi-api/` material is retained upstream source/reference material,
not a Windows runtime dependency or an input to this Meson build.

## Licensing and credit

Retain [AUTHORS](source/AUTHORS), [COPYING](source/COPYING),
[COPYING.LIB](source/COPYING.LIB) and individual file notices. The library is
LGPL-2.1-or-later; tools and legacy/reference files have their own GPL/BSD-style
notices. Do not apply OE's top-level licence to this entire dependency.
See [the upstream README](source/README.md) for its original project guidance.

## Status

Native software builds only; no Surface deployment or physical sensor
qualification. This folder is not a Lexr-installable payload. See the
[shared Lexr boundary](../README.md#lexr-boundary) before integration.
