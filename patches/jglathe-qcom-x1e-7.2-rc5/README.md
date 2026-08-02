# Johan G. qcom-x1e 7.2-rc5 build compatibility patches

These patches are for building Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.2-rc5
branch with this repository's Docker kernel builder.

The upstream branch (tag `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`) already carries
the Surface Pro 11 Wi-Fi `disable-rfkill` kernel and Denali DTB changes, and
its `debian/rules.d` already uses the packaged `/usr/lib/stubble` and
`/usr/share/stubble` paths, so no rfkill, Denali DTB, or stubble-paths patches
are needed here.

This directory only carries build policy compatibility patches needed by
Ubuntu's `check-config` step, if any.

## Build environment

The Docker image is `ubuntu:26.04`. The kernel's `debian/rules.d` hardcodes
`gcc-15`, which only `ubuntu:26.04` provides.

## Regenerating the annotations patch

If a future `jg/ubuntu-qcom-x1e-7.2rc` build fails `check-config` with
`N config options have been changed`, regenerate the
`0001-debian-qcom-x1e-update-annotations-for-*.patch` patch with the helper
script. The branch name does not encode the full kernel version, so pass
`--version-token` and `--base-version` explicitly:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2rc \
  --version-token 7.2-rc5-jg-0 \
  --base-version 7.2-rc5 \
  --reset-source
```

The helper runs the export → `olddefconfig` → import cycle inside an
`ubuntu:26.04` container and writes the resulting patch back into this
directory as `0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch`.
Rerun the kernel build command unchanged afterwards.
