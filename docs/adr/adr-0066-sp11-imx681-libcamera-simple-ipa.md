---
id: adr-0066-sp11-imx681-libcamera-simple-ipa
title: "ADR0066: SP11 IMX681 libcamera Simple IPA Integration"
# prettier-ignore
description: Architecture Decision Record (ADR) for integrating the Surface Pro 11 IMX681 with libcamera's simple IPA through a model-specific gain helper, evidence-gated tuning, and a coherently signed Ubuntu package build.
---

# ADR0066: SP11 IMX681 libcamera Simple IPA Integration

## Status

Accepted on 2026-08-28 as the userspace integration design for the
`7.2.0-jg-0sp11v14` camera milestone. Package installation remains gated on a
successful v14 raw capture. Image-quality, PipeWire, and browser acceptance
remain runtime gates.

## Context

The v14 kernel identifies the front camera as `imx681` and exposes one standard
`V4L2_CID_ANALOGUE_GAIN` control. Control code `x` is in the range `0..960` and
programs the sensor's effective global U8.8 gain as:

```text
register value = 0x0100 + 4 * x
real gain      = 1 + x / 64
```

Ubuntu Resolute currently ships libcamera `0.7.0-1ubuntu2`. Its simple IPA
creates a sensor helper from the sensor model and selects tuning data using
`sensor->model() + ".yaml"`. Version 0.7 has no IMX681 helper. Without one it
interprets kernel codes `0..960` as real gain and uses the default code `192`
as its nominal 1x threshold. Code 192 is actually 4x, so automatic exposure
cannot correctly reduce the initial sensor gain in a bright scene.

The tuning file must consequently be named `simple/imx681.yaml`, not
`smiapp.yaml`. The completed Snapdragon reference publishes useful factory CCM
seed values, but neither this device's Windows trace nor a Linux colour-target
capture has validated them. The Windows corpus also does not establish a RAW10
black pedestal or Bayer order.

libcamera generates an IPA signing key at build time. `libcamera0.7` embeds the
public key, while `libcamera-ipa` contains modules signed with the matching
private key. Replacing only `ipa_soft_simple.so`, or installing a newly built
IPA beside the distro core library, can therefore fail signature validation or
create an untraceable mixed installation.

## Decision

We will integrate the IMX681 into libcamera as follows.

### Sensor helper and tuning

- Add `CameraSensorHelperImx681` with
  `AnalogueGainLinear{ 1, 64, 0, 64 }`. This expresses exactly
  `gain = 1 + code / 64` and its inverse.
- Do not assert a fixed helper black level yet. Measure covered-lens RAW10
  frames first and retain simple IPA black-level estimation until the pedestal
  is defensible.
- Install model-named tuning as
  `/usr/share/libcamera/ipa/simple/imx681.yaml`.
- Treat the four reference factory CCMs as seed values pending Linux colour
  validation. Do not use a CCM to hide an incorrect Bayer order.
- Retain libcamera 0.7's stock Adjust defaults and global AGC target. Any gamma,
  contrast, saturation, or exposure-target change must be sensor-scoped and
  justified by captured output.

The auditable source bundle lives in:

```text
scripts/build-sp11-imx681-libcamera-docker.sh
userspace/camera/libcamera/0001-libipa-add-imx681-simple-ipa-support.patch
userspace/camera/libcamera/imx681.yaml
userspace/camera/libcamera/BASE.txt
userspace/camera/libcamera/README.md
```

### Packaging

- Use `scripts/build-sp11-imx681-libcamera-docker.sh` as the canonical local
  package builder. It requires a native ARM64 Linux host, ARM64 Docker server,
  and an Ubuntu 26.04 ARM64 container; emulated or cross-architecture builds
  do not satisfy this release gate.
- Resolve the requested builder tag to an immutable image ID, record both, and
  execute the ID. Do not inspect one image and later run a mutable tag.
- Require the builder, `BASE.txt`, patch, and YAML to be tracked and
  byte-identical to the support `HEAD`. Stage exactly those four inputs in a
  private mode-`0700` directory and mount only that directory read-only. The
  container never receives the support repository; unrelated untracked files
  remain outside the build.
- Apply the patch after Ubuntu's existing quilt series to the exact
  `0.7.0-1ubuntu2` source package. Build in a new private directory with a
  version of the form
  `0.7.0-1ubuntu2+sp11.1.<23-digit-UTC-nanoseconds>.<32-hex-random-nonce>`;
  never reuse a version across builds that have different generated signing
  keys.
- Verify the downloaded DSC, orig tarball, and Debian source tarball against
  the hashes in `BASE.txt` before resolving build dependencies or importing the
  local quilt patch. The pinned DSC hash is the trust anchor when its historical
  signing key is unavailable in the current Ubuntu keyring.
- Install at least `libcamera0.7` and `libcamera-ipa` from that same build so
  the embedded public key and IPA signatures match. Keep rebuilt tools and
  V4L2/GStreamer shims on the same package version when they are installed.
- Bind the exact package filenames and hashes to the single build's `.changes`
  file. Do not select privileged install inputs through globs or a shared
  staging directory.
- Require `ipa_verify` to accept `ipa_soft_simple.so` before installation and
  again against the installed package set.
