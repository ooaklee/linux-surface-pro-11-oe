# Surface Pro 11 qcom-x1e 7.2-rc5 v3 patches

This patch set enables the Surface Pro 11 OLED touchscreen (Microsoft
MSHW0485) in the 7.2-rc5 build, retains the validated 2.4 MHz Denali DMIC
clock, and gives the result the distinct Debian version
`7.2-rc5-jg-0sp11v3`.

The upstream `jg/ubuntu-qcom-x1e-7.2rc` branch sets `qcom,dmic-sample-rate`
to 4.8 MHz, which reintroduces the continuous broadband microphone static
previously eliminated on the 7.1.3 v2 kernel. These patches restore the
validated 2.4 MHz clock.

The touchscreen runs over the SE2 QSPI controller at `0xa88000` (spi10).
`hamoa.dtsi` already defines the hardware as both i2c10 and spi10 (both
disabled) plus the `qup_spi10_data_clk` / `qup_spi10_cs` pinctrl states.
The v3 DTS patch enables GPI DMA instance 1, keeps i2c10 disabled, adds the
QSPI data pins GPIO 49/50 (`qup1_se2`), and attaches the touchscreen child
with GPIO 48 reset, GPIO 51 interrupt, and GPIO 64 power. Runtime QSPI
support is provided by the paired out-of-tree `gpi`, `spi-geni-qcom`, and
`mshw0485_touch` modules from the geocausa phase 91 baseline, installed as
higher-priority `/lib/modules/<release>/updates/` overrides. Use
`scripts/build-sp11-touchscreen-modules.sh --install`; it pins the Phase 91
source, targets the exact v3 ABI, rebuilds the initramfs, and verifies that the
three overrides—not the stock SPI/GPI modules—are embedded. See ADR-0050 for
the clean-install failure retrospective.

Apply it after `patches/jglathe-qcom-x1e-7.2-rc5` so the annotations
compatibility fix is established before the Surface Pro 11 version signature
is updated:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2rc \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

The output is a matching four-package set:

- `linux-image-7.2-rc5-jg-0sp11v3-qcom-x1e`
- `linux-modules-7.2-rc5-jg-0sp11v3-qcom-x1e`
- `linux-headers-7.2-rc5-jg-0sp11v3-qcom-x1e`
- `linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3`

Device testing found that 2.4 MHz eliminated the continuous microphone
feedback/static and made recorded speech dramatically clearer. See
[ADR-0046](https://github.com/ooaklee/linux-surface-pro-11-oe/blob/main/docs/adr/adr-0046-sp11-default-2p4mhz-dmic-clock.md).
