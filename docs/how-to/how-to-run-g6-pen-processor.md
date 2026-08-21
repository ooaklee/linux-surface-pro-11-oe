# Run the Surface G6 userspace pen processor

The G6 panel does not send native pen report `0x01`.  The kernel exports exact
HEAT payloads through `/dev/g6ts-heat`; `g6-pen` bundles and processes them in
userspace, following the architecture observed on Windows.

## Safety status

The packaged `/etc/g6-pen.conf` has `hover.enabled=false`.  This is intentional:
the simultaneous P4 capture validates the coarse DFT-vector centers and
coordinate scaling across 870 outputs, but does not yet validate presence or
the fine-position solver.
With this default the service validates and counts records/cycles and creates a
typed, lifted pen device; it cannot generate false contact.  Contact, pressure,
buttons, eraser, and signed tilt remain hard-gated in code.
The P7 capture intended to exercise the barrel button, but Windows reported no
button transitions, so it does not provide a raw mapping and does not relax the
button gates.
P8 validates Windows' typed eraser hover/contact semantics, but not the
upstream HEAT tool mapping; eraser/tool synthesis therefore remains gated too.

## OpenEmbedded install

Add `meta-sp11` to `BBLAYERS`, add `g6-pen` to the image, and build normally.
The recipe installs and enables `g6-pen.service`.  The service retries until
both `/dev/g6ts-heat` and `/dev/uinput` are available.

For a source-tree diagnostic build on Linux:

```sh
cd userspace/g6-pen
make check
sudo install -m 0755 g6-pen /usr/sbin/g6-pen
sudo install -m 0644 packaging/g6-pen.conf /etc/g6-pen.conf
sudo install -m 0644 packaging/g6-pen.service /etc/systemd/system/g6-pen.service
sudo systemctl daemon-reload
sudo systemctl enable --now g6-pen.service
```

Inspect `journalctl -u g6-pen.service` for final record/cycle counters.  For a
non-injecting foreground check:

```sh
sudo systemctl stop g6-pen.service
sudo /usr/sbin/g6-pen --no-uinput --emit-json
```

Only one process can open the raw device.  See `userspace/g6-pen/README.md` for
the complete ABI, replay workflow, state machine, validation gates, and map
configuration schema.

The kernel stream includes ordered opaque `0x07` and `0x6e` sideband.  Never
publish a replay containing `0x6e` without sanitizing it: the record can carry
a device or pen identifier.  Sideband never opens or completes pen tracking.
