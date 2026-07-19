# Surface Pro 11 qcom-x1e 7.1.3 v2 patches

This patch set promotes the device-validated 2.4 MHz Denali DMIC clock to the
standard Surface Pro 11 build and gives the result the distinct Debian version
`7.1.3-jg-1sp11v2`.

Apply it after `patches/jglathe-qcom-x1e-7.1.3` so the upstream-tag build
compatibility fixes and annotations are established before the Surface Pro 11
version signature is updated:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.1.3 patches/sp11-qcom-x1e-7.1.3-v2" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.3-sp11-v2 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.1.3-sp11-v2 \
  --copy-to-payload \
  --reset-source \
  --jobs 4
```

The output is a matching four-package set:

- `linux-image-7.1.3-jg-1sp11v2-qcom-x1e`
- `linux-modules-7.1.3-jg-1sp11v2-qcom-x1e`
- `linux-headers-7.1.3-jg-1sp11v2-qcom-x1e`
- `linux-qcom-x1e-headers-7.1.3-jg-1sp11v2`

The earlier `patches/sp11-dmic-2p4mhz` directory is retained unchanged as the
reproducible source of the diagnostic `7.1.3-jg-1dmic2p4` build. See
[ADR-0046](../../docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for the
decision and device-side evidence.
