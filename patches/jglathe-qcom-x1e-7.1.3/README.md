# Archived Johan G. qcom-x1e 7.1.3 build-compatibility patches

> [!IMPORTANT]
> This directory preserves historical patch provenance. It is not part of the
> current `lexr` kernel build and contains no supported operator flow.

These patches recorded Ubuntu `check-config` compatibility work for the
`7.1.3-jg-1` source, including toolchain-dependent annotation changes. The
maintained custom kernel repository now owns its source configuration and
annotations; the OE companion neither regenerates annotations nor patches an
arbitrary legacy source during a build.

When a maintained kernel branch changes configuration, its source maintainer
must run that source package's own Debian annotation export, `olddefconfig` and
import process with the branch's declared toolchain, review the complete diff,
and commit the result in the kernel source repository. A new OE release should
then build the reviewed ref with `lexr kernel build` and retain the
native provenance record. Do not revive an OE-side annotation helper.
