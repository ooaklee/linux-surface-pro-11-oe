# Native sensor userspace — experimental sources

This directory holds the accepted native Linux sensor development sources,
separately from the kernel. They are **source-only, not an installable release**:
they are not included in v26/v27 and have not been deployed or physically
qualified on a Surface. Building them does not enable automatic rotation or
ambient-light handling. No Windows driver, DLL, service or MSI payload is needed.

| Component | Purpose | Source identity |
| --- | --- | --- |
| [libqmi](libqmi/README.md) | Pinned upstream QMI/QRTR dependency with SSC protocol support | 1.39.1, `d9e8af5cae7fdf9749baf87606568d3af4d03082` |
| [libssc](libssc/README.md) | Downstream SSC library, owned sensor/sample APIs and `ssccli` | 0.4.7 development snapshot; not an upstream 0.4.7 release |
| [iio-sensor-proxy](iio-sensor-proxy/README.md) | Downstream desktop-facing IIO/SSC sensor client and `monitor-sensor` | Based on `ca0d5b08bd647afc5f8ead3ce00a44018fbc633f` |

Each component has an integration README and a `source/` snapshot. Relative
inventories cover [libqmi](libqmi/SOURCE.json), [libssc](libssc/SOURCE.json) and
[iio-sensor-proxy](iio-sensor-proxy/SOURCE.json). Original licences, notices,
upstream READMEs and build systems remain in `source/`. The only omitted
upstream material is a raw Android diagnostic capture, explicitly recorded in
the libssc inventory; no production source is omitted. Git executable bits are
preserved, while delivery-only read-only directory/file permissions are not.

## Build and qualification

Use [BUILDING.md](BUILDING.md) for an unprivileged native ARM64 build into a
private prefix and selected fixture-only tests. It does not install a system
service or replace distribution libraries. [VALIDATION.md](VALIDATION.md)
separates existing software evidence from hardware and deployment work still
required. The source inventories identify this exact composition: matching
version numbers from unrelated system packages are not a substitute.

These sources do not establish device roles, sensor axes, calibration,
timestamp clocks, suspend/resume reliability or complete hardware parity.
Do not run discovery/streaming CLI commands or activate the proxy as part of
the source-build check. Those operations can contact firmware and require a
separate, explicit hardware qualification plan.

## Lexr boundary

Lexr integration is checked against
[`b74247d08f7ccf90110a291c62c5fb56d895c55f`](https://github.com/ooaklee/lexr.sh/commit/b74247d08f7ccf90110a291c62c5fb56d895c55f).
That revision has no sensor source-build/install adapter or sensor catalogue
capability. Its source builders support IPTSD and camera only; its installer
supports audio, IPTSD, camera and Wi-Fi, with audio/IPTSD as `recommended`.
Neither surface supports sensors. Adding a YAML file does not create an
executable workflow. `SOURCE.json` is an OE source
inventory, **not** a Lexr catalogue, compatibility promise or install recipe.
There is no supported `lexr userspace build sensors` command at this boundary.

Keep three separate milestones:

- **Raw sources:** available here with licences, inventories and a manual
  maintainer build recipe. This does not promise an installable bundle.
- **Lexr build-only support:** not advertised at the checked revision above.
  A future compiled adapter must authenticate this source composition, own
  dependency preparation and supervised native ARM64 compilation, validate
  the outputs, and pass its normal end-to-end CLI flow, dry-run and refusal
  checks. A source-only entry must stay experimental and build-only, with no
  install action or invented kernel/OS qualification. Build-only qualification
  is separate from desktop deployment and physical sensor compatibility.
- **Desktop installation and hardware support:** still unqualified. This
  separately needs reviewed packaging and runtime providers, service/package
  conflict handling, privileges, transactional rollback, explicit activation
  and physical qualification of the declared kernel/OS/device pairing.

An editable manifest alone does not deliver any of these executable workflows.
Do not guess a minimum Lexr or kernel version from the `sp11vN` number. Existing
recommended audio/IPTSD and camera workflows are unchanged.

Workflow ownership remains with Lexr under
[ADR0069](../../docs/adr/adr-0069-standalone-lexr-workflow-ownership.md) and
[ADR0070](../../docs/adr/adr-0070-retire-superseded-repository-scripts.md).
These are component sources and maintainer build instructions, not a second
installer or an OE script-runner API.
