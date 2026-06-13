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
  debs/
  notes/
```

The image builder copies this directory as `/payload` on the USB data
partition. Use it for local firmware bundles, kernel `.deb` files, and notes
needed while testing offline.
