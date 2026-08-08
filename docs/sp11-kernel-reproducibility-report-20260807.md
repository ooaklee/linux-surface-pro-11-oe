# Surface Pro 11 kernel adjacent-build reproducibility report

Date: 2026-08-07

Immutable-input verification addendum: 2026-08-08

Scope: `7.2-rc5-jg-0sp11v3-qcom-x1e`, build pair A/B

> **Byte reproducibility: FAIL.** All four emitted `.deb` files have different
> bytes and SHA-256 digests between builds A and B.
>
> **Normalized/semantic adjacent-pair equivalence: PASS, with zero
> unclassified payload bytes.** Every observed payload difference was either
> removed by an explicit normalization documented below or classified as a
> relocation-immediate consequence of the compressed payload length.
>
> **Immutable future replay for the audited A/B pair: NOT PROVEN.** Those two
> builds predate the immutable-APT implementation described below. A separate
> real clean build completed that path on 2026-08-08, but it cannot
> retroactively strengthen this historical pair.
>
> **P0.4 remains OPEN overall.** For evidence accounting, this report calls the
> historical semantic facet P0.4a (complete), the byte-reproducibility facet
> P0.4b (failed/open), and the one-real-build immutable-input facet P0.4c
> (complete); these
> are not additional backlog IDs. The checked-in historical comparator verifies
> this exact directional A/B pair with zero unknown payload differences, but it
> does not support a bit-for-bit reproducibility claim. The
> [separate P0.4c evidence](sp11-kernel-immutable-build-evidence-20260808.md)
> records the later build without treating it as a replay or a second member of
> this pair. Release/image schema propagation is implemented and
> hostile-fixture tested. Signing, licence, recovery/hardware evidence, and
> explicit release authorization remain open.

## Scope and method

Builds A and B used separate, initially absent Docker Linux volumes and separate
host artifact directories. Both builds started from the same support commit,
checked out the same exact upstream kernel commit, applied the same four patches
in the same order, and ran the same `binary-indep binary-qcom-x1e` build with
eight jobs. No package from one build was reused by the other.

The audit compared the adjacent pair at five levels:

1. declared inputs, manifests, installed build-package inventories, and patched
   source state;
2. raw `.deb` bytes plus extracted Debian control/data members and metadata;
3. kernel configuration, `System.map`, packaged DTBs, and Stubble-embedded
   DTBs;
4. the outer Stubble PE image, its `.linux` payload, the decompressed kernel
   Image, and kernel executable code; and
5. every packaged kernel module, using the kernel module-signature trailer
   format rather than a fixed byte count to separate payloads from signatures.

SHA-256 is used throughout. An "aggregate" digest means SHA-256 over the
lexicographically sorted, path-qualified digest inventory for that set; it is
not a digest of an unspecified directory traversal.

This is an adjacent-pair audit, not a claim that a future build can recover the
same dependency set. It also covers the in-tree kernel packages only. The
separately built `mshw0485_touch` override module is outside this report.

## Pinned and observed inputs

