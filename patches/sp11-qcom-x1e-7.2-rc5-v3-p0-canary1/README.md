# Surface Pro 11 v3 Phase 0 recovery canary

This directory contains one packaging-only patch for the Phase 0 recovery
proof. It gives the already patched v3 kernel a distinct co-installable ABI:

```text
7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e
```

Apply it last, after the exact baseline and v3 patch directories:

```text
patches/jglathe-qcom-x1e-7.2-rc5
patches/sp11-qcom-x1e-7.2-rc5-v3
patches/sp11-qcom-x1e-7.2-rc5-v3-p0-canary1
```

The expected source is Johan G.'s tag
`jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`, commit
`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`.

The patch changes only the Debian changelog version/description and
`CONFIG_VERSION_SIGNATURE`. It does not change kernel code, configuration
choices, device-tree hardware data, or the v3 feature patches. This makes it a
bounded test of package co-installation, embedded-DTB packaging, exact-ABI
touchscreen-module installation, GRUB `next_entry`, and automatic return to
the persistent fallback.

This ABI is not a public release candidate and is not for upstream submission.
Install it only after the known-good v3 fallback, recovery media, and ADR0053
preflight have been verified. Queue it for one boot only; never make it the
persistent default.
