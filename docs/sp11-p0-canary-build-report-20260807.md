# Surface Pro 11 Phase 0 no-op canary build report

Date: 2026-08-07

Scope: `7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e`

> **Off-target artifact gate: PASS.** The canary preserves the reviewed v3
> kernel configuration, symbols, DTBs, kernel semantics, and touchscreen-module
> semantics after normalizing only the expected ABI/build-identity fields and
> the classified address consequences of the longer ABI.
>
> **Publication: BLOCKED.** The kernel build used the legacy, non-schema-v2
> manifest, and the touchscreen-module manifest does not bind the exact kernel
> headers, normalized configuration, or toolchain. These artifacts are local
> evidence only and must not be released.
>
> **P0.8 hardware evidence: NOT DONE.** The canary has not been installed or
> booted on the target. The privileged one-shot preflight, one-shot boot,
> intended active-FDT check, second-boot return to the persistent fallback, and
> physical recovery-media test have not been performed.

This is a packaging-only, no-op ABI canary for the recovery workflow in
[ADR-0053](adr/adr-0053-one-shot-experimental-kernel-boot.md). It does not add
a hardware feature or change the v3 DTB. Under
[ADR-0055](adr/adr-0055-retire-installed-loose-dtb-injection.md), its relevant
device-tree inputs are the DTB packaged with the exact kernel and the matching
DTB embedded in that kernel's Stubble EFI image, not a shared loose DTB.

## Pinned inputs

| Input | Value |
|---|---|
| Kernel source | `https://github.com/jglathe/linux_ms_dev_kit.git` |
| Source ref | `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` |
| Exact source commit | [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/commit/8f953dd060bc6e8fb86ca2ea8a92f258141c0169) |
| OCI image | `ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03` |
| Resolved ARM64 manifest | `sha256:3fe5b610f5c41eeeb56c2995bd4afb4990ac5b80dc980e33f9251eaaa8013615` |
| Container platform | `linux/arm64/v8` |
| Build targets | `binary-indep binary-qcom-x1e` |
| Parallel jobs | `8` |
| Ordered patch directories | `patches/jglathe-qcom-x1e-7.2-rc5`, `patches/sp11-qcom-x1e-7.2-rc5-v3`, `patches/sp11-qcom-x1e-7.2-rc5-v3-p0-canary1` |

The first four patches are the reviewed v3 baseline. The fifth changes only
Debian packaging metadata to create the distinct canary ABI.

