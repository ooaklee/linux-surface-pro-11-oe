---
id: adrs-adr009
title: "ADR009: Default Casper ISO Scan Boot"
# prettier-ignore
description: Architecture Decision Record (ADR) for making the casper iso-scan GRUB entry the default and embedding GRUB fdt support explicitly.
---

## Context

[ADR002](adr-0002-boot-shim-image-strategy.md) chose a GRUB boot shim that
loads the Ubuntu concept ISO from a Linux data partition. [ADR007](adr-0007-auto-dtb-extraction-and-debug-entries.md)
added multiple debug-oriented GRUB entries.

Review after the first successful image build identified that GRUB's loopback
device is not visible to the Linux kernel or initrd. The Ubuntu concept ISO's
native GRUB entry is useful reference material, but our boot shim is different:
it stores the ISO as a file on `SP11DATA`, not as the firmware-visible boot
media.

The same review also noted that the GRUB `devicetree` command depends on FDT
module support.

## Decision

The default GRUB entry will pass:

```text
boot=casper iso-scan/filename=/iso/ubuntu-x1e.iso
```

The ISO-native entry remains available as a fallback, but it is no longer the
recommended first boot path.

The standalone GRUB image will explicitly include the `fdt` module and the
generated GRUB config will `insmod fdt` before calling `devicetree`.

## Consequences

The default path now matches the fact that the Ubuntu ISO is a file inside the
USB data partition.

If Ubuntu's future concept initrd drops casper `iso-scan` support, this entry
will fail early and the ISO-native fallback can still be tested.

The image has one fewer hidden assumption: DTB injection no longer relies on
GRUB module dependency side effects.