- Preserve the exact `.changes` and `.buildinfo` alongside the five selected
  ARM64 runtime packages after all `.changes` entries pass SHA-256 validation
  and the extracted core/tools/IPA set passes the same-build verifier. Record
  the image identity, support commit, source and input hashes, applied patch
  order, build timing, `.buildinfo` hash, package metadata, and output hashes in
  `sp11-imx681-libcamera-build-manifest.txt`.
- Treat the retained `.changes` as the unmodified record of the complete
  binary-any build, not as a self-contained upload directory. It references
  development, debug, Python, and other unexported artifacts. The container
  verifies every entry while all outputs exist; the host verifies the six
  delivered entries, and the manifest distinguishes both phases and enumerates
  every intentionally omitted entry.
- After copying, have the host require the exact eight regular files, recompute
  the manifest-recorded hashes and package metadata, bind every selected DEB
  and `.buildinfo` to its unique `.changes` entry, and repeat `ipa_verify` from
  a private extraction of the same core/tools/IPA set.
- Keep output under the ignored, mode-`0700` `build/libcamera-docker/` tree,
  reject a pre-existing symlink, foreign owner, or non-`0700` root, return files
  to the invoking UID/GID, and never install from the builder. Package
  installation is a separate, explicit post-raw-capture action using exact
  manifest-derived paths rather than globs.
- Do not install a second libcamera under `/usr/local`, copy an isolated IPA
  shared object, or replace only PipeWire's libcamera SPA plugin.

### Runtime sequencing

1. Boot the provenance-verified v14 kernel and pass the topology, negotiated
   format, exact frame-size, sampled RAW10 range/entropy/temporal-difference,
   and emitted-error checks in `scripts/validate-sp11-imx681-raw.sh`. Then
   separately complete its documented repeated-stream, control-sweep,
   Bayer-order, dark-pedestal, and privacy-LED follow-ups; the one-shot script
   does not automate those manual gates.
2. Install the coherent libcamera package set and require the logs to select
   `simple/imx681.yaml`, create the IMX681 helper, and report a real-gain range
   near `1..16`.
3. Validate software-ISP output and repeated start/stop through `cam` and
   GStreamer before testing PipeWire and browser/WebRTC clients.
4. Keep distro PipeWire, WirePlumber, and systemd hardening unchanged initially.
   Backport or relax components only after a specific repeatable runtime
   failure identifies that layer.

V4L2 core owns the device-tree privacy LED. We will not install the reference
GPIO polling daemon, hard-code a GPIO chip or `/dev/videoN`, or encode another
machine's paths in a service.

## Consequences

- The simple IPA operates in physical gain units and can reduce gain below the
  kernel's 4x startup default instead of treating code 192 as nominal 1x.
- The patch, tuning data, signing key, core library, and IPA remain a coherent,
  reversible Ubuntu package build.
- A package build no longer depends on mutable host build dependencies or a
  shared source directory. Each invocation has a timestamp-and-random-nonce
  version, disposable container workspace, bounded private output set, and
  auditable provenance records.
- Initial processed colour benefits from reference seed matrices but is not
  described as calibrated until Linux measurements pass.
- Black level, longer-than-71-ms exposure, LED polarity, and Bayer order remain
  explicit measurement work rather than unverified constants.
- PipeWire allocation backports, service-hardening changes, custom WirePlumber
  rules, and browser workarounds remain conditional remedies, not default
  configuration.

## Acceptance gates

1. The native ARM64 Ubuntu 26.04 Docker builder rejects dirty target inputs,
   including its own script, verifies the exact Ubuntu DSC and payload hashes,
   applies the complete distro patch series before the local patch, and builds
   `ipa_soft_simple`, its signature, and `ipa_verify` successfully without
   mounting or modifying the support repository.
2. The package contains `ipa_soft_simple.so`, its detached `.sign` file, and
   `simple/imx681.yaml`; the installed core, IPA, tools, V4L2 shim, and
   GStreamer shim have the same unique
   `0.7.0-1ubuntu2+sp11.1.<UTC-nanoseconds>.<random-nonce>` version and match the
   one checksum-verified `.changes`. The private output contains exactly those
   five packages, `.changes`, `.buildinfo`, and a manifest whose support commit,
   image, source, package, and hash fields pass the host post-check and repeated
   same-build IPA verification.
3. `cam` emits neither a helper-creation failure nor an uncalibrated tuning
   fallback, and reports gain approximately `1..16`.
4. Automatic exposure can descend below 4x in a bright scene, while exposure
   and gain sweeps remain monotonic.
5. Repeated `cam`, GStreamer, PipeWire, and browser sessions work across
   suspend/resume without DMA-import, allocation, IPA, or EGL failures.
6. The privacy LED is off while idle, on only during a real stream, and returns
   off after normal stop and failed start.

## References

- [ADR0065: SP11 Front Camera C-PHY Integration](adr-0065-sp11-front-camera-cphy-integration.md)
- [Hardware-proven Snapdragon reference](https://github.com/karsies-wq/sp11-imx681-linux/tree/b08f76f40b8d7b715bd4da6aef484f86142cc147)
- [libcamera sensor helper implementation](https://git.libcamera.org/libcamera/libcamera.git/tree/src/ipa/libipa/camera_sensor_helper.cpp?h=v0.7.0)
