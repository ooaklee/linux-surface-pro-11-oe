---
id: adrs-adr022
title: "ADR022: Privileged Windows collection and controller authority"
description: Architecture decision for protected Windows collection transactions and physical Surface Pro 11 Bluetooth controller selection.
---

## Status

Accepted on 2026-08-30.

## Context

The Windows hand-off collector runs with administrator rights because it must
query active DriverStore packages and copy protected firmware. An output path
is therefore a privileged boundary, not a convenience parameter. If an
unprivileged process can replace a parent or staging directory with a junction,
symbolic link, mount point, or other reparse object between checks, an elevated
collector could disclose private material, overwrite an unrelated path, or
delete content outside its transaction during recovery. FAT and exFAT do not
provide the required Windows access-control contract, and a network share adds
an independently mutable namespace.

Bluetooth controller numbering is also not physical identity. An attached USB
radio can enumerate as `hci0`, while the built-in controller receives another
index. Windows friendly names and localised descriptions are likewise
unsuitable authority. A registry address without a proven relationship to the
built-in radio could describe another controller.

The physical identifiers used by the collector were checked against the
official [Surface Pro 11 drivers and firmware
package](https://www.microsoft.com/en-us/download/details.aspx?id=106119). The
reviewed package evidence is:

| Evidence | Reviewed value |
| --- | --- |
| Installer | `SurfacePro11_ARM_Win11_26100_26.041.12746.0.msi` |
| Microsoft page update date | 2026-06-24 |
| Installer size | 646807552 bytes |
| Installer SHA-256 | `0c3966bb6f3d39673ae3d2bbd785967d36db149e6c0fa8baa5fa3abd4ccd249b` |
| Radio INF | `qcbtaddvscregistry8380.inf` |
| Radio INF SHA-256 | `efd7191ba8a6e8b666cb14df95f36984eb8e19b48711815fc38e363a9acde92a` |
| Radio hardware ID | `QCA_SHB\UART_H4_HMT` |
| Transport INF | `qcbtacx_transportdriver8380.inf` |
| Transport INF SHA-256 | `2b449383a1d988f0aee1769bf646fc24fcb53d2b18d03726d15f29d058760aad` |
| Transport hardware ID | `ACPI\QCOM0D04` |

These hashes identify the evidence reviewed for this decision. They are not a
claim that every future Microsoft package will have the same bytes. A changed
package requires the identifiers and their provenance to be reviewed again
before compiled policy changes.

On Linux, the Surface Pro 11 device tree places the Bluetooth child beneath
the UART and gives it the exact compatible string `qcom,wcn7850-bt`. The
kernel's HCI serdev registration makes that serdev object the HCI device's
parent. Consequently, the class entry's `device/of_node/compatible` property
is physical device-tree evidence which does not depend on its `hciN` number.

## Decision

The collector accepts an output only as a new direct child of a
pre-provisioned parent on a ready local NTFS filesystem. The parent must have a
protected DACL, be owned by Local System or the built-in Administrators group,
and contain only explicit inheritable Full Control entries for those two
principals. A fixed or removable local NTFS volume can satisfy the mechanism,
but the operating procedure creates the protected parent directly beneath the
stock `Program Files` directory on a fixed local volume, then copies the
completed child to trusted removable storage afterwards. The stock
`ProgramData` ACL grants Users write-attribute and write-extended-attribute
access which the ancestor policy rejects. Network, FAT, exFAT, permissive, and
already existing output destinations are rejected.

Every ancestor from the filesystem root to the protected parent must be a
non-reparse directory with a trusted owner. An access rule for any other
principal must not grant the redirect, deletion, ownership, or security-control
rights that could exchange the privileged path. The collector opens each
boundary object with `FILE_FLAG_OPEN_REPARSE_POINT`, records its volume and file
identifier, and checks that identity again after access-control inspection.

Collection uses an unpredictable sibling staging directory beneath the
verified parent. The staging directory receives the same exact private DACL,
and the retained parent and staging identities are rechecked around every
sensitive write, validation, and publication boundary. Files are created
without replacement. The complete closed directory is validated before a
same-parent directory move publishes it under the requested new name; an
existing or newly appeared destination is never merged or overwritten.

Failure recovery enumerates one directory level at a time. It rejects reparse
objects before descent, removes a reparse object itself without visiting its
target, and checks the retained staging identity throughout cleanup. It does
not invoke recursive provider deletion over an unchecked path. If identity
cannot be proved, cleanup stops and preserves the staged object for deliberate
inspection.

Windows Bluetooth collection requires exactly one present physical radio with
the exact `QCA_SHB\UART_H4_HMT` hardware ID and an immediate parent transport
with the exact `ACPI\QCOM0D04` hardware ID. Software enumerators are not treated
as physical candidates. An external or otherwise ambiguous physical radio
causes collection to fail closed.

The default Bluetooth address source is a network adapter's structured
`PermanentAddress`, never its current address or display name. Its PnP parent
chain must reach the exact built-in radio, and exactly one eligible result is
required. The optional `-UseBTHPORTRegistry` path remains an operator-requested
corroboration: exactly one valid local BTHPORT controller-address key must
equal that independently correlated `PermanentAddress`. A BTHPORT value alone
never gains authority.

Linux application stores the compiled controller selector
`surface-pro-11-wcn7850-uart`, not a numeric HCI index. The bounded selector
scans `/sys/class/bluetooth/hciN`, reads each
`device/of_node/compatible` property, and compares its NUL-delimited tokens
exactly with `qcom,wcn7850-bt`. An external controller cannot acquire authority
by enumerating first. No match times out without issuing an HCI address
mutation, and more than one matching built-in candidate fails immediately as
ambiguous.

Windows and Linux therefore establish physical controller authority
independently from platform-native evidence. The hand-off does not export a
raw Windows PnP identifier or claim a cryptographic Windows-to-Linux controller
binding; the salted SMBIOS product UUID remains the same-device boundary for
application.

## Consequences

- Operators must create one exact protected NTFS parent before collection and
  must choose a new child name for every run.
- Portable transfer occurs only after the protected transaction has published
  a complete child. The transferred directory remains private even if the
  removable filesystem cannot preserve Windows ACLs.
- A permissive destination is refused instead of being made temporarily safe
  after privileged files have become visible.
- Attached or ambiguously identified Windows Bluetooth radios block collection,
  while a Linux external radio is ignored rather than being selected by index.
- The compiled hardware identities and device-tree selector are reviewable,
  versioned policy rather than user-supplied paths or friendly names.
- Windows CI exercises the accepted protected-parent ACL, unsafe owner and
  access-rule rejection, retained identity drift, destination collision,
  no-follow cleanup, and the portable contract checks. Host-independent tests
  cover contract shape, selector parsing, and ambiguity handling. Collection
  on supported Windows hardware, transfer, Linux application, address
  programming, cold boot, and restoration on the same physical Surface Pro 11
  remain release gates.
