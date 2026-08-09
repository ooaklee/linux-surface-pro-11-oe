# Surface Pro 11 immutable kernel build evidence

Date: 2026-08-08

Scope: one real release-mode build of
`7.2-rc5-jg-0sp11v3-qcom-x1e` from the pinned kernel source, OCI image, and
Ubuntu snapshot.

> **P0.4c immutable-input build verification: COMPLETE for one real build.**
> The fresh build completed, emitted the required provenance trio, and passed
> independent host validation against every retained immutable APT input.
>
> **P0.4 remains OPEN overall.** This is one immutable-input provenance result,
> not a two-build or byte-reproducibility result. P0.4b remains failed/open.
>
> **NO-PUBLISH.** Signing policy, corresponding-source and release-candidate
> review, target/recovery evidence, hardware validation, and explicit release
> authorization remain open. The interim project-code licence and SP11 UCM
> basis is now recorded in [`LEGAL.md`](../LEGAL.md), with final reviews pending;
> that pending status alone is not a blanket block on newly authored artifacts.

## Exact build identity

| Input | Verified value |
|---|---|
| Support repository | [`8110b2933beca73e2046f706f1299553906ff30d`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/8110b2933beca73e2046f706f1299553906ff30d), clean before and after the build |
| Kernel source | `https://github.com/jglathe/linux_ms_dev_kit.git` |
| Kernel ref | `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` |
| Kernel commit | [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/commit/8f953dd060bc6e8fb86ca2ea8a92f258141c0169) |
| OCI index | `ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03` |
| ARM64 child manifest | `sha256:3fe5b610f5c41eeeb56c2995bd4afb4990ac5b80dc980e33f9251eaaa8013615` |
| Ubuntu snapshot | `20260807T000000Z` |
| Build target | `binary-indep binary-qcom-x1e` |
| Jobs | `8` |
| Patch count | `4`, all exact committed hashes and all applied |
| Patched diff SHA-256 | `016e92b6da429884157a6b37d305f7c9db52db579c2bf595ea1963bc5cba9855` |
| Patched tree | `c8fc15ee7b216f10b48d70e521e23b7c16ab88bc` |

The release-mode wrapper exited successfully only after it created and
validated the schema-v2 build manifest, v1 APT sidecar, and v1 build-inputs
envelope. A separate host invocation of the retained-input validator then
validated the same bytes using canonical managed paths. It checked the raw OCI
index and unique ARM64 child, generated build controls, retained APT trees,
package inventories, cached Debs, manifest, sidecar, and all five envelope
inputs.

## Immutable APT evidence

| Evidence | Verified result |
|---|---|
| `InRelease` files | 4 exact pinned files and signatures |
| Signed indexes | 32 exact authenticated gzip indexes |
| Authenticated empty indexes | 6 exact 20-byte gzip files, SHA-256 `9ceffb7310338057cfe71a4ae1e2c98d2c485d81cdef906532a801f457a38d64`, each decompressing to zero bytes |
| Local list views | The six empty-index views are absent; all 26 nonempty views are present and decode to the signed payloads |
| Retained list targets | 31 exact files |
| Downloaded Debs | 334, each matched to retained signed `Packages.gz` metadata |
| Pre-install inventory | 87 packages; SHA-256 `aeeb11bfb5c8e0273e9efec427a72c16bc198d5b035a06f9e50f426517626626` |
| Post-install inventory | 415 packages; SHA-256 `39a5a0bd62c72ee8bdaeaad45ec38159f5a38d1105f131186e1d51caa553cf3e` |
| Local build-deps Deb | 2,652 bytes; SHA-256 `5b6f86532f4b0a47e5005c9f2f8224017680e3412723927f9cec04322987dc95` |
| Strict HTTPS recheck | `true` |
| APT provenance complete | `true` |

The six absent list views are expected APT behaviour for authenticated indexes
whose decompressed payload is empty. No placeholder files were synthesized.

## Copied artifacts

The artifact directory contained exactly these nine regular, non-symlinked
files. Sizes are decimal bytes.

| Artifact | Size | SHA-256 |
|---|---:|---|
| `linux-headers-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb` | 1,426,584 | `7096182c8b87c38df48bf219aab449044da4a9f71463edd1c9453c08676e65a7` |
| `linux-image-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb` | 164,032 | `bbd3135af212f8335f32e2816ee9d349071d8c093d4c0703583bd7247d53a0a9` |
| `linux-modules-7.2-rc5-jg-0sp11v3-qcom-x1e_7.2-rc5-jg-0sp11v3_arm64.deb` | 306,821,312 | `8dad2fa8a6dee0db66010724acc9214b98d7eb9f5db51aa615d6e2a1d4d17aa7` |
| `linux-qcom-x1e-build-deps_1.0_arm64.deb` | 2,652 | `5b6f86532f4b0a47e5005c9f2f8224017680e3412723927f9cec04322987dc95` |
| `linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3_7.2-rc5-jg-0sp11v3_all.deb` | 15,169,970 | `dc2fd82c859972a6780cdd47599e9e29fdf4e78c205344044eff67c6a3e9415e` |
| `sp11-kernel-apt-provenance.txt` | 279,701 | `e26b8c7ee5a296b94c1f7eac4bba2ceafe53eabc0f73bb93b6cb33ac8c2efa3b` |
| `sp11-kernel-build-inputs.txt` | 1,408 | `0a8e56858b99eef4dfad1ed9bae72ab40b9f86acb22b1a18d46ce4e4284bfacc` |
| `sp11-kernel-build-manifest.txt` | 5,499 | `36ae9da3166b45ab161782d191290349d8053a60aec445d3d011ac01eba42406` |
| `sp11-kernel-debs.txt` | 356 | `d6589374bfc1ed66987403c49787b1b483987e45b4bffb7236447fc82c1c03d1` |

