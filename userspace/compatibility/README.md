# Userspace compatibility declarations

These files are the authored compatibility input for the next packaging of the
existing audio, pen and camera components. They implement the source side of
[Lexr issue #44](https://github.com/ooaklee/lexr.sh/issues/44). Lexr authenticates
the canonical bytes from a clean checkout's Git `HEAD`, checks them against its
compiled component policy and copies them into the prepared release.

| Component | Next packaging identity | Existing evidence |
| --- | --- | --- |
| `audio-fullio-v19c` | `sp11-audio-v19c-full` | [FullIO v19c pairing](../../docs/adr/adr-0064-sp11-audio-release-strategy.md) |
| `iptsd-v1` | `sp11-iptsd-v3` | [IPTSD integration](../iptsd-sp11/README.md) |
| `imx681-libcamera-v1` | `sp11-imx681-libcamera-v2` | [IMX681 device evidence](../camera/libcamera/README.md#recorded-device-evidence) |

All three declarations use canonical hardware profile IDs for ARM64
Surface Pro 11: `x1e80100-microsoft-denali-oled` (X Elite OLED) and
`x1p64100-microsoft-denali` (X Plus LCD). These match `lexr profile list`;
kernel platform aliases are not compatibility identities. The declarations
retain the existing `7.2.0` / `qcom-x1e` / `sp11` generation bounds. The initial OS
interval covers Ubuntu `26.04` only. Lexr `0.5.0` is the first planned consumer
of this schema. These are component compatibility bounds, not permission to
redistribute a payload or install to arbitrary paths.

`tested_versions` is deliberately empty for the new packaging identities.
Historical device results remain evidence for their exact packages and kernel;
creating these declarations does not qualify a new build or either hardware
profile. If later evidence qualifies only one profile, give it a separate
complete target rule. Until a reviewed
qualification update records an OS version, the shared evaluator reports
`unverified` and mutation requires the dedicated
`--allow-unverified-compatibility` flag. A hard incompatibility or missing target
identity still blocks the operation.

## Prepare a release

Use the matching Lexr implementation, a clean Git-backed support checkout and
an explicit payload target. Build with `--target-architecture arm64`,
`--target-device-profile x1e80100-microsoft-denali-oled` (or
`x1p64100-microsoft-denali` for X Plus LCD), `--target-os ubuntu`,
`--target-os-version 26.04` and the actual `--target-kernel` ABI. Release
preparation takes that ABI through its existing `--kernel-abi` option.
Check the non-mutating plan before preparing a new
local release. Development or dirty Lexr builds also require the dedicated
override; `--yes` is not a compatibility override.

The prepared release must contain the exact canonical
`lexr-component-compatibility.json` bytes, with SHA-256 and size recorded in the
release authority and checksum coverage in `SHA256SUMS`. Retain any independent
authority digest separately from the artefacts. Catalogue adoption requires a
reviewed manifest pin and the existing compiled payload authority; a transfer
receipt alone cannot authorise a component.

Canonical files use the schema's field order, two-space indentation and a
terminal newline. Change the authored file here and let Lexr copy it; do not
maintain a second hand-edited release declaration. Re-run Lexr's canonical
decoder and producer tests after any change.

The published `sp11-audio-v19c`, `sp11-iptsd-v2` and
`sp11-imx681-libcamera-v1` releases remain unchanged. Older Lexr versions keep
their pinned legacy behaviour. These declarations do not retrofit new
metadata into those historical releases.

Native IPTSD builds preserve the existing closed `stage/` payload and retain
these declaration bytes and the producer assessment beside it, covered by an
outer checksum manifest. Those build sidecars do not authorise installation
or establish a published `sp11-iptsd-v3` release. Camera build/release schema 2
and audio release schema 2 include the declaration in their closed artefact
sets. See Lexr's [component compatibility reference](https://github.com/ooaklee/lexr.sh/blob/main/docs/reference/component-compatibility.md)
for migration and the exact producer and consumer boundaries.