| Input | Value used by both builds |
|---|---|
| Support repository commit | [`f93fe57c0b7d8cb396168a0d7ba4547a5d91f25a`](https://github.com/ooaklee/linux-surface-pro-11-oe/commit/f93fe57c0b7d8cb396168a0d7ba4547a5d91f25a) |
| Kernel source | `https://github.com/jglathe/linux_ms_dev_kit.git` |
| Exact source ref | `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` |
| Exact source commit | [`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`](https://github.com/jglathe/linux_ms_dev_kit/commit/8f953dd060bc6e8fb86ca2ea8a92f258141c0169) |
| OCI index | `ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03` |
| Resolved ARM64 platform manifest | `sha256:3fe5b610f5c41eeeb56c2995bd4afb4990ac5b80dc980e33f9251eaaa8013615` |
| Container platform | `linux/arm64/v8` |
| Build targets | `binary-indep binary-qcom-x1e` |
| Parallel jobs | `8` |
| Ordered patch directories | `patches/jglathe-qcom-x1e-7.2-rc5`, then `patches/sp11-qcom-x1e-7.2-rc5-v3` |
| Build-argument record SHA-256 | `746dd6c9fd1905165f30dc74d5aaf583bfd4f385ce1daf29f33b0180bbbe33dd` |
| Generated inner build script SHA-256 | `9e6e68772272ce938ac4d4012e985e7cd63299d4b71a0d25b8e694bf853f90a4` |
| Legacy build manifest SHA-256 | `4104f152bc6e0bd301e34485918bc10dfb38220ec114c17b3f30622570c81757` |
| Emitted package-list record SHA-256 | `d6589374bfc1ed66987403c49787b1b483987e45b4bffb7236447fc82c1c03d1` |
| Installed build-package inventory | 415 identical rows; aggregate `e804fc92fca56c60acce5018da07c6c4b4298d4107856a9a969c45b0f27e374f` |

The identical installed-package inventories establish what this pair actually
used. They do not make those packages retrievable later because their repository
URLs and downloaded `.deb` hashes were not fixed in the old manifest.

### Ordered patch identity

| Order | Repository-relative patch | SHA-256 |
|---:|---|---|
| 1 | `patches/jglathe-qcom-x1e-7.2-rc5/0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch` | `16afa251fd448b204d5d1bf80605edc58fd30e6bb899a55084abd36d5dd759d8` |
| 2 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0001-arm64-dts-qcom-x1-denali-use-2.4-MHz-DMIC-clock.patch` | `333a168c3941b804aa87803b435ac4b3dbf023e5a09e2abcf43327a89dfad9e8` |
| 3 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0002-arm64-dts-qcom-x1-denali-enable-mshw0485-touchscreen.patch` | `92aac884bb3791e15abf33ff09a6669e93f320c1a96c9a9f3b4047c41d385293` |
| 4 | `patches/sp11-qcom-x1e-7.2-rc5-v3/0003-debian-qcom-x1e-name-SP11-v3-build.patch` | `3fa309d079f8cbee7b6a4abe4a4705f485bbd5c3518920bdb4753b2d775a4431` |
| — | Ordered path-and-digest listing aggregate | `03557f49985d92a40b3ebae159ff3345e63d56a97b58cda3d1a0848302aa669d` |

## Raw package result: fail

Every emitted package differs byte-for-byte. Sizes are decimal bytes.

| Package role | Build A SHA-256 | A size | Build B SHA-256 | B size | Raw result |
|---|---|---:|---|---:|---|
| ARM64 headers | `e4fa77c90e95c3a36c15dca304521f5c3b7f694697ccb25f7c1baa4ea933aa63` | 1,431,262 | `e4101b608146915843ff96905943f56e3258b15100445671e268c72a1ee0b22e` | 1,430,668 | Different |
| Image package | `c1c7c056d81ab7f55b569ae8db4c6db01743bb1b20fd0e9f6fcecd7cce339812` | 164,032 | `125f94aa247ed32a720d630443ccffca3f6d9856f556877c19693dcf445b7ac0` | 164,032 | Different |
| Modules package | `4209f6aa05bdba18e9f40fcebf7d9a5b1cf6f223ae436c452d33a1329c80970f` | 306,821,312 | `0ff61e491bca4106d3d252f74ea6b6ab58f8165220cac85c2dd6006c1e42abc0` | 306,811,072 | Different |
| Common headers | `c1ff51eae8eabce0737b73aa09204c6ef78a69ccbb693397a9658858e3dcae46` | 15,167,686 | `b560c6f435cb31f3ad736d63809f3eaef9d2708267503b581b2359e6a0953d62` | 15,168,272 | Different |

The Debian archives nevertheless have identical member names and path sets,
file types, modes, numeric and named ownership, symlink targets, and hard-link
targets. Extracted differences are bounded as follows:

| Package role | Extracted comparison |
|---|---|
| Common headers | File contents are exact; archive member mtimes differ. |
| Image package | File contents are exact; archive member mtimes differ. |
| ARM64 headers | `compile.h` embeds the transient build host; derived `md5sums` and archive mtimes differ. No other content difference was found. |
| Modules package | Differences are limited to `vmlinuz`, appended module signatures, derived `Installed-Size`/`md5sums`, and archive mtimes. |

This extracted equivalence explains the package differences; it does not turn
the raw package result into a pass.

## Patched source, configuration, and DTBs

The read-only source-volume audit produced the same evidence for both builds.

| Evidence | A/B result |
|---|---|
| `git rev-parse HEAD` | Exact: `8f953dd060bc6e8fb86ca2ea8a92f258141c0169` |
| Tracked-status inventory | Exact: `a49adec7c893009ee2f3fb7246284b1db1e8329638053ea2921c479f9d706d3e` |
| `git diff --binary --full-index HEAD` | Exact: `96004d57880b7827537f90c8820cdd46a9687519d669342f81d39e73d4b4c02b` |
| `git diff --check` | Pass in A and B |
| Modified paths | Exact: `arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi`, `debian.qcom-x1e/changelog`, and `debian.qcom-x1e/config/annotations` |
| Kernel `.config` | Exact: `6a878782b69c54e7408e3f29140b83868036aac7317b6201c012aaa443dc48de` |
| `System.map` | Exact: `d8d42d75f3e6e3613756c7cbee0455cfd2aec8e7882fa902fcd5b65ce0691347` |
| All 1,792 packaged DTBs | Exact aggregate: `d41b7c27e7e58eb307494f0add22d8fab8383d2ddf13c173901908a2d53b95a6` |
| Surface Pro 11 OLED DTB | Exact: `360f1b9ef87e3de33e6eeeb6fb8179abd385807860e0d177ab4d57cea9d68f7b` |
| All 38 Stubble-embedded `.dtbauto` DTBs | Exact aggregate: `1c9fb2a76004df732437ccf59bd18727b04daf13a7ab35fff562a0e93ca41a53` |

The packaged Surface Pro 11 OLED DTB is byte-identical to embedded `.dtbauto`
index 7 in both builds.

## Kernel and Stubble image evidence

| Layer | Build A | Build B | Result |
|---|---|---|---|
| Whole `vmlinuz` | `0b360ef2a7ca504c84b1a0098434d0a14f8b318bf5682d087cc9baa7063daf23`, 22,639,104 bytes | `b5abab7c999be7f44d8c9b22f68e4550ed3aa240211423a96bf88492c19e70ce`, 22,639,104 bytes | Different; only the outer `.linux` section differs |
| Decompressed kernel Image | `dbe9b0df33ecfd65a7c058d3cadf1431d8fa4456aa38d6e57886c9e5c86cecb7`, 53,936,128 bytes | `70c8a1027ad99268b6a0bc1332d4320e074e7ccf0b99ddc7269fba478312bb07`, 53,936,128 bytes | Different, fully classified |
| Kernel `_text.._etext` | `151b8c80bb9bb2cd5b969e3c832aef74b3e1dd24f084f519b3bda408fafa12af`, 28,246,016 bytes | Same | Exact kernel code |
| Normalized kernel Image | `ccdec0fffffa9ee783bc8301187a51e4fd422273fde5f0bfd81e758fe355deb6`, 53,936,128 bytes | Same | Exact after the listed normalizations |

All 1,142 changed bytes in the decompressed kernel Image were assigned to
known build-identity inputs:

| Classification | Changed bytes | Normalization |
|---|---:|---|
| Transient container hostname | 33 | Replace the two build host strings with one canonical fixed-width value. |
| Wall-clock timestamp digits | 8 | Replace timestamp digits with one canonical build timestamp. |
| Autogenerated X.509 material | 1,069 | Replace the complete generated certificate region with one canonical equal-length region. |
| GNU build ID | 20 | Replace the build-ID note and its copied value with canonical bytes. |
| Built-in cpio mtimes | 12 | Set the affected newc header mtime fields to one canonical epoch. |
| **Total** | **1,142** | **No changed Image byte remains unclassified.** |

These substitutions are an audit normalization, not a reconstructed release
artifact. They are valid for proving that this pair has no other Image payload
difference; they are not a reason to publish either raw Image as reproducible.

### zboot nuance

The zboot wrapper's executable bytes are **not** byte-exact. Build B's
compressed payload is seven bytes shorter. That length change produces exactly
265 changed relocation-immediate words: 263 `ADD` immediates and two `LDR`
immediates. The opcode and register-selection bits remain identical, and the
audit found zero unknown wrapper changes.

The correct conclusion is therefore:

- the kernel's `_text.._etext` code is exact;
- every inner Image difference is classified and the normalized Images are
  exact; and
- zboot relocation immediates differ in a fully classified way.

It would be incorrect to summarize this as "all executable sections are
exact."

## Module evidence

Both builds contain the same 7,814 module paths: 7,729 modules carry an
appended signature and 85 are unsigned. Every signed raw module differs because
each build generated different signing material.

The audit located the kernel marker `~Module signature appended~`, parsed the
preceding module-signature descriptor, validated its big-endian signature
length and optional signer/key-ID lengths, and removed exactly that described
trailer. It did not truncate a hard-coded number of bytes.

| Module comparison | Result |
|---|---|
| Signature-stripped signed modules | 7,728 exact; only `kheaders` differs |
| All non-`kheaders` module payloads | All 7,813 exact; aggregate `0c36587d0153d65abf2586d98c0c3119516c610cc8722f144eefaa5cc65e4c67` |
| `gpi` unsigned payload | Exact: `8e5a3f561dfd4e0f2d66612e84408c90dae3fcf022c9c31bc2120083bfa11664` |
| `spi-geni-qcom` unsigned payload | Exact: `4ed669b472ae1b0fd5c859602c239c3bd8043e51924bdb3c874cd7da8ed775ae` |
| Normalized `kheaders` archive | Exact aggregate: `6c5c0dac76be29dfc9a67006da6aeb5101691dc7275fca7821edaa93091065d0` |

The `kheaders` difference is limited to the `compile.h` host identity, embedded
archive mtimes, and the layout/build-ID values derived from those inputs. After
canonicalizing those fields and rebuilding the path-qualified archive
inventory, no difference remains.

## Machine-verifiable historical comparison

The checked-in comparator emits `sp11-kernel-adjacent-comparison-v1` under the
`sp11-kernel-historical-semantic-v1` policy. Run the complete retained-artifact
gate from the support repository root:

```bash
python3 ./tests/test-sp11-kernel-build-comparison.py --require-real
```

This command fails if either retained directory is absent, runs the hostile
parser fixtures, scans the complete A/B pair twice, and requires deterministic
path-neutral output. The underlying report can also be generated directly:

```bash
python3 ./scripts/compare-sp11-kernel-builds.py \
  --build-a build/phase0-repro-a-f93fe57/artifacts \
  --build-b build/phase0-repro-b-f93fe57/artifacts
```

The policy is deliberately limited to this historical pair. Before parsing any
Debian archive, it binds every role and side to the exact filename, byte size,
and SHA-256 recorded above on retained no-follow descriptors. Parsing then
confirms the expected package name, version, and architecture on those same
bytes. A/B order is part of the policy, so swapped inputs fail. Future pairs
require a reviewed, versioned policy and allowlist rather than expansion of this
historical result.

`Installed-Size` is checked independently against each package data inventory:

```text
int(Installed-Size) -
sum(ceil(each regular data-member size / 1024))
```

The reviewed residuals are 4,112 KiB for common headers, 456 KiB for ARM64
headers, 17 KiB for the image package, and 1,415 KiB for modules. Each residual
must match on both sides; equal apparent data size also requires equal
`Installed-Size`.

The comparator labels its new aggregate encoding as
`sp11-path-inventory-json-lines-v1` and separately carries the four published
historical aggregate values as exact-pair-bound references. The local retained
gate asserts both sets. Repository CI runs only `--synthetic-only`, because the
large retained Debs are not committed; a green CI run is parser/policy fixture
evidence, not a rerun of the historical pair.

## Original build reproduction command

Run the following from the support repository root at commit
`f93fe57c0b7d8cb396168a0d7ba4547a5d91f25a`. Run it once with `RUN_ID=a` and
once with `RUN_ID=b`. Each named Linux work volume must be absent before its
run; do not reuse a prior build volume.

```bash
RUN_ID=a

./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.2-rc5-jg-0 \
  --expected-source-commit 8f953dd060bc6e8fb86ca2ea8a92f258141c0169 \
  --image ubuntu:26.04@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03 \
  --platform linux/arm64/v8 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir "build/phase0-repro-${RUN_ID}-f93fe57" \
  --linux-work-volume "sp11-qcom-x1e-phase0-repro-${RUN_ID}-f93fe57" \
  --reset-source \
  --jobs 8
```

The public comparison procedure is intentionally path-relative. Its command
categories and invariants are:

```bash
# Raw records and packages
sha256sum build/phase0-repro-*/docker-build-args.txt
sha256sum build/phase0-repro-*/docker-build-inside.sh
sha256sum build/phase0-repro-*/artifacts/*.deb
sha256sum build/phase0-repro-*/artifacts/sp11-kernel-build-manifest.txt
sha256sum build/phase0-repro-*/artifacts/sp11-kernel-debs.txt

# Patched source, run once inside each read-only mounted source volume
git rev-parse HEAD
git status --short --untracked-files=no
git diff --binary --full-index HEAD
git diff --check

# Debian archive structure; compare sorted listings and extracted trees
dpkg-deb --ctrl-tarfile <package.deb>
dpkg-deb --fsys-tarfile <package.deb>

# ELF and PE payload inventory; use the matching LLVM/binutils tools
readelf --wide --sections <elf-file>
objcopy --dump-section .linux=<linux-payload> <vmlinuz>
```

For the last three categories, a reproducible implementation must additionally:

- hash sorted `path`, `type`, `mode`, `uid`, `gid`, owner/group name, link
  target, size, mtime, and content-digest records from both Debian tar streams;
- enumerate and hash every packaged DTB and every numbered Stubble `.dtbauto`
  section;
- decompress `.linux`, locate the ARM64 Image and `_text.._etext` bounds from
  the matching symbols, and compare both raw and normalized bytes;
- decode each changed zboot instruction and compare opcode/register bits
  independently of relocation immediates;
- strip module signatures only after validating the trailer marker and parsed
  descriptor lengths; and
- extract the `kheaders` archive, normalize only `compile.h` identity and
  archive mtimes, then recompute a sorted path-qualified inventory.

A comparison implementation must stop on an unknown path, member type, section,
instruction change, signature layout, or payload byte. Adding a new
normalization after seeing a difference requires review; it must not silently
convert a failure into a pass.

## Build warnings retained for follow-up

Both build logs contain the same two tolerated warning classes:

- Stubble's `readelf` non-ELF fallback while examining the PE image; and
- the packaging path's empty-`$ko` `readelf` warning.

Neither warning explains an A/B delta, and neither was treated as an unknown
payload difference. They remain defects to track rather than warnings to omit
from release evidence.

## Why immutable future replay is not proven

Pinning the OCI index fixes the initial container filesystem, but the build
executes `apt-get update` and installs dependencies from mutable Ubuntu
repositories. The pair happened to resolve the same 415 installed packages;
the old manifest cannot require that set again after repository publication
changes.

The old manifest also omits evidence that was recovered separately for this
audit: the support commit, its dirty-state decision, ordered patch identities,
the patched-source diff digest, script hashes, and the generated signing
certificate's identity. A matching legacy manifest hash therefore does not
fully identify the build.

## Immutable-APT replay implementation and later verification

The release-mode Docker wrapper has a fail-closed P0.4c implementation. This
was not used by builds A and B and is therefore not evidence that those
historical package bytes can be replayed.

The new path pins the direct dated Ubuntu snapshot
`https://snapshot.ubuntu.com/ubuntu/20260807T000000Z/`, the Ubuntu archive
keyring hash and signing fingerprint, and the four exact `InRelease` hashes in
`config/kernel-baselines/7.2-rc5-jg-0.env`. It requires the reviewed suite order
`resolute`, `resolute-updates`, `resolute-backports`, `resolute-security` and
all 32 component/index combinations: four components times binary ARM64 and
source indexes times four suites.

The digest-pinned minimal image has no usable CA bundle at first boot. The
bootstrap therefore permits a TLS peer-verification exception for one bounded
bootstrap phase only: a metadata update followed by a download-only install.
It verifies the signed `InRelease` identities before installing the four exact
hash-pinned CA/OpenSSL packages, clears the lists, and then repeats the update
with strict HTTPS. Every selected gzip index is fetched through its signed
by-hash URI and retained. Six positive-size `resolute-backports` gzip indexes
in the pinned snapshot have an authenticated decompressed payload of exactly
zero bytes, so the pinned APT does not emit local list views for them. The
baseline binds their exact paths and compressed identities. Acquisition and
finalization require those six views to remain absent, require views for the
other 26 indexes, and cross-check every emitted view against its signed gzip
payload. No placeholder list files are created.

Every cached `.deb` is authenticated directly from the retained signed
`Packages.gz` records. Identical records in `-updates` and `-security` are
accepted only when their size, hash, and archive filename agree; all matching
signed binary-index locations are recorded. Conflicting records fail. The
sidecar also binds the exact pre/post installed-package inventories, retained
list targets, the complete downloaded-Deb lock, and the generated local
build-dependencies Deb.

A successful release-mode build must produce these three provenance artifacts
under its artifact directory:

- `sp11-kernel-build-manifest.txt` (`sp11-kernel-build-v2`);
- `sp11-kernel-apt-provenance.txt` (`sp11-kernel-apt-provenance-v1`); and
- `sp11-kernel-build-inputs.txt` (`sp11-kernel-build-inputs-v1`).

The outer envelope binds the raw OCI index and unique ARM64 child, generated
Docker argument and entrypoint files, the schema-v2 manifest, and the APT
sidecar. Host-side validation independently re-hashes the retained snapshot
metadata, indexes, lists, Debs, local build-dependencies package, and package
inventories before and after envelope creation.

On 2026-08-08, one fresh release-mode build completed this path at support
commit `8110b2933beca73e2046f706f1299553906ff30d`. Independent host validation
accepted the retained v2 manifest, v1 APT sidecar, v1 build-inputs envelope,
32 authenticated indexes, 31 exact list targets, 334 cached Debs, pre/post
inventories of 87/415 packages, and all copied kernel-package identities. The
exhaustive module scan recorded 7,814 modules: 7,729 marker-signed and 85
unsigned. The exact hashes and bounded claim are in the
[2026-08-08 immutable-build evidence](sp11-kernel-immutable-build-evidence-20260808.md).

P0.4c is therefore **complete for one real immutable-input build**. The current
release/image preparation paths validate and attach the exact v2 manifest, v1
APT sidecar, and v1 build-inputs envelope, then attest their propagation in
outer manifests. The envelope's literal incomplete state remains unchanged as
a build-time fact. Publication remains closed because byte reproducibility,
the release-signing model, independent licence/UCM gates, recovery/hardware
evidence, corresponding-source/release-candidate review, and explicit release
authorization remain open.

## Required remediation before a byte-reproducible claim

1. Set `SOURCE_DATE_EPOCH` from a reviewed immutable source timestamp and set
   stable `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`, and
   `KBUILD_BUILD_TIMESTAMP` values. Normalize Debian and embedded archive
   mtimes from the same epoch.
2. Adopt an explicit release-signing model. Either use a controlled release
   certificate through a reproducible signing process or keep unsigned build
   payload production separate from release signing. Never generate an
   unrecorded ephemeral certificate while claiming byte reproducibility.
3. Preserve the completed 2026-08-08 real-build result and its exact attached
   trio as immutable-input provenance evidence. Do not treat the single run as
   a byte-reproducibility result or publication authorization.
4. Retain the schema-v2 manifest's existing support HEAD/dirty-state, ordered
   patch, patched-tree/diff, exact source, output, and certificate bindings.
   Retain the current outer-schema propagation of the v1 envelope's OCI-child,
   APT, and generated-control identities, and add the genuinely missing raw and
   normalized comparison hashes needed for a byte-reproducibility decision.
5. Version the comparison and normalization specification. Preserve the raw
   artifacts and raw hashes alongside normalized evidence so later reviewers
   can reproduce every classification.
6. Repeat two clean builds after those changes. Require identical raw package
   hashes for a byte-reproducible pass, and retain the semantic audit as an
   independent defense against accidentally identical packaging of incorrect
   content.

## Gate conclusion

The A/B pair demonstrates that the patched source state, configuration,
`System.map`, all packaged and embedded DTBs, kernel code, and all non-`kheaders`
module payloads are equivalent. The remaining payload differences are fully
classified, and the audit found zero unclassified bytes.

It also demonstrates that the current recipe is **not byte-reproducible**:
package bytes, raw signed modules, `vmlinuz`, the raw inner Image, and classified
zboot relocation immediates differ. The mutable APT dependency source used by
this historical pair means its future replay is not immutable even though the
two adjacent installed inventories match. A newer immutable-input path has
completed one separately recorded real build, but that cannot change the
historical pair's inputs or byte result.

P0.4 remains open overall. Its P0.4a historical semantic-evidence facet is
complete; P0.4b remains open because all four package byte identities differ;
and P0.4c is complete for one real immutable-input build. Publication remains
blocked on byte-reproducibility remediation, signing, the independent
licence/UCM gates, corresponding-source and release-candidate review,
recovery/hardware evidence, and explicit release authorization even though
outer-schema propagation is implemented. The historical semantic result and
the later immutable-input result support continued non-release development
only; neither is release authorization or proof that the historical A/B pair
can be replayed immutably.
