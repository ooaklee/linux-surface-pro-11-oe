---
id: adrs-adr013
title: "ADR013: Private hand-off application transactions"
description: Architecture decision for same-device application, recovery, firmware policy, and private Bluetooth boot integration.
---

## Status

Accepted on 2026-08-30.

## Context

ADR011 defines a private, device-bound Windows hand-off and deliberately withholds mutation authority from import, list, and purge operations. Applying that material is a separate security boundary. It can overwrite firmware used during boot, retain a persistent Bluetooth controller address, install an executable with system privileges, and alter systemd ordering. A valid imported document therefore cannot be treated as sufficient authority to modify either the running system or a mounted target.

The identity source and installation target are also different concepts. An operator may use the running Surface Pro 11 identity while preparing an installed root or live USB mounted elsewhere. Reading identity from the target would either fail for an offline root or allow target-controlled content to impersonate the physical device. Conversely, using the running filesystem as an implicit target would make an otherwise read-only inspection unexpectedly dangerous.

Filesystem replacement is atomic for one same-filesystem rename, but an eleven-file firmware policy and Bluetooth integration span several directories and cannot be one filesystem-wide atomic operation. The workflow needs a durable recovery model that remains safe after cancellation, process termination, or power loss without weakening path confinement or trusting a partially written journal.

## Decision

The `handoff application` domain will own planning, application, and restoration. Cobra will expose this as `handoff apply <id>` and `handoff restore <receipt-id>` while keeping the raw Bluetooth boot entry point hidden. Delivery code parses selectors and renders redacted results; it does not acquire private payload values or construct target paths.

Every application starts with complete private-store revalidation. The selected identifier must still name one direct content-addressed child whose manifest, declared payloads, permissions, inventory, sizes, and SHA-256 values match the closed-set contract. The domain then reads the SMBIOS product UUID only from an explicit identity root, which defaults to the running root, and re-derives the contract's domain-separated salted binding. It compares the derived binding in constant time and never returns, logs, or retains the raw UUID. The target root is a separate mandatory argument, including when the intended target is `/`.

Planning is read-only and does not require elevated privilege. An empty feature selection means every section included in the hand-off; repeated explicit selectors allow firmware or Bluetooth to be applied independently. Selecting an absent section fails rather than silently omitting it. Firmware selection also requires one explicit aDSP policy: `enabled` places the aDSP DTB at the installed-NVMe path, while `disabled` places it at the live-USB-safe inactive path. The mutually exclusive counterpart must be absent.

The plan contains only the public content address, resolved roots, selected features, compiled destinations, object kinds, whether each change is required, the host-helper compatibility result, and opaque digests. Its digest binds the complete revalidated private closed set, explicit roots, selected policy, exact desired bytes, and a private observation of every current target object. Current regular files are bound by type, mode, size, and complete SHA-256; symbolic links are bound by an opaque digest of their target; absence has a distinct value. The exact confirmation phrase includes the hand-off ID, plan digest, and resolved target root. Replanning immediately before mutation rejects a changed store, identity, executable, policy, or target even when both old and new target objects would merely appear as “change required”.

Mutation requires effective root, but a dry run and an already-satisfied idempotent reapply do not. Target access uses descriptor-confined filesystem operations. Final symbolic links are inspected without following them, intermediate links cannot escape the selected root, special files and unbounded originals are rejected, and all destinations come from compiled policy rather than contract-provided paths.

Firmware application is an all-or-nothing policy of eleven validated records. Each payload is reopened through the revalidated private-store handle, copied through a bounded reader, and checked again for exact size and SHA-256 before publication. Regular firmware files use mode `0644`. The workflow also manages the fixed Denali GPU compatibility link and the selected active or inactive aDSP path. Explicit omission of firmware grants no authority over any firmware destination.

Bluetooth application writes a fixed mode-`0600` private configuration, copies the current Linux ARM64 `linux-armer` ELF executable to a fixed mode-`0755` libexec path, writes a fixed mode-`0644` systemd oneshot unit, and installs its fixed dependency link before `bluetooth.service`. Planning may report an incompatible development-host executable, but mutation rejects it. The unit reads the private configuration from its fixed path; neither the address nor an address-bearing command line is placed in the unit, process arguments, ordinary output, JSON, or errors.

The hidden boot entry point uses a native Linux package rather than invoking `btmgmt` or a shell pipeline. It waits for only the selected `hciN` controller within a compiled deadline, opens a fresh close-on-exec raw `AF_BLUETOOTH` management socket for each bounded retry, sets a receive timeout, sends only `MGMT_OP_SET_PUBLIC_ADDRESS`, and accepts only a matching command-complete or command-status event. It never formats or logs the address.

Before the first target replacement, the application writes a private mode-`0600` receipt beneath a fixed mode-`0700` directory. The receipt records the compiled action set, desired fingerprints, safely inspected original fingerprints, same-parent staging and backup names, created directories, and transaction state. It is private operational recovery data and is never embedded in an ISO, returned as JSON, or treated as a public manifest attribute.

Each changed object is staged and flushed in its destination directory. Any original regular file or symbolic link is moved to a deterministic same-parent quarantine name, the directory is synchronised, the journal is updated, the desired object is renamed into place, and both target and journal are synchronised again. Successful completion revalidates the private source closed set, verifies every selected final object, and marks the receipt committed. Reapplying an already satisfied policy is a no-op.

An in-process failure triggers bounded reverse-order rollback. Recovery verifies the current desired object and every retained backup against the private receipt before removing or renaming anything; it restores original modes, bytes, links, or absence and removes only empty transaction-created directories. `handoff restore` provides the same path after interruption. Its read-only plan strictly decodes the receipt, checks the complete action allow-list and deterministic transaction paths, reconciles safe crash windows from observed targets, backups, and staging objects, and produces a new receipt-, recovery-, and target-bound confirmation. Restoration mutation also requires effective root and is idempotent.

This is a recoverable multi-object transaction, not a claim of filesystem-wide atomic visibility. Another privileged process must not concurrently modify compiled destinations during application or restoration. Repeated observations narrow that race, while any mismatch fails closed and retains the receipt and backups for review rather than deleting an unrecognised object.

## Consequences

- Import remains non-mutating and does not implicitly authorise application.
- One same-device private hand-off can support an installed system or a mounted live USB without trusting the target for physical identity.
- Distribution-independent delivery can select firmware and Bluetooth separately while the Surface Pro 11 destination policy stays compiled and reviewable.
- Live-USB and installed-NVMe aDSP behaviour becomes an explicit reviewed choice rather than a GRUB-entry side effect.
- The Bluetooth address remains outside shell history, systemd arguments, public manifests, diagnostics, and command output.
- Dry runs are useful on non-Linux development hosts, but Bluetooth mutation must run from a compatible Linux ARM64 executable.
- A committed receipt intentionally retains backups until an operator chooses restoration or a later, separately designed retention policy; automatic deletion would remove the recovery boundary.
- Power-loss recovery requires an explicit restore operation and exclusive control of the target. The receipt makes this deterministic but cannot make several directory renames globally atomic.
