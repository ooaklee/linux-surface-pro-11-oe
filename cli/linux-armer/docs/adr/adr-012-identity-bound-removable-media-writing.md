---
id: adrs-adr012
title: "ADR012: Identity-bound removable-media writing"
description: Architecture decision for safe cross-platform discovery, exact confirmation, raw writing, and read-back verification.
---

## Status

Accepted on 2026-08-30.

## Context

Writing an installation image to the wrong whole disk is irreversible. A path such as `/dev/disk2` or `/dev/sdb` can be reused after a device is disconnected, storage classifications can change between discovery and opening, mounted filesystems can keep stale data active, and a copy command's successful exit does not prove that durable target bytes match the source.

The image format is a separate concern. Ubuntu Casper, Fedora live media, Debian live-boot, and raw installed-root images need adapter-owned structural validation, but all can eventually reuse the same host removable-device policy. Embedding platform commands or distribution semantics in Cobra handlers would make that policy difficult to test and reuse.

## Decision

A distribution-neutral `media` package will own whole-device discovery, normalisation, immutable planning, privilege gating, unmounting, raw writing, read-back verification, and ejection. Image adapters will continue to own format and live-boot validation. The current `image write` command therefore runs the implemented Ubuntu structural validator before it delegates a generated ISO to `media`, then requires the validator's canonical path, byte length, and SHA-256 to agree exactly with the media plan before confirmation or execution. Future adapters may select their own validator without changing the raw-device manager.

The Darwin backend will obtain a physical-only device set and complete backing graph from `diskutil` property lists converted by `plutil`. It will resolve APFS stores, reject unresolved non-virtual mounts, and mark the physical disk backing any non-removable-style live mount as system storage. Its preparation step asks `diskutil` to unmount the whole disk even when no ordinary mount was reported, so hidden logical consumers must be detached or the operation fails. Only IOKit's persistent media UUID may contribute a Darwin stable identifier; disk-layout and volume UUIDs are content identifiers that may change because of the write and therefore cannot be part of post-write identity. The Linux backend will parse explicit `lsblk --json` columns, require usage evidence for the whole disk and every descendant, preserve major-and-minor identity as session evidence, require hardware WWN or serial evidence for destructive use, aggregate descendant mounts, mark non-removable-style live mounts as system storage, and mark active swap, device-mapper, LVM, RAID, or other non-partition descendants as in use. A filesystem UUID is never treated as Linux hardware identity because the write may replace it, and major-and-minor identity is not considered stable because it can be reused after hot-plug. Neither backend will parse human tables or construct shell command strings.

Discovery may display every physical whole device for operator review, but planning will require all of the following: a canonical whole-device path, external classification, removable classification, USB transport, writable media, positive sufficient capacity, a persistent media identifier, serial number, or WWN, no system backing, no active non-mount storage consumer, and a source image that is neither lexically below nor on the same filesystem as a target mount. A topology path alone is not sufficient because a replacement device can occupy the same port. Missing or contradictory evidence fails closed.

The manager will normalise bounded control-free metadata and issue an opaque fingerprint over stable path, topology, platform identity, capacity, block sizes, transport, and safety classifications. A write plan will bind the canonical regular non-symbolic-link source path, exact byte length, complete SHA-256, complete target snapshot, and the phrase `ERASE <whole-device> DEVICE <opaque-fingerprint> AND WRITE SHA256 <full-digest>`. Editing any field invalidates the plan. Real execution requires that exact phrase; an interactive prompt and `--confirm` share the same comparison, and no blanket affirmative flag exists. A phrase obtained for one USB device therefore cannot authorise another device that later occupies the same path.

Execution will reopen and completely rehash the planned source before any target mutation. It will freshly inspect the planned target and compare the already-open source descriptor with every target mount before checking elevated privilege. It will unmount only the mounts reported for that approved device and then require a fresh unmounted inspection. After opening the raw write path, it will inspect again before sending bytes. Writing uses bounded chunks, checks short and invalid write counts, hashes the exact source bytes as they are written, rejects source growth or digest drift, flushes the target, and treats close failure as failure.

Read-back will use a fresh target inspection before opening, another inspection after opening, and exactly the planned source length. A digest mismatch fails. A final fresh identity and safety inspection is required before `Verified` becomes true and before the backend ejects or powers off the device. `Complete` requires successful ejection. Errors return a partial receipt recording the furthest durable phase, complete byte counts, only complete digests, and whether verification or ejection actually completed. Distinct not-started, prepared, writing, written, verifying, verified, and complete states avoid implying that a raw open, read-back, or ejection succeeded when it did not.

The trusted backend owns the raw-device open boundary. On macOS and Linux it first requires actual ordinary and raw device nodes, proves that their kernel device numbers match, opens the raw node with `O_NOFOLLOW`, and proves that the opened descriptor retains both the inspected raw-node identity and paired kernel device number. This binds macOS `/dev/diskN` discovery to `/dev/rdiskN` I/O rather than relying only on their names. Fresh platform inspection immediately after opening independently checks that the device fingerprint and safety classification still match. Replaceable reader and writer interfaces remain available only at the injected test boundary.

The first production backends are macOS and Linux. Other platforms fail as unsupported while the rest of the command tree and help remain available. A dry run performs validation and planning but never checks privilege, unmounts, opens, writes, reads, or ejects a device.

## Consequences

- The same reviewed removable-device policy can serve future ISO and raw-image adapters without inheriting Ubuntu boot semantics.
- The operator confirms an exact device and exact image rather than a path and a generic affirmative.
- Mounted target volumes can be handled safely only after source-descriptor comparison and privilege, and must be absent at every raw-I/O boundary.
- Success means durable bytes were read back and matched, not merely that a process exited successfully.
- Device hot-swap exposure is narrowed through repeated evidence checks but remains bounded by the operating system and trusted raw-open backend.
- Actual writes still require sacrificial-media and hardware testing on each supported host; parser and in-memory tests do not prove every storage enclosure's behaviour.

## References

- [Apple I/O Kit `kIOMediaUUIDKey`](https://developer.apple.com/documentation/kernel/kiomediauuidkey), which defines the media UUID as a persistent identifier when the device provides one.
- [Apple Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html), for physical media descriptions, bus paths, and I/O Kit media objects.
