# Surface Pro 11 qcom-x1e 7.2-rc5 v2 patches

This patch set promotes the device-validated 2.4 MHz Denali DMIC clock to the
Surface Pro 11 7.2-rc5 build and gives the result the distinct Debian version
`7.2-rc5-jg-0sp11v2`.

The immutable upstream `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` tag sets
`qcom,dmic-sample-rate` to 4.8 MHz, which reintroduces the continuous broadband
microphone static previously eliminated on the 7.1.3 v2 kernel. These patches
restore the validated 2.4 MHz clock while keeping the original 7.2-rc5-jg-0
packages immutable and co-installable for rollback.

Apply it after `patches/jglathe-qcom-x1e-7.2-rc5` so the annotations
compatibility fix is established before the Surface Pro 11 version signature
is updated:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

The output is a matching four-package set:

- `linux-image-7.2-rc5-jg-0sp11v2-qcom-x1e`
- `linux-modules-7.2-rc5-jg-0sp11v2-qcom-x1e`
- `linux-headers-7.2-rc5-jg-0sp11v2-qcom-x1e`
- `linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v2`

Device testing found that 2.4 MHz eliminated the continuous microphone
feedback/static and made recorded speech dramatically clearer. See
[ADR-0046](https://github.com/ooaklee/linux-surface-pro-11-oe/blob/main/docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md).
