# Local Payload Directory

Files in this directory are copied into the data partition of the generated
USB image. Keep proprietary files out of git.

Suggested local layout:

```text
payload/
  firmware/
    qcom/
      x1e80100/
        microsoft/
          Denali/
  kernel-debs/
    linux-*.deb
    gpi.ko                  # required with an sp11v3 touchscreen kernel
    spi-geni-qcom.ko        # exact same kernel ABI as the .deb set
    mshw0485_touch.ko
  notes/
```

The image builder copies this directory as `/payload` on the USB data
partition. Use it for local firmware bundles, kernel artifacts, and notes
needed while testing offline. Keep all three touchscreen modules beside the
matching `sp11v3` kernel packages in `payload/kernel-debs/`; the guarded kernel
installer discovers that bundle and refuses an incomplete touchscreen install.
