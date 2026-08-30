# SP11 IMX681 libcamera integration

This directory contains the three reviewed inputs used by the native
`linux-armer` camera builder:

- `BASE.txt`, the strict upstream and Ubuntu source authority;
- `0001-libipa-add-imx681-simple-ipa-support.patch`, the simple-IPA integration;
- `imx681.yaml`, the byte-identical audit copy of the installed tuning data.

The integration teaches libcamera 0.7's simple IPA about the standalone IMX681
sensor metadata, reciprocal Sony analogue-gain control and model-named tuning
data. It remains experimental and must be paired explicitly with the kernel
release being qualified.

## Recorded device evidence

The coherent package set recorded on 29 August 2026 selected
`simple/imx681.yaml`, passed same-build IPA signature verification and exposed
approximately 1x–16x analogue gain. A Firefox and Chromium WebRTC test also
created active PipeWire streams. That dated result is evidence for the tested
package and kernel only; it is not a claim that a new build, exposure control,
privacy LED, colour response or lifecycle has passed.

The standalone kernel control code uses Sony's reciprocal mapping
`gain = 1024 / (1024 - x)` for `x=0..960`.
`AnalogueGainLinear{ 0, 1024, -1, 1024 }` expresses that relationship to
libcamera. The patch records the measured 1000 nm unit cell, two-frame
exposure/gain/blanking delays and a RAW10 black pedestal of 64 (4096 on
libcamera's 16-bit scale).

The sensor model is `imx681`, so the tuning filename is `imx681.yaml`, not
`smiapp.yaml`. The patch adds that file to the simple IPA's Meson install set.
The standalone YAML beside the patch must remain byte-identical to the copy
carried by the patch.

## Deliberate limits

- Confirm the pedestal with covered-lens RAW frames on the target unit.
- No colour-correction matrix is enabled; add one only after controlled
  colour-chart measurement.
- The integration does not change the global AGC target or adjustment defaults.
- It does not add a privacy-LED daemon; V4L2 core owns the device-tree LED.
- It does not relax PipeWire service hardening.
- A static package proof is not physical camera qualification.

## Build the coherent package set

Use a native ARM64 Linux Docker server and a clean Git-backed support checkout.
The CLI authenticates all three inputs against the exact support `HEAD`, uses a
digest-qualified Ubuntu 26.04 image and never mounts the repository into the
container. Review the non-mutating plan first:

```sh
linux-armer userspace build camera \
  --repository-root . \
  --output-dir build/linux-armer/camera/packages \
  --jobs 8 \
  --dry-run
```

The dry run reports an execution blocker on a non-ARM64 Docker server. Run the
same command without `--dry-run` only on a suitable builder. Every successful
invocation publishes a fresh `build.<UTC-build-id>` child beneath the selected
output directory and prints that exact path.

The closed build directory contains five ARM64 runtime packages, the original
`.changes` and `.buildinfo` records, and
`sp11-imx681-libcamera-build.json`. The trusted native build proves the source
digests, complete `.changes` accounting, package names, version and
architecture, tuning identity, detached IPA signature, same-build verifier and
every delivered file before publication. The builder never installs packages.
It prints an independent `authority SHA-256` for the final receipt; retain that
value separately from the build directory.

## Prepare a local release

Release preparation accepts only one validated native build and binds it to an
explicit kernel release tag and ABI. It creates a fresh local closed directory;
it never creates a Git tag, uploads an artefact or changes a remote service.

```sh
linux-armer userspace camera release prepare \
  --repository-root . \
  --from <printed-native-build-directory> \
  --output-dir build/release \
  --tag <camera-release-tag> \
  --kernel-tag <kernel-release-tag> \
  --kernel-abi <kernel-abi> \
  --build-authority-sha256 <build-authority-sha256> \
  --dry-run

linux-armer userspace camera release validate \
  build/release/<camera-release-tag> \
  --repository-root . \
  --authority-sha256 <release-authority-sha256>
```

Remove `--dry-run` only after reviewing the source, kernel pairing and fresh
destination. Successful preparation prints the independent release authority
SHA-256. Retain it separately and use it to repeat `release validate` against
the completed directory before using that directory as installer input.

Release preparation and validation authenticate the supplied authority digest,
package metadata, Debian records, package hashes and streamed tuning data. They
never extract or execute a package payload. The authenticated build receipt's
same-build IPA result remains build-time evidence rather than a command which
is rerun from an untrusted hand-off directory.

## Install and inspect

Review installation without privilege, then repeat with elevated access and
`--yes`:

```sh
linux-armer userspace install camera \
  --from build/release/<camera-release-tag> \
  --repository-root . \
  --camera-authority-sha256 <release-authority-sha256> \
  --dry-run

sudo linux-armer userspace install camera \
  --from build/release/<camera-release-tag> \
  --repository-root . \
  --camera-authority-sha256 <release-authority-sha256> \
  --yes

linux-armer doctor userspace --feature camera
```

The installer also accepts the exact native build directory printed by
`userspace build camera`; pass that build's printed authority digest instead of
a release digest. It repeats current-`HEAD`, package, Debian-record, digest and
tuning proof without executing bundle code, then hashes each package again
while staging it privately before `apt-get`. A prepared local release is the
preferred hand-off because it also records the paired kernel tag and ABI. Do
not combine packages from different builds or bypass either structured
authority by passing individual packages to `linux-armer`.

## Capture and render private RAW10 evidence

The live capture domain discovers only the reviewed
IMX681 → CSIPHY2 → CSID0 → VFE0-RDI0 route. A dry run validates the graph
without configuring or streaming it:

```sh
linux-armer userspace camera capture --dry-run
linux-armer userspace camera capture --output capture.raw --frames 10
linux-armer userspace camera render capture.raw preview.png
```

Capture enforces exact 3840×2640 packed-RAW10 frame geometry, transport,
sampled-content, temporal and emitted-kernel-error gates. It does not claim
that the privacy LED, image quality, cold boot or suspend/resume passed. RAW and
preview files may contain sensitive imagery; keep them private and out of
source control, releases, issue attachments and ordinary diagnostics.

## Desktop browser access

The recorded tested desktop exported the processed stream through PipeWire as
`Built-in Front Camera`. Browser feature switches and names change between
releases, so use the distribution and browser's current PipeWire camera
documentation. A browser preview is a useful end-to-end test, but does not
replace the native package, route and RAW validation gates.

## Acceptance gates

Before describing a camera pairing as hardware-qualified, record all of the
following against the exact camera and kernel release manifests:

1. native package and release validation;
2. `doctor userspace --feature camera` on the installed target;
3. a clean capture dry run and complete RAW10 capture;
4. manual privacy-LED observation for stream start and stop;
5. covered-lens pedestal and controlled exposure/gain response;
6. a reviewed colour-chart result before adding a colour matrix;
7. repeated browser or application streams;
8. cold boot and suspend/resume without graph, sensor or privacy regressions.

Upstream libcamera is LGPL-2.1-or-later and its IPA modules are
LGPL-2.1-or-later. Release preparation retains the source and licence evidence
recorded by the native build; review those records before redistribution.
