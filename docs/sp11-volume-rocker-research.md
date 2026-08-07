---
id: sp11-volume-rocker-research
title: "Surface Pro 11 Volume-Rocker Research"
# prettier-ignore
description: Read-only evidence, open questions, and the hardware gate for a future PM8550 volume-rocker DTS canary.
---

# Surface Pro 11 Volume-Rocker Research

This note records the completed desk portion and unprivileged starting-state
observation for P1.1 of the
[full-feature-parity execution plan](sp11-full-feature-parity-execution-plan.md#p1--volume-rocker-pm8550-gpio-candidate).
The privileged hardware-correlation portion remains blocked. The available
evidence identifies a bounded GPIO candidate; it does not claim that the
mapping, line polarity, or a DTS implementation has passed hardware
validation.

## Immutable evidence

- The pinned Surface Pro 11 ACPI dump at commit
  `1d0a2ce742b450fe3f65287adbe174ddccabe228` exposes device `MSBT` as
  `MSHW0040`. Its `_CRS` resource index 2 is a PM01 `GpioInt` on `0x00d5`, and
  index 4 is a PM01 `GpioInt` on `0x00d7`; both are `ActiveBoth` with pull-up.
  See the pinned [`ssdt.dsl` resource block](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/ssdt.dsl#L637-L706).
- In the pinned Johan G. baseline at
  `8f953dd060bc6e8fb86ca2ea8a92f258141c0169`, Linux's existing
  [`MSHW0040` table](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/input/misc/soc_button_array.c#L582-L590)
  assigns ACPI resource index 2 to `KEY_VOLUMEUP` and index 4 to
  `KEY_VOLUMEDOWN`, with repeat enabled. This establishes the resource
  semantics, not the SP11's DT wiring or polarity.
- The same baseline declares a 12-line
  [`pm8550_gpios` controller](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/pm8550.dtsi#L48-L56).
  Translating the ACPI PM01 resources produces the following DT candidates:

| Button | ACPI resource | PM8550 line name | GPIO chardev offset | State |
|---|---|---:|---:|---|
| Volume up | index 2, `0x00d5` | GPIO6 | 5 | Candidate; measurement required |
| Volume down | index 4, `0x00d7` | GPIO8 | 7 | Candidate; measurement required |

The one-based PMIC line names and prospective DT specifiers are GPIO6 and
GPIO8. The zero-based character-device offsets are 5 and 7; they must not be
copied into a DTS as GPIO5 and GPIO7. The pinned PMIC GPIO driver's
[`of_xlate` implementation](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/drivers/pinctrl/qcom/pinctrl-spmi-gpio.c#L794-L805)
performs that one-based DT translation. The pinned X1 CRD's
[PM8550 GPIO6 volume-up data](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/x1-crd.dtsi#L54-L65)
corroborates the low-offset interpretation but does not prove the SP11 map.

The ACPI `ActiveBoth` descriptors and PM01's pinned
[`_DSM` result `{7, 6}`](https://github.com/linux-surface/acpidumps/blob/1d0a2ce742b450fe3f65287adbe174ddccabe228/surface_pro_11_qcom/dsdt.dsl#L582-L650)
make polarity a testable hypothesis, not a settled result. Microsoft's
[GPIO controller `_DSM` contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/gpio-controller-device-specific-method---dsm-)
describes listed controller-relative ActiveBoth pins as asserted-high, but the
unverified PM01-to-Linux offset translation and the legacy MSHW0040 table do
not agree strongly enough to encode either polarity. The sanitized v3 target
inventory also found only the lid switch below the existing `gpio-keys` node,
with no native volume input device.

## Shared-DTS impact

The existing [`gpio-keys` node](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/x1-microsoft-denali.dtsi#L20-L33)
lives in the shared Denali include. Both the
[`x1e80100` OLED DTS](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/x1e80100-microsoft-denali-oled.dts#L6-L15)
and the
[`x1p64100` LCD DTS](https://github.com/jglathe/linux_ms_dev_kit/blob/8f953dd060bc6e8fb86ca2ea8a92f258141c0169/arch/arm64/boot/dts/qcom/x1p64100-microsoft-denali.dts#L6-L15)
include that file. A common-node change consequently affects both SKUs and
cannot be qualified from OLED testing alone.

## Blocked decision and measurement gate

No DTS patch should be written or booted yet. A hardware operator must first
capture a privileged observation that:

1. identifies the PM8550 gpiochip without relying on probe order;
2. records ownership, direction, IRQ state, and any available level evidence
   without first requesting or reconfiguring either candidate;
3. proceeds only when the lines are unclaimed and the operator has approved a
   bounded input-only request that preserves the existing bias and never
   drives an output;
4. correlates repeated isolated volume-up and volume-down presses with only
   the expected line and interrupt deltas; and
5. proves the inactive and asserted levels across release, hold, reboot, and
   one s2idle cycle.

The report must be sanitized and reviewed before publication. Ambiguous line
ownership, no measurable transition, a conflicting consumer, or inconsistent
polarity keeps P1.2 blocked.

## Canary shape after the gate

Only after that evidence passes, create a distinct one-shot ABI whose sole
functional change extends the existing `gpio-keys` node with volume-up and
volume-down children using PM8550 GPIO6 and GPIO8, the measured active level,
`KEY_VOLUMEUP`/`KEY_VOLUMEDOWN`, a measured or justified debounce interval,
and parent repeat support. Do not add `wakeup-source` without a separate wake
design and test. Validate both Denali DTBs, or scope the data to one SKU when
the LCD mapping cannot be established.

## Acceptance and rollback

| Gate | Acceptance | Rollback or failure action |
|---|---|---|
| Static | DTS and binding checks pass; the diff contains only the rocker data and a distinct ABI | Reject the patch before packaging |
| Press/release | 50 isolated presses per button each produce one correct press and release, with no opposite or phantom event | One-shot boot the persistent fallback and retain logs |
| Hold/repeat | Ten five-second holds per button repeat and stop within one second of release, with no stuck key | Return to fallback; do not tune debounce blindly |
| Interaction | Ten alternating two-button sequences pass; touch, keyboard, touchpad, power button, Wi-Fi, and audio do not regress | Return to fallback and remove only the canary after evidence capture |
| Power | Ten s2idle cycles produce no spontaneous input or wake and restore both buttons | Keep wake disabled; return to fallback on the first unexplained event |
| One-shot recovery | The canary boots once and the next boot returns to the unchanged known-good ABI | Use the physical GRUB recovery path; never make the canary persistent |

## Upstream destination

If the evidence supports a DTS-only implementation, send it to the arm64
Qualcomm and devicetree maintainers selected by `scripts/get_maintainer.pl` in
the feature branch. Involve Linux input maintainers only if testing proves a
generic `gpio-keys` or input-driver change is necessary. Keep SP11-specific
data out of generic input code.