The path-neutral nine-file inventory uses
`sp11-path-inventory-json-lines-v1`. Each record has exactly the fields
`{"path":...,"sha256":...,"size":...}`, where `path` is the basename,
`size` is a JSON integer containing the decimal byte size, and `sha256` is the
lowercase SHA-256. Records are sorted by `path`, serialized with Python
`json.dumps(record, sort_keys=True, separators=(",", ":"),
ensure_ascii=True)`, and followed by exactly one LF per record, with no header
or trailer. Its aggregate SHA-256 is
`4f2ab8edd181dff4ad24a2cc8560b373425bcca4904a9f689d7f4fd97857fa5a`.

The four kernel-package control records independently matched their manifest
roles, names, version `7.2-rc5-jg-0sp11v3`, and architecture (`arm64`, except
the common headers package is `all`). The local build-deps package independently
matched `linux-qcom-x1e-build-deps`, version `1.0`, architecture `arm64`.

## Module inventory

The committed fail-closed scanner completed with `--expect any`:

| Field | Result |
|---|---:|
| Kernel ABI | `7.2-rc5-jg-0sp11v3-qcom-x1e` |
| Modules | 7,814 |
| Marker-signed modules | 7,729 |
| Unsigned modules | 85 |
| Zstandard-compressed modules | 7,814 |
| Signature expectation satisfied | `true` |
| Scan completed | `true` |

These counts match the retained historical v3 classification. The scanner
exhaustively inventories every module; `--expect any` records the observed
mixed state without approving it as a future release-signing policy.

## Independent checks and boundaries

Both Quality workflows for the exact support commit completed successfully:

- [push run 31245126131](https://github.com/ooaklee/linux-surface-pro-11-oe/actions/runs/31245126131);
- [pull-request run 31245127935](https://github.com/ooaklee/linux-surface-pro-11-oe/actions/runs/31245127935).

Independent host review found no P0, P1, or P2 issue in the retained inputs,
copied artifacts, Deb metadata, or module scan. The host review did not open the
private Linux build volume to re-hash its seven manifest-bound intermediate
outputs, so this report does not claim an independent second observation of
those volume-resident files.

## Offline patched-source follow-up

Later deterministic archive tooling at support commit
[`4c644d57121de1b1b59f9721bb003cb666e86dab`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/4c644d57121de1b1b59f9721bb003cb666e86dab)
passed its exact-head [push run](https://github.com/ooaklee/linux-surface-pro-11-oe/actions/runs/31277808526)
and [pull-request run](https://github.com/ooaklee/linux-surface-pro-11-oe/actions/runs/31277810128).
An offline, network-disabled replay then reauthenticated all 334 retained Debs
and the local build-dependencies Deb and reproduced the exact 87-package to
415-package inventory transition. That is a passed APT replay sub-gate, not a
completed source-archive integration.

The independent archive validator correctly rejected the historical patched
tree because its tracked `debian/scripts/misc/find-dtbs.py` symbolic link has
an absolute developer-workstation target outside the archive root. No archive
was installed, the two release-source output directories remained empty, and
the second independent outer run did not start. The retained four-patch tree
`c8fc15ee7b216f10b48d70e521e23b7c16ab88bc` is therefore **NO-GO** for a
patched-source archive or release-asset claim. It must not be rewritten or
postprocessed under its existing manifest.

A future candidate requires an ordered source patch that removes the stale
link, an exact-tree symlink-containment preflight, a fresh release build and
manifest, and a fresh offline repeated-generation and independent-validation
run. The fork now carries the deletion and preflight tooling, but no fresh real
build has exercised them. This technical follow-up does not establish
corresponding-source legal sufficiency or authorize publication.

This result closes only P0.4c's one-real-build verification scope. It does not
retroactively make the historical A/B pair immutable, provide a second build
for a raw-byte comparison, remediate the known raw-byte differences, approve
the signing model, establish licence sufficiency, validate hardware, or
authorize an install or publication. The envelope remains byte-for-byte
authoritative with `Publication schema propagation: incomplete`; later outer
manifests carry their own propagation attestations without rewriting that
build-time fact.
