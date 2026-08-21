# meta-sp11

OpenEmbedded integration for Surface Pro 11 support components.  Add this
directory to `BBLAYERS`, then include `g6-pen` in the target image or install
the generated package.  The recipe enables `g6-pen.service` by default; its
configuration remains fail-closed until a validated HEAT field map is supplied.
The layer targets the post-5.0 `UNPACKDIR` layout (Styhead through the current
Wrynose 6.0 LTS).
