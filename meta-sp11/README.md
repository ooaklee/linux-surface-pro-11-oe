# meta-sp11

OpenEmbedded integration for Surface Pro 11 support components. Add this
directory and `meta-openembedded/meta-oe` to `BBLAYERS`, then include
`iptsd-sp11` in the target image. The recipe builds pinned upstream iptsd and
installs device-matched pen-only presets, a guarded udev rule, a dynamic
systemd service, and suspend/resume handling.

`iptsd-sp11` conflicts with `g6-pen`: the latter is retained only for raw HEAT
diagnostics and deterministic replay, and the two consumers must not run
together. The layer targets the post-5.0 `UNPACKDIR` layout (Styhead through
the current Wrynose 6.0 LTS).
