---
id: adrs-adr020
title: "ADR020: Independent camera authority digests"
description: Architecture decision for non-executable validation of native camera build and release hand-offs.
---

## Status

Accepted on 2026-08-30.

## Context

The native IMX681 build publishes five coherent ARM64 runtime packages, the
original Debian build records and a structured build receipt. The trusted build
workflow can execute its newly built verifier and IPA module on its native
Linux ARM64 builder before publication. A later release or installation command
has a different trust boundary: the supplied directory may have arrived from
another machine and every executable inside it is untrusted until independently
authenticated.

A receipt stored beside the packages cannot authenticate itself. An attacker
who can replace the packages can also replace that receipt and its recorded
hashes. Repeating the build-time proof by executing the directory's
`ipa_verify`, libraries and IPA module would therefore run attacker-controlled
code during validation, including before a privileged installation. Requiring
only a directory path or a self-authored checksum file does not close that
boundary.

## Decision

The trusted camera build retains the complete executable same-build IPA proof.
Before atomic publication, the build manager hashes the exact final
`sp11-imx681-libcamera-build.json` bytes, including their trailing newline.
After publication it reopens the authority and requires its digest and size to
match those private pre-publication bytes before returning `authority_sha256`
in the outer execution result. It never endorses bytes first observed in the
producer-writable final directory. The digest is not written into the build
receipt because doing so would make the authority self-referential.

Every later static build validation requires that independently retained
digest. It first binds the receipt bytes to the supplied value, then repeats
the current support-commit, input, closed-directory, package identity, Debian
record, size and file-digest checks. Static inspection may run only fixed Git
commands and `dpkg-deb` archive-inspection operations. It streams the IPA
package's filesystem archive through a bounded Go tar reader and requires one
regular `usr/share/libcamera/ipa/simple/imx681.yaml` whose bytes match the
authenticated support input. It does not extract a package, execute a package
member, invoke a maintainer script or create a validation workspace.

Local release preparation requires the build authority digest and embeds the
already authenticated build receipt plus its receipt-file digest in the closed
release manifest. It derives the release digest from the private final
`release-manifest.json` bytes before publication and refuses to endorse the
release unless the reopened published authority matches. Release validation
and native release installation require that independently retained release
digest. This creates the following trust chain:

```text
independent release digest
  -> release manifest
  -> recorded build-receipt digest
  -> build receipt
  -> package and Debian-record digests
```

Installing a native build directly uses the shorter equivalent chain beginning
with the independent build digest. The installer performs static validation,
derives the exact five-package order from the authenticated receipt, and hashes
each package again while copying it into a private staging directory. A
privileged installation ignores inherited temporary-directory settings and
uses a mode-0700 random child of a validated, fixed, root-owned sticky parent,
so another user cannot replace package paths before `apt-get` opens them. Only
the explicitly confirmed installation crosses into `apt-get`; validation
itself never executes package payload.

The CLI prints the build digest after a successful build and the release digest
after successful release preparation. Subsequent release, validation and
installation commands require the corresponding explicit SHA-256 option. JSON
output carries the same outer result fields so automation does not need to
parse terminal prose.

The camera build receipt and camera release manifest are userspace provenance
records. They are not additional ISO inventories. An image continues to have
one `*.iso.manifest.json`, whose `companion_bundle` attribute records any
camera-related file only if a future redistribution decision permits that file
to be carried.

## Consequences

- A copied native directory cannot establish trust using only files which it
  carries itself; the operator or automation must retain the printed digest.
- Release preparation and validation no longer require an ARM64 processor or
  execute the same-build verifier, although they still require their fixed
  read-only inspection tools.
- The receipt's successful same-build IPA result remains authenticated
  build-time evidence. Static validation deliberately does not claim to repeat
  that executable proof.
- A package mutation after static validation is detected again during private
  staging before `apt-get` runs.
- Current-support source identity remains bound to the selected repository
  `HEAD`; a future signed-release authority could replace that local hand-off
  requirement only through a separate decision.
- Static package validation still does not qualify camera transport, privacy
  indication, exposure, image quality, browser capture or lifecycle behaviour
  on physical hardware.
