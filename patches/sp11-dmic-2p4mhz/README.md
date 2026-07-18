# Surface Pro 11 2.4 MHz DMIC clock patches

These patches build a Johan G. qcom-x1e 7.1.3-jg-1 kernel with the validated
2.4 MHz Surface Pro 11 DMIC clock. Device testing found that this setting
eliminated the continuous microphone static heard at 4.8 MHz without an
audible music-playback regression. ADR-0046 adopts 2.4 MHz as the default;
capture remains slightly tinny or thin.

The initial validated build uses the distinct ABI `7.1.3-jg-1dmic2p4`,
producing packages such as
`linux-image-7.1.3-jg-1dmic2p4-qcom-x1e`. It can therefore be installed
alongside the known-good `7.1.3-jg-1-qcom-x1e` kernel. Future general-purpose
builds can integrate the accepted property without retaining the experiment
suffix.

The patches must be applied after the JG 7.1.3 build-compatibility patches so
the test-build annotations signature replaces the regenerated jg-1 signature:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.3-jg-1 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.1.3 patches/sp11-dmic-2p4mhz" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.3-dmic-2p4mhz \
  --linux-work-volume sp11-qcom-x1e-kernel-build-dmic-2p4mhz \
  --reset-source \
  --jobs 4
```

The isolated Docker volume prevents older qcom-x1e packages from being copied
into the build's artifact directory. Add `--copy-to-payload` when preparing a
new USB payload from this validated package set; omit it when only local
artifacts are required.

After installation, verify the running tree before recording audio:

```bash
uname -r
od -An -tu4 -N4 --endian=big \
  /sys/firmware/devicetree/base/soc@0/codec@6d44000/qcom,dmic-sample-rate
```

The expected values are `7.1.3-jg-1dmic2p4-qcom-x1e` and `2400000`.

For a direct local test, install all four generated packages together while
the normal 7.1.3-jg-1 kernel remains installed:

```bash
sudo apt install ./linux-qcom-x1e-headers-7.1.3-jg-1dmic2p4_*.deb \
  ./linux-headers-7.1.3-jg-1dmic2p4-qcom-x1e_*.deb \
  ./linux-modules-7.1.3-jg-1dmic2p4-qcom-x1e_*.deb \
  ./linux-image-7.1.3-jg-1dmic2p4-qcom-x1e_*.deb
```

Select the `7.1.3-jg-1dmic2p4-qcom-x1e` entry for the first boot. Keep
`7.1.3-jg-1-qcom-x1e` available in GRUB as the known-good fallback.

See [ADR-0045](../../docs/adr/adr-0045-sp11-2p4mhz-dmic-clock-test-kernel.md)
for the isolated build decision and
[ADR-0046](../../docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md) for the
device-side evidence and default-setting decision.
