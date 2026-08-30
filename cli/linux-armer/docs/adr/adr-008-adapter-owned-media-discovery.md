---
id: adrs-adr008
title: "ADR008: Adapter-owned live-media discovery"
description: Architecture decision for keeping distribution-specific live-media discovery explicit and structurally verifiable.
---

## Status

Accepted on 2026-08-30.

## Context

Firmware and GRUB can load a kernel and initramfs without proving that the
distribution's live-boot implementation will rediscover the physical medium.
Ubuntu Casper, Fedora dracut, Debian live-boot, and raw installed-root images use
different command-line, identity, filesystem, and partition contracts.

The Ubuntu Concept initramfs contains a Casper UUID in `conf/uuid.conf`. Casper
accepts a directly written hybrid ISO only when that value agrees with
`.disk/casper-uuid-generic` on the medium. Regenerating the initramfs creates a
new UUID. Retaining the source ISO marker therefore makes Casper reject the
correct USB device even though GRUB loaded the kernel from it successfully.

The earlier raw-image workflow uses a different topology: an ISO file resides
on a labelled outer filesystem and GRUB opens it through a loopback device.
That layout correctly requires Casper's `iso-scan/filename` argument because
the Linux kernel cannot inherit a GRUB loopback device. Applying the same
argument to an ISO written directly to USB would describe a file that does not
exist.

## Decision

Each distribution adapter will own its live-media discovery strategy. Shared
image orchestration will carry the selected strategy and its evidence in the
single ISO manifest, but it will not invent Casper, dracut, live-boot, or
installed-root arguments.

The Ubuntu adapter's direct-hybrid strategy will use a dedicated `caspermedia`
package. After Ubuntu's own `mkinitramfs` creates the live initramfs, the adapter
will extract and validate its canonical UUID, write the same value to
`.disk/casper-uuid-generic`, update Ubuntu's compatibility checksum list, and
record both identity paths and the value in `media_discovery` in the ISO
manifest.

The Ubuntu structural validator will unpack the completed initramfs and require
exact agreement between its UUID, the medium marker, the marker's manifest
digest, and the manifest identity. It will also verify Casper's default boot
mode and live-layer target. Direct-hybrid GRUB entries must not contain
`iso-scan/filename` or `ignore_uuid`. A labelled outer filesystem containing a
nested ISO remains a separate adapter-owned strategy.

Every live-USB menu entry will retain the temporary
`modprobe.blacklist=qcom_q6v5_pas` safeguard. The menu will not offer an aDSP
entry that removes this protection; normal aDSP operation remains available to
the installed system, where the live-media safeguard does not apply.

Future distribution adapters will implement and validate their native strategy
without importing Ubuntu values into shared code. Raw disk images will continue
to use a separate adapter because their partition and installed-root semantics
differ from live ISO discovery.

## Consequences

- A remastered Ubuntu ISO cannot be published when its initramfs and physical
  medium identities disagree.
- Validation now covers the hand-off from GRUB to the distribution live-boot
  implementation rather than only checking that boot files exist.
- Direct and nested ISO layouts remain distinct, preventing a superficially
  similar but incorrect kernel argument from leaking between them.
- Fedora, Debian, elementary OS, and Pop!_OS can add their own discovery
  strategies without changing the Surface kernel-bundle contract.
- A structurally valid strategy still requires a boot on the target device as
  the final hardware gate.