| Order | Repository-relative patch | SHA-256 |
|---:|---|---|
| 1 | `patches/jglathe-qcom-x1e-7.2-rc5/0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch` | `16afa251fd448b204d5d1bf80605edc58fd30e6bb899a55084abd36d5dd759d8` |
| 2 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0001-arm64-dts-qcom-x1-denali-use-2.4-MHz-DMIC-clock.patch` | `333a168c3941b804aa87803b435ac4b3dbf023e5a09e2abcf43327a89dfad9e8` |
| 3 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0002-arm64-dts-qcom-x1-denali-enable-mshw0485-touchscreen.patch` | `92aac884bb3791e15abf33ff09a6669e93f320c1a96c9a9f3b4047c41d385293` |
| 4 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0003-debian-qcom-x1e-name-SP11-v3-build.patch` | `3fa309d079f8cbee7b6a4abe4a4705f485bbd5c3518920bdb4753b2d775a4431` |
| 5 | `patches/sp11-qcom-x1e-7.2-rc5-v3-p0-canary1/0001-debian-qcom-x1e-name-SP11-v3-P0-canary-build.patch` | `5317d718a257c8d1eab0c7ae88e6ebd95c8a8125f3d38fe73b2ce274d51ed6a8` |

## Kernel package inventory

These SHA-256 values identify this one completed canary run. Sizes are decimal
bytes.

| Package | Size | SHA-256 |
|---|---:|---|
| `linux-headers-7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e_7.2-rc5-jg-0sp11v3p0canary1_arm64.deb` | 1,437,296 | `c257bb8f3963671c62a1adcff68f0fc4904ad2e71cea5cd5cdffaabd8573ea07` |
| `linux-image-7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e_7.2-rc5-jg-0sp11v3p0canary1_arm64.deb` | 164,032 | `c0cef27aa82da925a7aef42341afb67ab42101b3a8e984b74b023636070babb3` |
| `linux-modules-7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e_7.2-rc5-jg-0sp11v3p0canary1_arm64.deb` | 310,220,992 | `c0936a160558969a28453e45eb2acaac30c52a4f65b19300e8a417238f4945fa` |
| `linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v3p0canary1_7.2-rc5-jg-0sp11v3p0canary1_all.deb` | 15,211,754 | `d9ac55518a92202518a758ae355512cde4e5f3c1a5a2af65f93a6cb84f0dc584` |

The legacy kernel build manifest has SHA-256
`628e531af58534ed14c1e311276349a6e775413f98b9f546732e6c2cfb24998c`.
The emitted package-list record has SHA-256
`072b923a694e72d70b1c50695398767c93c7bdf76d714f32fcbd42b387c599f6`.
Their hashes make this run auditable; they do not remedy the manifest fields
that were never recorded.

## Kernel and DTB semantic audit

The read-only audit compared the canary payload with the reviewed v3 baseline
and failed closed on unclassified differences.

| Evidence | Result |
|---|---|
| Kernel configuration | The only raw difference is `CONFIG_VERSION_SIGNATURE`. After normalizing that one setting, both configurations hash to `5a41908b452a973b88c83066a2fbd6f2cb14bd15e6b1e565b83b92413ff11264`. |
| `Module.symvers` | Byte-exact: `711bd9573fa7c06f282c31c4369f14c0e8446aa16c36c5a3d124bc9d95344c36`. |
| Packaged DTBs | All 1,792 are byte-exact; path-qualified aggregate `d41b7c27e7e58eb307494f0add22d8fab8383d2ddf13c173901908a2d53b95a6`. |
| Stubble-embedded DTBs | All 38 `.dtbauto` payloads are byte-exact; ordinal-qualified aggregate `1c9fb2a76004df732437ccf59bd18727b04daf13a7ab35fff562a0e93ca41a53`. |
| Surface Pro 11 OLED DTB | Packaged and embedded ordinal 7 are byte-identical: `360f1b9ef87e3de33e6eeeb6fb8179abd385807860e0d177ab4d57cea9d68f7b`. |
| Kernel code semantics | Only address-bearing relocation immediates changed as a mechanical consequence of the longer ABI string and resulting data layout. Masking exactly those fields gives `455a50fdacca1c0662c6d78be466dc1a0f864b33a0203060dbaf8153bd3d31ae`; zero code symbols moved and no executable byte remained unexplained. |

The relocation-masked value is an audit digest, not a hash of a releasable
binary. Raw executable bytes are not asserted to be identical where their
address-bearing immediates necessarily refer to shifted ABI-dependent data.

## Touchscreen module inventory and audit

The out-of-tree modules were built from the clean
[`geocausa/SP11X1e-touchscreen`](https://github.com/geocausa/SP11X1e-touchscreen)
tree at exact commit
[`6bbcf7a4759a73014047a57e819219dd7f34951a`](https://github.com/geocausa/SP11X1e-touchscreen/commit/6bbcf7a4759a73014047a57e819219dd7f34951a)
and tree `c4897f33bf024d01acd9041cd16a758c216ed3e6`. Windows SE
initialization remained disabled. Each module has the exact canary vermagic
`7.2-rc5-jg-0sp11v3p0canary1-qcom-x1e SMP preempt mod_unload modversions aarch64`.

| Module | Size | `srcversion` | Raw SHA-256 | Canonical semantic SHA-256 |
|---|---:|---|---|---|
| `gpi.ko` | 138,920 | `A9BE6B3E2AEF71B5F41F865` | `13011f448837b8e0a7f9ccd3a5b7279bfc2ac0c0543d440372aaef88adf94616` | `832a453bc97f8df9937a8acca6836ee4c1c52fe79440485498e39e46b6ff460a` |
| `spi-geni-qcom.ko` | 106,904 | `3A825FCED27D92B662FFA0E` | `c0c1d0532001dfc738945adc5105ab48c2391998c86e0e8a69803556c761ea8a` | `8abfb477ad2433c0dac008336d63f59a42266de5ab2b1ce10d423bd9568192be` |
| `mshw0485_touch.ko` | 134,896 | `CF6FA888C2B8E129277C297` | `20e2e5985a1261c91f30f7c11a73d49f9ef12d9557b6012fbd1ccde577156ee7` | `6ed6202c57ab702261bd177c7854ae1814e48c10ec84193d40811ed78e9aad18` |

The module manifest is 1,071 bytes and has SHA-256
`1919b91f449a94c9d18156bfc5e4d85486e27c41dd5f1bde70fd5c87c0112217`.

All executable and core functional ELF sections match the v3 module set. The
touch module's read-only data is also byte-exact. For `gpi` and
`spi-geni-qcom`, the only payload difference beyond expected vermagic and
build-ID identity is an embedded diagnostic string naming the ABI-qualified
kernel-header directory. The longer canary ABI increases that string's aligned
slot by exactly eight bytes; the corresponding relocation and symbol-table
offsets move mechanically. Canonicalizing that diagnostic-only path and the
expected identity fields yields the semantic hashes above. The audit found no
unexplained module byte.

## Reproducibility and publication limits

This report records one clean canary build, not a two-build canary
reproducibility experiment. The adjacent v3 pair documented in the
[2026-08-07 kernel reproducibility report](sp11-kernel-reproducibility-report-20260807.md)
already demonstrates that the current recipe is not bit-reproducible: transient
build identity, timestamps, generated X.509 material, GNU build IDs, archive
mtimes, and module signatures change raw package bytes even when normalized
payloads are equivalent. APT repositories were not snapshot-pinned, so an
immutable future dependency replay is also unproven. The hashes in this report
must therefore be read as identity for this run, not as predicted outputs of a
future rebuild.

The canary was intentionally built without release mode. Its legacy kernel
manifest does not satisfy the schema-v2 release contract: among other omitted
bindings, it does not make the support-tree state, ordered patch hashes,
package identities, and release-signing identity one fail-closed provenance
record. The touchscreen manifest records source, ABI, module hashes,
`srcversion`, and Windows SE policy, but does not bind the exact header tree,
normalized kernel configuration, or complete toolchain. Publication stays
blocked until both artifacts are rebuilt under reviewed, complete release
provenance.

## Hardware evidence still required

No target state was changed during this build or audit. The following P0
evidence remains outstanding:

- complete the P0.7 installed-system migration and recovery-fallback gate;
- run the ADR-0053 privileged dry run from the boot-tested fallback;
- install the canary locally only after P0.7, the recovery gates, and the
  independent artifact evidence have been reviewed;
- queue and boot it once through `next_entry` without changing the persistent
  fallback;
- verify the packaged, Stubble-embedded, and active FDT for that exact boot;
- reboot again and prove return to the unchanged fallback; and
- boot the prepared recovery medium through the documented physical path.

Until all of that evidence is captured and reviewed, P0.8 is not complete and
no later hardware-mutating phase is unblocked.
