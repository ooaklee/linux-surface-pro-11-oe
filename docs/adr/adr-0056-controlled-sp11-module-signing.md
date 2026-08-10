---
id: adr-0056-controlled-sp11-module-signing
title: "ADR0056: Use Controlled Reproducible Module Signing for SP11 Releases"
# prettier-ignore
description: Architecture Decision Record (ADR) for owner-controlled, reproducible kernel and touchscreen module signing while Secure Boot remains unsupported.
---

# ADR0056: Use Controlled Reproducible Module Signing for SP11 Releases

## Status

Accepted (2026-08-09).

Implementation and hostile-fixture validation are required before the first
fresh release build. This decision does not authorize a tag, GitHub Release,
package, source archive, image, target install, or hardware boot.

## Context

The historical adjacent kernel builds used the kernel's default generated
RSA certificate. Each clean build therefore signed otherwise matching module
payloads with different private material. The resulting module, kernel Image,
and Debian package bytes could not be identical. The later deterministic build
identity and zero-normalization comparator correctly left the signing decision
open instead of normalizing those differences away.

The SP11 release path also builds three exact-ABI touchscreen modules outside
the kernel package build. Those modules were previously unsigned. Treating the
kernel packages and touchscreen bundle as one release candidate requires one
explicit signing identity and independent verification of every appended
signature.

Secure Boot is a separate boot-chain problem. The current Stubble image is not
PE/Authenticode signed, no shim/MOK or UEFI trust-enrollment contract is
implemented, and the recovery matrix has not exercised that path. Module
signing alone must not be described as Secure Boot support.

## Decision

Use signing policy `sp11-controlled-rsa4096-sha512-v1` for release builds.
One owner-controlled RSA-4096 private key and fixed X.509 certificate sign the
kernel modules and the three exact-ABI touchscreen modules. SHA-512 is derived
from and cross-checked against the pinned kernel configuration.

Ubuntu's kernel packaging may deliberately leave a bounded subset of packaged
modules unsigned even when `CONFIG_MODULE_SIG_ALL=y`. Release validation must
cryptographically verify every appended signature against the approved
certificate, enumerate every unsigned packaged module, and bind the sorted
unsigned-path inventory into the C/D comparison and release evidence. An
unsigned path outside that reviewed identical inventory is a blocker. This is
acceptable only because Secure Boot and forced module-signature enforcement
remain disabled for this experimental release class.

The reviewed policy is tracked as
[`config/kernel-signing/sp11-module-signing-allowed-unsigned.txt`](../../config/kernel-signing/sp11-module-signing-allowed-unsigned.txt).
Its 85 sorted, LF-terminated `drivers/staging/` paths have SHA-256
`eb507e006b37ad7d291a37524f3f2f6b5281c5a3f98738dc07056a3ca7cba800`.
The candidate must match that exact set; the allowlist does not turn an
unsigned module into a signed or trusted module.

The private key is encrypted and remains outside Git. It is supplied only to
the supervised build process through a private, read-only mount together with
a bounded PIN file. Host paths, PINs, private-key bytes, and their hashes must
not enter command output, Docker-retained arguments, manifests, APT evidence,
retained build-state archives, source archives, release notes, images, or
release assets. Once Docker has returned and the supervisor has registered a
full immutable container ID, every success, failure, timeout, and handled-signal
path removes that exact container and scrubs the held key and PIN bytes before
dropping their descriptors. Before ID registration, cleanup never deletes by
the mutable random name or label; it preserves a possible stopped orphan while
still scrubbing the creation-owned held bytes. Staged pathnames and the
directory are removed only while their name-to-inode mapping still proves
ownership; otherwise cleanup preserves an unrelated substitute and returns
failure. Refusals before staging authority exists write no private bytes and
never remove a caller-controlled path.

The exact public certificate is committed as
[`config/kernel-signing/sp11-module-signing-cert.pem`](../../config/kernel-signing/sp11-module-signing-cert.pem)
and propagated as DER in release evidence. Its approved identity is:

- DER SHA-256:
  `8ad9b402339b5ceff8e7fc9dfcc7dd368b2466fce0e90d97553059bcdc66e99b`;
- X.509 SHA-256 fingerprint:
  `8A:D9:B4:02:33:9B:5C:EF:F8:E7:FC:9D:FC:C7:DD:36:8B:24:66:FC:E0:E9:0D:97:55:30:59:BC:DC:66:E9:9B`;
- serial: `A48577E23557D28F5963279767D1C038`.

Release mode rejects missing, incomplete, unencrypted, mismatched, weak,
unapproved, or mapping-unstable signing inputs before compilation. It also
rejects an unexpected certificate in the completed build. Non-release
development may retain generated development signing, but no artifact from
that mode is a release candidate.

The controlled build uses the new co-installable package version
`7.2-rc5-jg-0sp11v3r2` and ABI
`7.2-rc5-jg-0sp11v3r2-qcom-x1e`. Historical v3 and r1 package bytes remain
immutable evidence and are never replaced in place.

The touchscreen bundle contains the three signed modules, their public DER
certificate, and a strict manifest. Validators parse each kernel module
signature trailer, reconstruct the exact unsigned payload and detached CMS
signature, verify it with the pinned certificate, and cross-bind the
certificate identity to the kernel build manifest. The private key is never a
bundle member.

Secure Boot remains disabled and unsupported. Release documentation must say
that this policy provides deterministic module identity and kernel/touchscreen
certificate consistency, not firmware trust, PE signing, or key enrollment.

## Consequences

Two clean builds using the same controlled key can be compared as raw package
bytes without treating signature differences as noise. A different or
unapproved key fails before a matched-pair result can pass.

The owner must retain the encrypted private key and PIN in controlled secret
storage and maintain a separately recoverable copy. Compromise or deliberate
rotation requires a new certificate identity, package ABI, reviewed baseline,
fresh C/D pair, and a new release candidate. Published tags and assets are
never rewritten around a replacement key.

The build container is a trusted signing boundary because it necessarily sees
the decrypted private key while signing. Its pinned image, exact entrypoint,
mount topology, process lifecycle, and cleanup remain part of the release
authority contract.

This decision resolves the signing-model choice only. Publication remains
blocked until fresh corrected C/D builds are byte-identical, corresponding
source and release-candidate reviews pass, recovery and hardware evidence is
complete for the declared release class, and explicit artifact-release
authorization is recorded.

## Related

- [ADR-0049: SP11 v3 Touchscreen Kernel Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR-0050: Touchscreen Clean-Install Release Flow](adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [ADR-0051: Release and Tag Cleanup](adr-0051-release-and-tag-cleanup.md)
- [ADR-0052: Thin SP11 Kernel Integration Fork](adr-0052-thin-sp11-kernel-integration-fork.md)
- [ADR-0053: One-Shot Experimental Kernel Boot](adr-0053-one-shot-experimental-kernel-boot.md)
