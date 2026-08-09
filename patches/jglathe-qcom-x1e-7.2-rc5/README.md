# Johan G. qcom-x1e 7.2-rc5 build compatibility patches

These patches are for building Johan G.'s `linux_ms_dev_kit` qcom-x1e 7.2-rc5
baseline with this repository's Docker kernel builder.

The upstream tag `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` already carries
the Surface Pro 11 Wi-Fi `disable-rfkill` kernel and Denali DTB changes, and
its `debian/rules.d` already invokes the packaged
`/usr/libexec/stubble/finddtbs.py` with `/usr/share/stubble/hwids`, so no
rfkill, Denali DTB, or Stubble path rewrite is needed here.

This directory carries two compatibility changes:

- the Ubuntu `check-config` annotation update; and
- removal of the stale `debian/scripts/misc/find-dtbs.py` symlink, whose target
  was an absolute developer-workstation path. The active package rules use the
  `finddtbs.py` installed by the Ubuntu `stubble` package instead. Its patch is
  intentionally an irreversible binary deletion, so it does not republish the
  stale target bytes as reverse-patch data.

## Build environment

The Docker image family is Ubuntu 26.04; the reproducible baseline pins its OCI
index digest in `config/kernel-baselines/7.2-rc5-jg-0.env`. The kernel's
`debian/rules.d` hardcodes
`gcc-15`, which only `ubuntu:26.04` provides.

## Regenerating the annotations patch

If a future immutable 7.2-rc5 tag fails `check-config` with
`N config options have been changed`, regenerate the
`0001-debian-qcom-x1e-update-annotations-for-*.patch` patch with the helper
script. If its ref does not encode the full kernel version, pass
`--version-token` and `--base-version` explicitly:

```bash
./scripts/regenerate-qcom-x1e-annotations.sh \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --version-token 7.2-rc5-jg-0 \
  --base-version 7.2-rc5 \
  --reset-source
```

The helper runs the export → `olddefconfig` → import cycle inside an
`ubuntu:26.04` container and writes the resulting patch back into this
directory as `0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch`.
Rerun the kernel build command unchanged afterwards.
